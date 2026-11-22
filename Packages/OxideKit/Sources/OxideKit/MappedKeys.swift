/// The host's operating system, as far as key codes go.
public enum HostPlatform: Equatable, Sendable {
    case windows, macOS, linux, other

    /// From `PeerInfo.platform` ("Windows", "Mac OS", "Linux").
    public init(peerPlatform: String) {
        switch peerPlatform.lowercased().filter({ !$0.isWhitespace }) {
        case "windows": self = .windows
        case "macos": self = .macOS
        case "linux": self = .linux
        default: self = .other
        }
    }
}

/// A hardware keyboard's keys as physical keys: RustDesk's map mode. Each key
/// goes down and up as the host platform's own key code, so the host's
/// layout decides what it types, held keys stay held (games, Shift-click),
/// and modifiers work on their own. See docs/protocol/input.md.
public enum MappedKeys {
    public static func code(hidUsage: Int, on platform: HostPlatform) -> Int32? {
        switch platform {
        case .windows: KeyCodes.windows[hidUsage]
        case .macOS: KeyCodes.macOS[hidUsage]
        case .linux: KeyCodes.linux[hidUsage]
        case .other: nil
        }
    }

    /// The key going down or up; nil when the host has no code for it.
    public static func message(hidUsage: Int, down: Bool, on platform: HostPlatform,
                               capsLock: Bool) -> Hbb_Message? {
        guard let code = code(hidUsage: hidUsage, on: platform) else { return nil }
        var m = Hbb_Message()
        m.keyEvent = .with {
            $0.mode = .map
            $0.chr = UInt32(bitPattern: code)
            $0.down = down
            // The host matches its lock keys to these for the key's duration,
            // as the official client sends them.
            if capsLock, isLetter(hidUsage) { $0.modifiers.append(.capsLock) }
            if isNumpad(hidUsage) { $0.modifiers.append(.numLock) }
        }
        return m
    }

    /// The key for a modifier latched on the on-screen bar (its left one).
    public static func hidUsage(for modifier: Hbb_ControlKey) -> Int? {
        switch modifier {
        case .control: 0xE0
        case .shift: 0xE1
        case .alt: 0xE2
        case .meta: 0xE3
        default: nil
        }
    }

    public static func isModifier(_ hidUsage: Int) -> Bool { (0xE0...0xE7).contains(hidUsage) }

    /// Keys Caps Lock changes: letters, and the punctuation that is a letter
    /// on some layouts.
    static func isLetter(_ hidUsage: Int) -> Bool {
        (0x04...0x1D).contains(hidUsage) || [0x2F, 0x30, 0x33, 0x34, 0x36, 0x37].contains(hidUsage)
    }

    /// Keypad digits, operators and decimal point.
    static func isNumpad(_ hidUsage: Int) -> Bool { (0x54...0x57).contains(hidUsage) || (0x59...0x63).contains(hidUsage) }
}

/// Hardware keys down on the host, so each goes up again, even when the key's
/// release never reaches this app (switching sessions, the background).
public struct HeldKeys: Sendable {
    public let platform: HostPlatform
    /// Each held key, with the bar's modifiers held around it.
    private var held: [(key: Int, latched: [Int])] = []

    public init(platform: HostPlatform) {
        self.platform = platform
    }

    public func isHeld(_ hidUsage: Int) -> Bool { held.contains { $0.key == hidUsage } }

    /// The key going down, after any modifiers latched on the bar. Nil when
    /// the host has no code for it: it's then sent some other way.
    public mutating func down(_ hidUsage: Int, latching modifiers: [Hbb_ControlKey] = [],
                              capsLock: Bool) -> [Hbb_Message]? {
        guard let key = MappedKeys.message(hidUsage: hidUsage, down: true, on: platform, capsLock: capsLock)
        else { return nil }
        // Pressed again without a release in between (a lost release): restart it.
        var out = isHeld(hidUsage) ? up(hidUsage, capsLock: capsLock) : []
        let latched = modifiers.compactMap(MappedKeys.hidUsage(for:)).filter { $0 != hidUsage }
        out += latched.compactMap { MappedKeys.message(hidUsage: $0, down: true, on: platform, capsLock: capsLock) }
        out.append(key)
        held.append((hidUsage, latched))
        return out
    }

    /// Another down while the key is held: the host's apps see a repeat.
    public func repeated(_ hidUsage: Int, capsLock: Bool) -> Hbb_Message? {
        guard isHeld(hidUsage) else { return nil }
        return MappedKeys.message(hidUsage: hidUsage, down: true, on: platform, capsLock: capsLock)
    }

    /// The key going up, then the modifiers latched for it.
    public mutating func up(_ hidUsage: Int, capsLock: Bool) -> [Hbb_Message] {
        guard let i = held.firstIndex(where: { $0.key == hidUsage }) else { return [] }
        let entry = held.remove(at: i)
        return ([entry.key] + entry.latched.reversed()).compactMap {
            MappedKeys.message(hidUsage: $0, down: false, on: platform, capsLock: capsLock)
        }
    }

    public mutating func releaseAll() -> [Hbb_Message] {
        var out: [Hbb_Message] = []
        while let last = held.last {
            out += up(last.key, capsLock: false)
        }
        return out
    }
}
