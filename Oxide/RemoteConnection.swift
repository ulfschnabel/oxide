import AVFoundation
import OxideKit
import Observation
import UIKit

enum ConnectError: LocalizedError {
    case address
    case login(LoginFailure)
    case timedOut
    case closed(String?)

    var errorDescription: String? {
        switch self {
        case .address: "That isn't a valid address. Use a host name or IP, optionally with :port."
        case .login(.wrongPassword): "The password was wrong."
        case .login(.needsApproval):
            "That computer only accepts connections someone approves on it. In RustDesk on that computer, set Settings → Security → Password approval to accept passwords."
        case .login(.twoFactorRequired):
            "That computer asks for a two-factor code, which Oxide doesn't support yet. Turn off 2FA in RustDesk on that computer to connect."
        case .login(.offline): "RustDesk on that computer isn't ready to take connections yet."
        case .login(.other(let reason)): "The computer refused the login: \(reason)."
        case .timedOut:
            "The computer didn't answer like RustDesk does. Check the address and port, and that RustDesk has direct IP access turned on."
        case .closed(let reason): "The host closed the connection\(reason.map { ": \($0)" } ?? "")."
        }
    }
}

/// A live session and what the UI shows of it. One task reads the session's
/// events for the connection's whole life; login resolves `open`.
@MainActor @Observable
final class RemoteConnection {
    let host: String
    private(set) var peer = Hbb_PeerInfo()
    private(set) var status: String?
    private(set) var framesShown = 0
    /// The picture's size, from the stream; the view maps touches through it.
    private(set) var videoSize: CGSize = .zero
    let renderer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private(set) lazy var input = InputController(
        display: currentDisplay, send: { [weak self] in self?.send($0) })

    private let session: Session
    private var resolution = ResolutionController()
    private var screen: (size: CGSize, scale: CGFloat)?
    private var resolutionWork: Task<Void, Never>?
    private var builder: VideoSampleBuilder?
    private var login: CheckedContinuation<Void, Error>?
    private let outbox: AsyncStream<Hbb_Message>.Continuation
    private let outgoing: AsyncStream<Hbb_Message>
    private var sender: Task<Void, Never>?

    private init(host: String, session: Session) {
        self.host = host
        self.session = session
        (outgoing, outbox) = AsyncStream.makeStream()
        renderer.videoGravity = .resizeAspect
        renderer.backgroundColor = UIColor.black.cgColor
    }

    /// How long the host gets to answer the login after the TCP connect.
    static let loginTimeout: Duration = .seconds(15)

    /// Connects and logs in; throws with a readable reason if either fails,
    /// or `CancellationError` if the task is cancelled. Nothing is left
    /// running when it throws.
    static func open(host: String, password: String) async throws -> RemoteConnection {
        guard let address = HostAddress(host) else { throw ConnectError.address }
        let transport = TCPTransport(host: address.host, port: address.port)
        try await transport.connect()
        let session = Session(transport: transport, host: host, password: password,
                              clientName: UIDevice.current.name)
        let connection = RemoteConnection(host: host, session: session)
        let timeout = Task { @MainActor [weak connection] in
            try? await Task.sleep(for: loginTimeout)
            guard !Task.isCancelled else { return }
            connection?.abortLogin(ConnectError.timedOut)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.login = continuation
                connection.start()
                if Task.isCancelled { connection.abortLogin(CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor in connection.abortLogin(CancellationError()) }
        }
        return connection
    }

    /// Ends a login that hasn't finished, and the session with it.
    private func abortLogin(_ error: Error) {
        guard login != nil else { return }
        finishLogin(.failure(error))
        let session = session
        Task { await session.close() }
    }

    private func start() {
        let session = session
        Task.detached { await session.run() }
        sender = Task.detached { [outgoing] in
            for await message in outgoing {
                try? await session.send(message)
            }
        }
        Task { [weak self, events = session.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func finishLogin(_ result: Result<Void, Error>) {
        login?.resume(with: result)
        login = nil
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .loggedIn(let peer):
            self.peer = peer
            input.display = currentDisplay
            let i = Int(peer.currentDisplay)
            if peer.displays.indices.contains(i) {
                let d = peer.displays[i]
                resolution.update(display: peer.currentDisplay,
                                  current: Mode(pixels: Int(d.width), Int(d.height), scale: d.scale),
                                  original: d.hasOriginalResolution ? Mode(d.originalResolution) : nil,
                                  modes: peer.resolutions.resolutions.map(Mode.init))
            }
            finishLogin(.success(()))
            scheduleResolution(after: .zero)
        case .switchDisplay(let s):
            guard s.display == peer.currentDisplay else { break }
            input.display = DisplayRect(x: Int(s.x), y: Int(s.y), width: Int(s.width), height: Int(s.height))
            let wasPending = resolution.pending != nil
            resolution.update(display: s.display,
                              current: Mode(pixels: Int(s.width), Int(s.height), scale: currentScale),
                              original: s.hasOriginalResolution ? Mode(s.originalResolution) : nil,
                              modes: s.resolutions.resolutions.map(Mode.init))
            // Our request settled: the window may have changed meanwhile.
            if wasPending { scheduleResolution(after: .zero) }
        case .displays(let displays):
            peer.displays = displays
            input.display = currentDisplay
        case .cursorPosition(let x, let y):
            input.hostCursorMoved(x: x, y: y)
        case .loginFailed(let reason):
            finishLogin(.failure(ConnectError.login(reason)))
        case .video(let frame):
            show(frame)
        case .unsupportedCodec(let codec):
            status = "The host switched to \(codec.uppercased()), which Oxide can't decode. Check its hardware encoding."
        case .closed(let reason):
            finishLogin(.failure(ConnectError.closed(reason)))
            status = "Disconnected\(reason.map { ": \($0)" } ?? "")."
        }
    }

    private func show(_ frame: VideoFrameUnit) {
        if builder?.codec != frame.codec {
            builder = VideoSampleBuilder(codec: frame.codec)
        }
        do {
            guard let sample = try builder?.sampleBuffer(for: frame.data, isKey: frame.key, pts: frame.pts) else { return }
            let renderer = renderer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sample)
            framesShown += 1
            if let format = CMSampleBufferGetFormatDescription(sample) {
                let d = CMVideoFormatDescriptionGetDimensions(format)
                let size = CGSize(width: Int(d.width), height: Int(d.height))
                if size != videoSize { videoSize = size }
            }
        } catch {
            status = "Video error: \(error)"
        }
    }

    // MARK: Resolution

    /// The window's size changed (connect, rotate, fold, Split View).
    func screenChanged(size: CGSize, scale: CGFloat) {
        guard size != screen?.size || scale != screen?.scale else { return }
        screen = (size, scale)
        // Rotating and folding pass through intermediate sizes, and each change
        // stalls the stream while the host rebuilds its encoder.
        scheduleResolution(after: .milliseconds(600))
    }

    /// The resolution settings changed.
    func resolutionSettingsChanged() {
        scheduleResolution(after: .zero)
    }

    private func scheduleResolution(after delay: Duration) {
        resolutionWork?.cancel()
        resolutionWork = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.applyResolution()
        }
    }

    private func applyResolution() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.matchResolution) else {
            if let restore = resolution.restore() { send([restore]) }
            return
        }
        guard let screen else { return }
        let textSize = TextSize(rawValue: defaults.string(forKey: SettingsKey.textSize) ?? "") ?? .balanced
        let factor = textSize.factor(screenScale: screen.scale)
        let target = Mode(Int((screen.size.width * factor).rounded()), Int((screen.size.height * factor).rounded()))
        if let request = resolution.target(target, now: .now) {
            send([request])
        }
        // While a request is unconfirmed, look again at its deadline: then a
        // window change that came meanwhile is applied, or, if the host never
        // confirmed, the next best mode is tried.
        if let deadline = resolution.pending?.deadline {
            scheduleResolution(after: .seconds(max(deadline.timeIntervalSinceNow, 0) + 0.3))
        }
    }

    /// Host pixels per mode unit for the current display (2 on a Retina Mac).
    private var currentScale: Double {
        let i = Int(peer.currentDisplay)
        return peer.displays.indices.contains(i) ? peer.displays[i].scale : 1
    }

    /// The display being shown, in host pixels.
    var currentDisplay: DisplayRect {
        let i = Int(peer.currentDisplay)
        guard peer.displays.indices.contains(i) else { return DisplayRect(x: 0, y: 0, width: 1920, height: 1080) }
        return DisplayRect(peer.displays[i])
    }

    /// Input goes through one queue so the host gets it in order (a move
    /// before the click it positions).
    private func send(_ messages: [Hbb_Message]) {
        for message in messages { outbox.yield(message) }
    }

    func disconnect() async {
        // Release a held button, and let queued input reach the host first.
        input.dragEnded()
        outbox.finish()
        await sender?.value
        await session.close()
    }
}
