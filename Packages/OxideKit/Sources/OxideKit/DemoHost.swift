import Foundation

public enum DemoLinkError: Error, Equatable {
    case closed
}

/// The connection between the app and its demo computer: two in-memory byte
/// streams in place of TCP. Nothing goes over the network.
public enum DemoLink {
    public static func pair() -> (client: Transport, host: DemoHostEnd) {
        let toHost = Pipe()
        let toClient = Pipe()
        return (DemoClientEnd(outgoing: toHost, incoming: toClient), DemoHostEnd(outgoing: toClient, incoming: toHost))
    }
}

/// One direction of the link. One reader at a time.
final class Pipe: Sendable {
    // The reader reads serially, so one iterator without locking is fine.
    nonisolated(unsafe) private var iterator: AsyncStream<Data>.Iterator
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        iterator = stream.makeAsyncIterator()
        self.continuation = continuation
    }

    func write(_ data: Data) throws {
        if case .terminated = continuation.yield(data) { throw DemoLinkError.closed }
    }

    func read() async -> Data? { await iterator.next() }

    func finish() { continuation.finish() }
}

final class DemoClientEnd: Transport {
    private let outgoing: Pipe
    private let incoming: Pipe

    init(outgoing: Pipe, incoming: Pipe) {
        self.outgoing = outgoing
        self.incoming = incoming
    }

    func send(_ data: Data) async throws { try outgoing.write(data) }
    func receive() async throws -> Data? { await incoming.read() }

    func close() {
        outgoing.finish()
        incoming.finish()
    }
}

/// The demo computer's end of the link.
public final class DemoHostEnd: Sendable {
    private let outgoing: Pipe
    private let incoming: Pipe

    init(outgoing: Pipe, incoming: Pipe) {
        self.outgoing = outgoing
        self.incoming = incoming
    }

    func send(_ message: Hbb_Message) throws { try outgoing.write(Framing.encode(message.serializedData())) }
    func receive() async -> Data? { await incoming.read() }

    func close() {
        outgoing.finish()
        incoming.finish()
    }
}

/// Oxide's demo computer: a RustDesk host inside the app, so Oxide can be
/// tried without a computer running RustDesk. It speaks the real protocol
/// (password challenge, peer info, H.264 video, input, resolution changes)
/// to the app's own client, over an in-memory link. Its screen is a
/// `DemoDesktop`: it shows what the input did.
public actor DemoHost {
    /// The address the app gives the demo computer: not a valid host
    /// address (it has a space), so no computer the user adds can have it.
    public static let address = "oxide demo"
    /// Typed in for the user: the login runs like any other.
    public static let password = "oxide-demo"

    private var desktop = DemoDesktop()
    private let picture = DemoPicture()
    private var sentVersion: Int?
    private var keyWanted = true
    private var pts: Int64 = 0
    /// The connection being served: an earlier one still winding down
    /// leaves the video to it.
    private var generation = 0

    public init() {}

    /// What was typed on the demo desktop.
    var typed: String { desktop.text }

    /// Serves one connection until the client closes it.
    /// The desktop stays as it was between connections (a reconnect, a
    /// pause in the background); each connection starts with a key frame.
    public func serve(_ end: DemoHostEnd) async {
        defer { end.close() }
        generation += 1
        let current = generation
        keyWanted = true
        sentVersion = nil
        desktop.releaseInput()
        let salt = Self.token(32)
        let challenge = Self.token(6)
        var hash = Hbb_Message()
        hash.hash = .with {
            $0.salt = salt
            $0.challenge = challenge
        }
        guard (try? end.send(hash)) != nil else { return }
        var decoder = FrameDecoder(maxLength: 1 << 20)
        var video: Task<Void, Never>?
        defer { video?.cancel() }
        while let chunk = await end.receive() {
            guard let bodies = try? decoder.append(chunk) else { return }
            for body in bodies {
                guard let message = try? Hbb_Message(serializedBytes: body) else { continue }
                if video == nil {
                    guard case .loginRequest(let login) = message.union else { continue }
                    guard login.password == PasswordHash.compute(password: Self.password, salt: salt,
                                                                  challenge: challenge)
                    else {
                        var refused = Hbb_Message()
                        refused.loginResponse.error = "Wrong Password"
                        try? end.send(refused)
                        continue
                    }
                    guard (try? end.send(loggedIn())) != nil else { return }
                    video = Task { await self.sendVideo(to: end, generation: current) }
                } else if current == generation {
                    handle(message, end: end)
                }
            }
        }
    }

    private func loggedIn() -> Hbb_Message {
        var message = Hbb_Message()
        message.loginResponse.peerInfo = .with {
            $0.hostname = "Oxide demo"
            $0.username = "demo"
            $0.platform = "Windows"
            $0.version = Session.protocolVersion
            $0.displays = [.with {
                $0.width = Int32(desktop.width)
                $0.height = Int32(desktop.height)
                $0.name = "DEMO"
                $0.online = true
                $0.originalResolution = Self.resolution(DemoDesktop.original)
            }]
            $0.resolutions = Self.modes
        }
        return message
    }

    private static var modes: Hbb_SupportedResolutions {
        .with { $0.resolutions = DemoDesktop.modes.map(resolution) }
    }

    private static func resolution(_ mode: (Int, Int)) -> Hbb_Resolution {
        .with {
            $0.width = Int32(mode.0)
            $0.height = Int32(mode.1)
        }
    }

    private func handle(_ message: Hbb_Message, end: DemoHostEnd) {
        switch message.union {
        case .mouseEvent(let e):
            desktop.handle(e)
        case .keyEvent(let e):
            desktop.handle(e)
        case .misc(let misc):
            switch misc.union {
            case .changeDisplayResolution(let change):
                let mode = (Int(change.resolution.width), Int(change.resolution.height))
                // An unlisted mode goes unanswered, as on a real host.
                guard desktop.resize(width: mode.0, height: mode.1) else { return }
                var reply = Hbb_Message()
                reply.misc.switchDisplay = .with {
                    $0.display = change.display
                    $0.width = Int32(mode.0)
                    $0.height = Int32(mode.1)
                    $0.resolutions = Self.modes
                    $0.originalResolution = Self.resolution(DemoDesktop.original)
                }
                try? end.send(reply)
                keyWanted = true
            case .refreshVideo:
                keyWanted = true
            default:
                break
            }
        default:
            break
        }
    }

    /// A frame whenever the desktop changed (or a key frame was asked for),
    /// at most 30 a second.
    private func sendVideo(to end: DemoHostEnd, generation: Int) async {
        while !Task.isCancelled, generation == self.generation {
            if keyWanted || sentVersion != desktop.version {
                let key = keyWanted
                keyWanted = false
                sentVersion = desktop.version
                if let frame = try? picture.frame(of: desktop, forceKey: key) {
                    var message = Hbb_Message()
                    message.videoFrame = .with {
                        $0.h264S = .with { $0.frames = [.with {
                            $0.data = frame.data
                            $0.key = frame.key
                            $0.pts = pts
                        }] }
                    }
                    pts += 33
                    guard (try? end.send(message)) != nil else { return }
                }
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private static func token(_ n: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}
