/// Why the host refused a login, from the message RustDesk sends
/// (src/client.rs `LOGIN_MSG_*` in RustDesk 1.5.3).
public enum LoginFailure: Equatable, Sendable {
    /// The password matched neither the one-time nor the permanent one.
    case wrongPassword
    /// The host only lets in connections someone accepts on it.
    case needsApproval
    /// The host asks for a 2FA code, which Oxide doesn't support yet.
    case twoFactorRequired
    /// The host isn't ready to take connections.
    case offline
    case other(String)

    public init(_ message: String) {
        switch message {
        case "Wrong Password", "Empty Password": self = .wrongPassword
        case "No Password Access": self = .needsApproval
        case "2FA Required", "Wrong 2FA Code": self = .twoFactorRequired
        case "Offline": self = .offline
        default: self = .other(message)
        }
    }
}
