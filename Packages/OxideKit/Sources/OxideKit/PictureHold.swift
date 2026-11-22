/// Keeps a new session's picture back while the host's resolution is changed
/// to fit this screen. The host starts streaming at its old resolution the
/// moment it accepts the login, and RustDesk has no way to ask for another
/// one before that; showing those frames means a picture at the wrong size,
/// a stall while the host rebuilds its encoder, then a jump.
public struct PictureHold: Sendable {
    /// Longest the picture is kept back, for a host that never confirms.
    public static let limit: Duration = .seconds(4)

    private var until: ContinuousClock.Instant?

    public init() {}

    public var isHeld: Bool { until != nil }

    /// A session logged in.
    public mutating func begin(now: ContinuousClock.Instant) {
        until = now + Self.limit
    }

    /// The resolution settled (or needed no change). True when this ends a
    /// hold, so the picture should start, from a key frame.
    public mutating func release() -> Bool {
        guard until != nil else { return false }
        until = nil
        return true
    }

    /// True when the hold ran out at `now` and has just ended.
    public mutating func expire(now: ContinuousClock.Instant) -> Bool {
        guard let until, now >= until else { return false }
        self.until = nil
        return true
    }
}
