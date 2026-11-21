import Foundation

/// A byte stream to a host. `receive` returns nil once the host has closed it.
public protocol Transport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close()
}

public struct VideoFrameUnit: Sendable, Equatable {
    public let codec: VideoCodec
    public let data: Data
    public let key: Bool
    public let pts: Int64
    public let display: Int32
}

public enum SessionEvent: Sendable, Equatable {
    case loggedIn(Hbb_PeerInfo)
    case loginFailed(LoginFailure)
    case video(VideoFrameUnit)
    /// The host switched to a codec this client does not decode (it falls
    /// back to VP9 when its hardware encoder fails).
    case unsupportedCodec(String)
    /// Where the host's cursor is, in host pixels (sent when someone else
    /// moves it).
    case cursorPosition(x: Int32, y: Int32)
    /// The display changed (resolution, position) or was switched to.
    case switchDisplay(Hbb_SwitchDisplay)
    /// The host's display list changed (a monitor added, moved or resized).
    case displays([Hbb_DisplayInfo])
    case closed(String?)
}

/// One remote-desktop connection to a RustDesk host by direct IP (stock
/// 1.5.3: plaintext, no key exchange). See docs/protocol/transport-auth.md.
public actor Session {
    public static let protocolVersion = "1.5.3"

    public nonisolated let events: AsyncStream<SessionEvent>
    private let emit: AsyncStream<SessionEvent>.Continuation
    private let transport: Transport
    private let host: String
    private let password: String
    private let clientName: String
    private var decoder = FrameDecoder(maxLength: 64 << 20)
    private var loggedIn = false

    public init(transport: Transport, host: String, password: String, clientName: String = "Oxide") {
        self.transport = transport
        self.host = host
        self.password = password
        self.clientName = clientName
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Reads from the host until it closes or `close()` is called.
    public func run() async {
        var reason: String?
        do {
            loop: while let chunk = try await transport.receive() {
                for body in try decoder.append(chunk) {
                    let message = try Hbb_Message(serializedBytes: body)
                    if try await !handle(message) { break loop }
                }
            }
        } catch {
            reason = String(describing: error)
        }
        transport.close()
        emit.yield(.closed(reason))
        emit.finish()
    }

    public func close() {
        transport.close()
    }

    public func send(_ message: Hbb_Message) async throws {
        try await transport.send(Framing.encode(message.serializedData()))
    }

    /// Handles one message; false ends the session.
    private func handle(_ message: Hbb_Message) async throws -> Bool {
        switch message.union {
        case .hash(let hash):
            try await send(loginRequest(salt: hash.salt, challenge: hash.challenge))
        case .loginResponse(let response):
            switch response.union {
            case .peerInfo(let info):
                loggedIn = true
                emit.yield(.loggedIn(info))
            case .error(let error):
                // The host keeps the connection open for a retry; this client
                // asks the user again instead.
                emit.yield(.loginFailed(LoginFailure(error)))
                return false
            default:
                break
            }
        case .testDelay:
            // The host measures latency with these and drops the frame rate,
            // then the connection, if they are not echoed.
            try await send(message)
        case .videoFrame(let frame):
            return deliver(frame)
        case .cursorPosition(let p):
            emit.yield(.cursorPosition(x: p.x, y: p.y))
        case .misc(let misc):
            if case .switchDisplay(let s) = misc.union {
                emit.yield(.switchDisplay(s))
            }
        case .peerInfo(let info) where loggedIn:
            emit.yield(.displays(info.displays))
        default:
            break
        }
        return true
    }

    private func deliver(_ frame: Hbb_VideoFrame) -> Bool {
        let codec: VideoCodec
        let frames: Hbb_EncodedVideoFrames
        switch frame.union {
        case .h264S(let f): (codec, frames) = (.h264, f)
        case .h265S(let f): (codec, frames) = (.h265, f)
        case .vp9S: emit.yield(.unsupportedCodec("vp9")); return false
        case .vp8S: emit.yield(.unsupportedCodec("vp8")); return false
        case .av1S: emit.yield(.unsupportedCodec("av1")); return false
        default: return true
        }
        for f in frames.frames {
            emit.yield(.video(VideoFrameUnit(codec: codec, data: f.data, key: f.key, pts: f.pts, display: frame.display)))
        }
        return true
    }

    private func loginRequest(salt: String, challenge: String) -> Hbb_Message {
        var message = Hbb_Message()
        message.loginRequest = .with {
            $0.username = host
            $0.password = PasswordHash.compute(password: password, salt: salt, challenge: challenge)
            $0.myID = "oxide"
            $0.myName = clientName
            $0.sessionID = UInt64.random(in: 1...UInt64(Int64.max))
            $0.version = Session.protocolVersion
            $0.myPlatform = "iOS"
            $0.videoAckRequired = false
            $0.option = .with {
                $0.supportedDecoding = .with {
                    $0.abilityH264 = 1
                    $0.abilityH265 = 1
                    $0.prefer = .h264
                }
                $0.disableAudio = .yes
                // The host reports where its cursor is only when asked to; the
                // trackpad mode follows it when someone else moves it.
                $0.showRemoteCursor = .yes
            }
        }
        return message
    }
}
