import Foundation

/// Modifier keys on the on-screen accessory bar: one tap applies to the
/// next key, a second tap locks, a third releases.
public struct StickyModifiers: Sendable, Equatable {
    public enum State: Sendable, Equatable { case off, once, locked }

    /// The order modifiers are listed in on the wire.
    public static let all: [Hbb_ControlKey] = [.control, .alt, .shift, .meta]

    private var states: [Hbb_ControlKey: State] = [:]

    public init() {}

    public func state(_ key: Hbb_ControlKey) -> State { states[key] ?? .off }

    public mutating func tap(_ key: Hbb_ControlKey) {
        states[key] = switch state(key) {
        case .off: .once
        case .once: .locked
        case .locked: .off
        }
    }

    public var active: [Hbb_ControlKey] {
        Self.all.filter { state($0) != .off }
    }

    /// After a key has used them: one-shot modifiers end, locked ones stay.
    public mutating func consume() {
        for (key, state) in states where state == .once {
            states[key] = .off
        }
    }
}

/// The iOS on-screen keyboard: what `insertText` and `deleteBackward` send.
public enum SoftKeyboard {
    public static func insert(_ text: String, modifiers: [Hbb_ControlKey]) -> [Hbb_Message] {
        let shortcut = !Input.hotkeyModifiers.isDisjoint(with: modifiers)
        if shortcut || text.count == 1 {
            return text.map { c in
                switch c {
                case "\n", "\r": Input.key(.return, modifiers: modifiers)
                case "\t": Input.key(.tab, modifiers: modifiers)
                default:
                    if !shortcut, modifiers.contains(.shift) {
                        // Shift latched on the bar: the host types Unicode, so
                        // the case has to be in the text itself.
                        Input.typed(c.uppercased())
                    } else {
                        Input.typed(String(c), modifiers: shortcut ? modifiers : [])
                    }
                }
            }
        }
        // Several characters at once (autocorrect, paste, dictation): as text,
        // with line breaks as Return.
        var messages: [Hbb_Message] = []
        var run = ""
        for c in text {
            if c == "\n" || c == "\r" {
                if !run.isEmpty { messages.append(Input.text(run)); run = "" }
                messages.append(Input.key(.return))
            } else {
                run.append(c)
            }
        }
        if !run.isEmpty { messages.append(Input.text(run)) }
        return messages
    }

    public static func deleteBackward(modifiers: [Hbb_ControlKey]) -> Hbb_Message {
        Input.key(.backspace, modifiers: modifiers)
    }
}

/// A hardware keyboard: UIKey's HID usage and characters to messages.
public enum HardwareKeys {
    private static let special: [Int: Hbb_ControlKey] = [
        0x28: .return, 0x29: .escape, 0x2A: .backspace, 0x2B: .tab, 0x39: .capsLock,
        0x3A: .f1, 0x3B: .f2, 0x3C: .f3, 0x3D: .f4, 0x3E: .f5, 0x3F: .f6,
        0x40: .f7, 0x41: .f8, 0x42: .f9, 0x43: .f10, 0x44: .f11, 0x45: .f12,
        0x46: .snapshot, 0x47: .scroll, 0x48: .pause, 0x49: .insert, 0x4A: .home,
        0x4B: .pageUp, 0x4C: .delete, 0x4D: .end, 0x4E: .pageDown,
        0x4F: .rightArrow, 0x50: .leftArrow, 0x51: .downArrow, 0x52: .upArrow,
        0x53: .numLock, 0x58: .numpadEnter, 0x65: .apps,
    ]

    public static func controlKey(forHIDUsage usage: Int) -> Hbb_ControlKey? {
        special[usage]
    }

    /// The message for a key going down, or nil for keys that send nothing
    /// on their own (modifiers; they ride along on other keys).
    public static func message(hidUsage: Int, characters: String, charactersIgnoringModifiers: String,
                               modifiers: [Hbb_ControlKey]) -> Hbb_Message? {
        if (0xE0...0xE7).contains(hidUsage) { return nil }
        if let key = controlKey(forHIDUsage: hidUsage) {
            return Input.key(key, modifiers: modifiers)
        }
        if !Input.hotkeyModifiers.isDisjoint(with: modifiers) {
            guard let base = charactersIgnoringModifiers.first else { return nil }
            return Input.character(base, modifiers: modifiers)
        }
        // Plain typing: the character already reflects a physical Shift; a
        // Shift latched on the bar has to be applied here.
        guard !characters.isEmpty else { return nil }
        let shiftLatched = modifiers.contains(.shift) && characters == charactersIgnoringModifiers
        return Input.typed(shiftLatched ? characters.uppercased() : characters)
    }
}
