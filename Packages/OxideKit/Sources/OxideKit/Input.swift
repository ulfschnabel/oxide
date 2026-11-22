import Foundation

public enum MouseButton: Int32, CaseIterable, Sendable {
    case left = 0x01, right = 0x02, middle = 0x04, back = 0x08, forward = 0x10

    /// The buttons down in a pointer event's button mask (UIKit numbers
    /// buttons with the same bits).
    public static func pressed(inMask mask: Int) -> Set<MouseButton> {
        Set(allCases.filter { Int($0.rawValue) & mask != 0 })
    }
}

/// Input messages for the host. Mouse positions are absolute host pixels in
/// the host's virtual-desktop space; keys use Legacy mode, where characters
/// are Unicode code points and modifiers ride along on each event. See
/// docs/protocol/input.md.
public enum Input {
    private enum MouseType: Int32 {
        case move = 0, down = 1, up = 2, wheel = 3, trackpad = 4
    }

    /// Ctrl, Alt and Win/Cmd turn a character into a shortcut on the host.
    static let hotkeyModifiers: Set<Hbb_ControlKey> = [.control, .alt, .meta]

    private static func mouse(_ type: MouseType, button: MouseButton? = nil, x: Int32 = 0, y: Int32 = 0,
                              modifiers: [Hbb_ControlKey]) -> Hbb_Message {
        var m = Hbb_Message()
        m.mouseEvent = .with {
            $0.mask = (button?.rawValue ?? 0) << 3 | type.rawValue
            $0.x = x
            $0.y = y
            $0.modifiers = modifiers
        }
        return m
    }

    public static func move(_ x: Int32, _ y: Int32, modifiers: [Hbb_ControlKey] = []) -> Hbb_Message {
        mouse(.move, x: x, y: y, modifiers: modifiers)
    }

    /// One button only: the host ignores combined button masks.
    public static func button(_ button: MouseButton, down: Bool, modifiers: [Hbb_ControlKey] = []) -> Hbb_Message {
        mouse(down ? .down : .up, button: button, modifiers: modifiers)
    }

    /// Down and up do not move the cursor, so a click starts with a move.
    public static func click(_ button: MouseButton, at point: (Int32, Int32),
                             modifiers: [Hbb_ControlKey] = []) -> [Hbb_Message] {
        [move(point.0, point.1, modifiers: modifiers),
         self.button(button, down: true, modifiers: modifiers),
         self.button(button, down: false, modifiers: modifiers)]
    }

    /// Smooth scrolling in raw wheel units (120 = one notch). Positive y
    /// scrolls up; positive x scrolls left.
    public static func scroll(dx: Int32, dy: Int32) -> Hbb_Message {
        mouse(.trackpad, x: dx, y: dy, modifiers: [])
    }

    private static func keyEvent(_ build: (inout Hbb_KeyEvent) -> Void) -> Hbb_Message {
        var m = Hbb_Message()
        m.keyEvent = .with {
            $0.mode = .legacy
            build(&$0)
        }
        return m
    }

    /// A special key pressed and released.
    public static func key(_ key: Hbb_ControlKey, modifiers: [Hbb_ControlKey] = []) -> Hbb_Message {
        keyEvent {
            $0.controlKey = key
            $0.down = true
            $0.press = true
            $0.modifiers = modifiers
        }
    }

    /// A character typed. With Ctrl/Alt/Win it is a shortcut and is sent
    /// lowercase, since the host adds Shift for an uppercase letter.
    public static func character(_ c: Character, modifiers: [Hbb_ControlKey] = []) -> Hbb_Message {
        let shortcut = !hotkeyModifiers.isDisjoint(with: modifiers)
        let scalar = (shortcut ? Character(c.lowercased()) : c).unicodeScalars.first!
        return keyEvent {
            $0.chr = scalar.value
            $0.down = true
            $0.press = true
            $0.modifiers = modifiers
        }
    }

    /// Typed text: a single code point is a key (so shortcuts work), anything
    /// longer (ß→"SS", flags, family emoji, decomposed accents) goes as text,
    /// since `chr` holds one code point.
    public static func typed(_ text: String, modifiers: [Hbb_ControlKey] = []) -> Hbb_Message {
        if text.unicodeScalars.count == 1, let c = text.first {
            return character(c, modifiers: modifiers)
        }
        return self.text(text)
    }

    /// Text inserted as is (paste, autocorrect, emoji).
    public static func text(_ text: String) -> Hbb_Message {
        keyEvent { $0.seq = text }
    }

    /// The Windows secure attention sequence; the host needs RustDesk
    /// installed as a service for it.
    public static var ctrlAltDel: Hbb_Message {
        keyEvent {
            $0.controlKey = .ctrlAltDel
            $0.down = true
        }
    }
}

/// On-screen mouse buttons held down: each press sends one down, each
/// release one up, and nothing is left pressed on the host.
public struct HeldButtons: Sendable {
    private var held: [MouseButton] = []

    public init() {}

    public func isHeld(_ button: MouseButton) -> Bool { held.contains(button) }
    public var any: Bool { !held.isEmpty }
    public var down: Set<MouseButton> { Set(held) }

    /// Down where the cursor is (the host doesn't move on a press, so it's
    /// positioned first). Nothing if it's down already.
    public mutating func press(_ button: MouseButton, at point: (Int32, Int32),
                               modifiers: [Hbb_ControlKey] = []) -> [Hbb_Message] {
        guard !held.contains(button) else { return [] }
        held.append(button)
        return [Input.move(point.0, point.1, modifiers: modifiers),
                Input.button(button, down: true, modifiers: modifiers)]
    }

    public mutating func release(_ button: MouseButton) -> [Hbb_Message] {
        guard let i = held.firstIndex(of: button) else { return [] }
        held.remove(at: i)
        return [Input.button(button, down: false)]
    }

    public mutating func releaseAll() -> [Hbb_Message] {
        defer { held.removeAll() }
        return held.map { Input.button($0, down: false) }
    }

    /// A hardware mouse's buttons are now `pressed`: ups for the ones let go,
    /// then downs for the new ones.
    public mutating func set(_ pressed: Set<MouseButton>, at point: (Int32, Int32),
                             modifiers: [Hbb_ControlKey] = []) -> [Hbb_Message] {
        var out: [Hbb_Message] = []
        for button in held where !pressed.contains(button) { out += release(button) }
        for button in MouseButton.allCases where pressed.contains(button) {
            out += press(button, at: point, modifiers: modifiers)
        }
        return out
    }
}
