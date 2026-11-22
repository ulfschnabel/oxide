import Foundation

/// Why a connection couldn't be made or didn't last, in words for the user.
/// The system's own error text goes to the log, not here.
public enum ConnectionProblem: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress
    case notFound
    case refused
    case unreachable
    case localNetworkDenied
    case login(LoginFailure)
    /// Something answered, but not the way RustDesk does.
    case notRustDesk
    /// The connection broke while it was in use.
    case dropped
    /// The host ended the session and said why.
    case closedByHost(String)
    /// The host sends video in a codec Oxide can't decode.
    case unsupportedCodec(String)
    /// Unexpected: the detail is for the log.
    case other(String)

    public init(_ error: Error) {
        switch error {
        case let p as ConnectionProblem: self = p
        case let t as TransportError:
            switch t {
            case .refused: self = .refused
            case .unreachable: self = .unreachable
            case .notFound: self = .notFound
            case .connectionLost: self = .dropped
            case .localNetworkDenied: self = .localNetworkDenied
            case .failed(let detail): self = .other(detail)
            }
        default: self = .other(String(describing: error))
        }
    }

    /// Whether trying again by itself might help: network trouble may pass,
    /// a refused password or a host that hung up on purpose won't.
    public var isTransient: Bool {
        switch self {
        case .notFound, .refused, .unreachable, .notRustDesk, .dropped, .other: true
        case .invalidAddress, .localNetworkDenied, .login, .closedByHost, .unsupportedCodec: false
        }
    }

    public enum Cause: Sendable {
        case unreachable, authentication, timedOut, closedByHost, other

        public var title: String {
            switch self {
            case .unreachable: "Computer Unreachable"
            case .authentication: "Not Allowed In"
            case .timedOut: "No Answer"
            case .closedByHost: "Disconnected by the Computer"
            case .other: "Connection Problem"
            }
        }
    }

    public var cause: Cause {
        switch self {
        case .notFound, .refused, .unreachable, .dropped, .localNetworkDenied: .unreachable
        case .login: .authentication
        case .notRustDesk: .timedOut
        case .closedByHost: .closedByHost
        case .invalidAddress, .unsupportedCodec, .other: .other
        }
    }

    public var message: String {
        switch self {
        case .invalidAddress: "That isn't a valid address. Use a host name or IP, optionally with :port."
        case .notFound: "That computer's name couldn't be found. Check the address, or use its IP address."
        case .refused:
            "The computer is there but isn't taking connections on that port. Check that RustDesk is running with direct IP access turned on."
        case .unreachable: "Couldn't reach the computer. Check that it's on, and on your network or VPN."
        case .localNetworkDenied:
            "Oxide isn't allowed to reach computers on your network. Turn it on in Settings → Privacy & Security → Local Network → Oxide."
        case .login(.wrongPassword): "The password wasn't accepted."
        case .login(.needsApproval):
            "That computer only accepts connections someone approves on it. In RustDesk on that computer, set Settings → Security → Password approval to accept passwords."
        case .login(.twoFactorRequired):
            "That computer asks for a two-factor code, which Oxide doesn't support yet. Turn off 2FA in RustDesk on that computer to connect."
        case .login(.offline): "RustDesk on that computer isn't ready to take connections yet."
        case .login(.other(let reason)): "The computer refused the login: \(reason)."
        case .notRustDesk:
            "The computer didn't answer like RustDesk does. Check the address and port, and that RustDesk has direct IP access turned on."
        case .dropped: "The connection was lost."
        case .closedByHost(let reason): "The computer ended the session: \(reason)."
        case .unsupportedCodec(let codec):
            "The computer sends its picture as \(codec.uppercased()), which Oxide can't show. That usually means its hardware video encoder isn't working: check the graphics driver, or RustDesk's hardware codec setting."
        case .other: "Something went wrong with the connection. Settings → Diagnostics has the details."
        }
    }

    public var errorDescription: String? { message }
}

/// When to try a dropped connection again, and when to stop and ask.
public struct ReconnectPolicy: Sendable {
    /// The wait before each attempt; there are as many attempts as delays.
    public var delays: [Duration]
    /// No attempt starts after this long.
    public var deadline: Duration

    public static let standard = ReconnectPolicy(
        delays: [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8)], deadline: .seconds(40))

    public init(delays: [Duration], deadline: Duration) {
        self.delays = delays
        self.deadline = deadline
    }

    public enum Decision: Equatable, Sendable {
        case retry(after: Duration)
        case giveUp
    }

    /// After `failures` failed attempts, `elapsed` since the connection
    /// dropped, the last one failing with `last`.
    public func next(failures: Int, elapsed: Duration, last: ConnectionProblem?) -> Decision {
        if let last, !last.isTransient { return .giveUp }
        guard delays.indices.contains(failures) else { return .giveUp }
        let delay = delays[failures]
        return elapsed + delay < deadline ? .retry(after: delay) : .giveUp
    }
}

/// Session-level requests that aren't input.
public enum Control {
    /// Asks the host for a key frame, so the picture can be decoded from scratch.
    public static func refreshVideo() -> Hbb_Message {
        var m = Hbb_Message()
        m.misc = .with { $0.refreshVideo = true }
        return m
    }
}
