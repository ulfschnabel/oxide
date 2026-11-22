import AVFoundation
import CoreImage
import Network
import OxideKit
import Observation
import UIKit

/// A remote session and what the UI shows of it. It outlives any one
/// socket: when the connection drops, or is paused in the background, it
/// logs in again with the same session id and carries on with the same
/// screen, input and settings.
@MainActor @Observable
final class RemoteConnection {
    enum Phase: Equatable {
        case live
        /// Closed on purpose in the background; reconnects on return.
        case paused
        case reconnecting(attempt: Int)
        /// Gave up; the UI asks what to do.
        case failed(ConnectionProblem)
        /// Disconnected by the user.
        case ended
    }

    let host: String
    private(set) var phase: Phase = .live
    private(set) var peer = Hbb_PeerInfo()
    private(set) var status: String?
    /// The picture's size, from the stream; the view maps touches through it.
    private(set) var videoSize: CGSize = .zero
    /// The last picture, shown while there is no live one (background,
    /// reconnecting) so the screen never goes black.
    private(set) var placeholder: UIImage?
    let renderer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private(set) lazy var input = InputController(
        display: currentDisplay, send: { [weak self] in self?.send($0) })

    private var password: String
    /// Kept across reconnects: the host lets a recent session back in on its
    /// old password, even a one-time password that has rotated since.
    private let sessionID = Session.newID()
    private var session: Session?
    /// Which session's events count; older sessions' late events are ignored.
    private var generation = 0
    private var outbox: AsyncStream<Hbb_Message>.Continuation?
    private var sender: Task<Void, Never>?
    private var login: CheckedContinuation<Void, Error>?
    private var hostClosedReason: String?
    /// Why the session can't go on, if not the host's say: retrying won't help.
    private var terminalProblem: ConnectionProblem?
    /// When the current session logged in.
    private var liveSince: ContinuousClock.Instant?
    /// The reconnect budget. A session that dies soon after logging in
    /// doesn't refill it, so a host that drops every session can't make
    /// this reconnect forever.
    private var reconnectStarted: ContinuousClock.Instant?
    private var reconnectFailures = 0
    /// A session must last this long before the budget starts over.
    static let stableAfter: Duration = .seconds(10)
    private var reconnectTask: Task<Void, Never>?
    private let policy = ReconnectPolicy.standard

    private var resolution = ResolutionController()
    private var screen: (size: CGSize, scale: CGFloat)?
    private var loggedScreen: (size: CGSize, scale: CGFloat)?
    private var resolutionWork: Task<Void, Never>?
    private var builder: VideoSampleBuilder?
    /// After the background or a reconnect, frames until the next key frame
    /// can't be decoded: they're skipped.
    private var awaitingKeyFrame = false

    private var inBackground = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pauseTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true

    private init(host: String, password: String) {
        self.host = host
        self.password = password
        renderer.videoGravity = .resizeAspect
        renderer.backgroundColor = UIColor.black.cgColor
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: .main)
    }

    /// How long the host gets to answer the login after the TCP connect.
    static let loginTimeout: Duration = .seconds(15)

    /// Connects and logs in; throws a `ConnectionProblem`, or
    /// `CancellationError` if the task is cancelled. Nothing is left
    /// running when it throws.
    static func open(host: String, password: String) async throws -> RemoteConnection {
        let connection = RemoteConnection(host: host, password: password)
        do {
            try await connection.attach()
        } catch {
            connection.shutDown()
            throw error
        }
        return connection
    }

    /// One TCP connection and login, as a new session generation.
    private func attach() async throws {
        guard let address = HostAddress(host) else { throw ConnectionProblem.invalidAddress }
        diag("connect \(address.host):\(address.port)")
        let transport = TCPTransport(host: address.host, port: address.port)
        do {
            try await transport.connect()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diag("connect failed: \(error.localizedDescription)")
            throw ConnectionProblem(error)
        }
        diag("tcp connected, logging in")
        let session = Session(transport: transport, host: host, password: password,
                              clientName: UIDevice.current.name, sessionID: sessionID)
        generation += 1
        let current = generation
        self.session = session
        hostClosedReason = nil
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loginTimeout)
            guard !Task.isCancelled else { return }
            diag("login timed out")
            self?.abortLogin(ConnectionProblem.notRustDesk)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                login = continuation
                start(session, generation: current)
                if Task.isCancelled { abortLogin(CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor in self.abortLogin(CancellationError()) }
        }
    }

    /// Ends a login that hasn't finished, and its session.
    private func abortLogin(_ error: Error) {
        guard login != nil else { return }
        finishLogin(.failure(error))
        closeSession()
    }

    private func start(_ session: Session, generation current: Int) {
        let (outgoing, outbox) = AsyncStream.makeStream(of: Hbb_Message.self)
        self.outbox = outbox
        Task.detached { await session.run() }
        sender = Task.detached {
            for await message in outgoing {
                try? await session.send(message)
            }
        }
        Task { [weak self, events = session.events] in
            for await event in events {
                guard let self, self.generation == current else { return }
                self.handle(event)
            }
        }
    }

    private func finishLogin(_ result: Result<Void, Error>) {
        login?.resume(with: result)
        login = nil
    }

    /// Closes the current socket without telling the host why: a host that
    /// gets a close reason forgets the session, and a reconnect couldn't use it.
    @discardableResult
    private func closeSession() -> Task<Void, Never> {
        input.dragEnded()
        outbox?.finish()
        outbox = nil
        let session = session
        self.session = nil
        return Task { await session?.close() }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .loggedIn(let peer):
            self.peer = peer
            input.display = currentDisplay
            // A new session: the host's display may have been restored meanwhile.
            resolution = ResolutionController()
            let i = Int(peer.currentDisplay)
            if peer.displays.indices.contains(i) {
                let d = peer.displays[i]
                resolution.update(display: peer.currentDisplay,
                                  current: Mode(pixels: Int(d.width), Int(d.height), scale: d.scale),
                                  original: d.hasOriginalResolution ? Mode(d.originalResolution) : nil,
                                  modes: peer.resolutions.resolutions.map(Mode.init))
            }
            let shown = peer.displays.indices.contains(i)
                ? "\(peer.displays[i].width)×\(peer.displays[i].height) scale \(peer.displays[i].scale)" : "?"
            diag("logged in: \(peer.platform) \(peer.version), display \(i) of \(peer.displays.count) \(shown), \(peer.resolutions.resolutions.count) modes")
            phase = .live
            liveSince = .now
            terminalProblem = nil
            awaitingKeyFrame = true
            finishLogin(.success(()))
            if inBackground {
                // Came back up while away (a network change): don't hold it.
                pause(because: "logged in while in the background")
            } else {
                scheduleResolution(after: .zero)
            }
        case .switchDisplay(let s):
            guard s.display == peer.currentDisplay else { break }
            input.display = DisplayRect(x: Int(s.x), y: Int(s.y), width: Int(s.width), height: Int(s.height))
            let wasPending = resolution.pending != nil
            diag("host display now \(s.width)×\(s.height)\(wasPending ? " (answering our request)" : "")")
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
            diag("login refused: \(reason)")
            finishLogin(.failure(ConnectionProblem.login(reason)))
        case .video(let frame):
            show(frame)
        case .unsupportedCodec(let codec):
            diag("unsupported codec \(codec)")
            terminalProblem = .unsupportedCodec(codec)
        case .hostClosed(let reason):
            diag("host closed the session: \(reason)")
            hostClosedReason = reason
        case .closed(let reason):
            diag("closed\(reason.map { ": \($0)" } ?? "")")
            sessionEnded(error: reason)
        }
    }

    /// The current socket is gone, whoever closed it.
    private func sessionEnded(error: String?) {
        guard phase != .ended else { return }
        let wasLive = phase == .live && login == nil
        if login != nil {
            // Something answered but ended the login: not RustDesk, or a host
            // that turned this client away.
            let problem: ConnectionProblem = hostClosedReason.map { .closedByHost($0) }
                ?? (error == nil ? .dropped : .notRustDesk)
            finishLogin(.failure(problem))
        }
        outbox?.finish()
        outbox = nil
        session = nil
        guard wasLive else { return }
        if let liveSince, .now - liveSince < Self.stableAfter, reconnectStarted != nil {
            // Died soon after a reconnect: that reconnect didn't really work.
            reconnectFailures += 1
        } else {
            reconnectStarted = nil
            reconnectFailures = 0
        }
        liveSince = nil
        capturePlaceholder()
        if let reason = hostClosedReason {
            phase = .failed(.closedByHost(reason))
        } else if let terminalProblem {
            phase = .failed(terminalProblem)
        } else if inBackground {
            // Dropped while away: reconnect on return, not now.
            phase = .paused
        } else {
            startReconnect()
        }
    }

    // MARK: Reconnecting

    /// Retry from the failure dialog, with a new password if one was asked for.
    func retry(password newPassword: String? = nil) {
        if let newPassword { password = newPassword }
        reconnectStarted = nil
        reconnectFailures = 0
        startReconnect()
    }

    private func startReconnect() {
        guard phase != .ended else { return }
        reconnectTask?.cancel()
        phase = .reconnecting(attempt: 1)
        reconnectTask = Task { [weak self] in await self?.reconnect() }
    }

    private func reconnect() async {
        let started = reconnectStarted ?? .now
        reconnectStarted = started
        var last: ConnectionProblem? = reconnectFailures > 0 ? .dropped : nil
        while !Task.isCancelled {
            let failures = reconnectFailures
            switch policy.next(failures: failures, elapsed: .now - started, last: last) {
            case .giveUp:
                let problem = last ?? .dropped
                diag("giving up reconnecting: \(problem)")
                phase = .failed(problem)
                return
            case .retry(let delay):
                phase = .reconnecting(attempt: failures + 1)
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                diag("reconnect attempt \(failures + 1)")
                do {
                    try await attach()
                    diag("reconnected")
                    return
                } catch is CancellationError {
                    return
                } catch {
                    last = ConnectionProblem(error)
                    reconnectFailures += 1
                    diag("reconnect attempt failed: \(last.map { "\($0)" } ?? "?")")
                }
            }
        }
    }

    private func networkChanged(up: Bool) {
        let cameBack = up && !networkUp
        networkUp = up
        // The network that was missing is back: one more round, unasked.
        guard cameBack, !inBackground, case .failed(let problem) = phase, problem.isTransient else { return }
        diag("network is back, reconnecting")
        startReconnect()
    }

    // MARK: Background

    /// The app went to the background: keep the session for the grace
    /// window (as long as iOS allows, about 30 s), then pause it.
    func enteredBackground() {
        guard !inBackground, phase != .ended else { return }
        inBackground = true
        capturePlaceholder()
        input.dragEnded()
        if case .reconnecting = phase {
            reconnectTask?.cancel()
            phase = .paused
        }
        guard phase == .live else { return }
        let grace = UserDefaults.standard.double(forKey: SettingsKey.backgroundGrace)
        guard grace > 0 else {
            pause(because: "in the background")
            return
        }
        diag("in the background, keeping the session up to \(Int(grace)) s")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keep the remote session") { [weak self] in
            MainActor.assumeIsolated { self?.pause(because: "background time ran out") }
        }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.pause(because: "background grace over")
        }
    }

    /// Back in front: carry on with the live session, or reconnect.
    func becameActive() {
        guard inBackground else { return }
        inBackground = false
        pauseTask?.cancel()
        pauseTask = nil
        endBackgroundTask()
        switch phase {
        case .live:
            diag("back, session still live")
            // The display layer stops in the background; start it again from a key frame.
            renderer.sampleBufferRenderer.flush()
            awaitingKeyFrame = true
            send([Control.refreshVideo()])
            scheduleResolution(after: .zero)
        case .paused:
            diag("back, reconnecting")
            // Paused on purpose: earlier trouble doesn't count against this.
            reconnectStarted = nil
            reconnectFailures = 0
            startReconnect()
        case .reconnecting, .failed, .ended:
            break
        }
    }

    private func pause(because reason: String) {
        pauseTask?.cancel()
        pauseTask = nil
        // A late expiry call must not pause a session that's in front again.
        guard inBackground else { return }
        guard phase == .live else {
            endBackgroundTask()
            return
        }
        diag("pausing: \(reason)")
        phase = .paused
        liveSince = nil
        let closing = closeSession()
        // Stay awake until the socket is really closed, so the host doesn't
        // keep a half-open connection while the app is suspended.
        Task { [weak self] in
            await closing.value
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Video

    private func show(_ frame: VideoFrameUnit) {
        // The display layer can't take frames in the background.
        guard !inBackground else { return }
        if awaitingKeyFrame {
            guard frame.key else { return }
            awaitingKeyFrame = false
        }
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
            if let format = CMSampleBufferGetFormatDescription(sample) {
                let d = CMVideoFormatDescriptionGetDimensions(format)
                let size = CGSize(width: Int(d.width), height: Int(d.height))
                if size != videoSize { videoSize = size }
            }
            if placeholder != nil { dropPlaceholderSoon() }
        } catch {
            diag("video error: \(error)")
            status = "The picture couldn't be decoded."
        }
    }

    /// Keeps a copy of what's on screen, for while nothing live is.
    private func capturePlaceholder() {
        guard let buffer = renderer.sampleBufferRenderer.displayedPixelBuffer() else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = Self.imageContext.createCGImage(image, from: image.extent) else { return }
        placeholder = UIImage(cgImage: cg)
    }

    private static let imageContext = CIContext()
    private var placeholderDrop: Task<Void, Never>?

    /// The live picture is back: drop the copy once the layer has drawn it.
    private func dropPlaceholderSoon() {
        guard placeholderDrop == nil else { return }
        placeholderDrop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            if self.phase == .live, !self.inBackground { self.placeholder = nil }
            self.placeholderDrop = nil
        }
    }

    // MARK: Resolution

    /// The window's size changed (connect, rotate, fold, Split View).
    func screenChanged(size: CGSize, scale: CGFloat) {
        guard size != screen?.size || scale != screen?.scale else { return }
        screen = (size, scale)
        // iOS resizes the window in the background to take app-switcher
        // snapshots; that's no reason to change the host. Applied on return.
        guard !inBackground else { return }
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
        // A request nobody receives would time out and count against the mode.
        guard phase == .live, !inBackground, outbox != nil else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.matchResolution) else {
            if let restore = resolution.restore() {
                diag("matching off: restoring \(resolution.original.map { "\($0.width)×\($0.height)" } ?? "?")")
                send([restore])
            }
            return
        }
        guard let screen else { return }
        // Logged here, after the debounce: a live resize passes many sizes.
        if loggedScreen?.size != screen.size || loggedScreen?.scale != screen.scale {
            loggedScreen = screen
            diag("window \(Int(screen.size.width))×\(Int(screen.size.height)) pt @\(screen.scale)x")
        }
        let textSize = TextSize(rawValue: defaults.string(forKey: SettingsKey.textSize) ?? "") ?? .balanced
        let factor = textSize.factor(screenScale: screen.scale)
        let target = Mode(Int((screen.size.width * factor).rounded()), Int((screen.size.height * factor).rounded()))
        let pendingBefore = resolution.pending?.mode
        if let request = resolution.target(target, now: .now) {
            let r = request.misc.changeDisplayResolution.resolution
            diag("target \(target.width)×\(target.height) → asking for \(r.width)×\(r.height)")
            send([request])
        } else if pendingBefore == nil, resolution.pending == nil {
            diag("target \(target.width)×\(target.height): no change (current \(resolution.current.map { "\($0.width)×\($0.height)" } ?? "?"), \(resolution.modes.count) modes)")
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
    /// before the click it positions). Without a live session it's dropped.
    private func send(_ messages: [Hbb_Message]) {
        guard phase == .live, login == nil, let outbox else { return }
        for message in messages { outbox.yield(message) }
    }

    func disconnect() async {
        diag("disconnect")
        // Release a held button while input still goes out.
        input.dragEnded()
        // Nothing may bring the session back from here on.
        shutDown()
        outbox?.finish()
        outbox = nil
        let session = session
        let sender = sender
        self.session = nil
        // Queued input (the button release) gets a moment to reach the host;
        // a send stuck on a dead socket doesn't hold up the user.
        Task.detached {
            await sender?.value
            await session?.close()
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            await session?.close()
        }
    }

    /// Stops everything that could bring the session back.
    private func shutDown() {
        phase = .ended
        reconnectTask?.cancel()
        pauseTask?.cancel()
        placeholderDrop?.cancel()
        endBackgroundTask()
        pathMonitor.cancel()
    }
}
