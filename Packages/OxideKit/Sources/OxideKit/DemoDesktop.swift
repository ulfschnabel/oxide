import Foundation

/// The desktop of Oxide's demo computer, a host inside the app for trying
/// Oxide without a RustDesk computer. It reacts to input the way a person
/// can see: the left button draws, other buttons leave marks, keys type
/// text, shortcuts and special keys are named. Positions are kept as
/// fractions of the display, so a resolution change keeps the drawing.
public struct DemoDesktop: Sendable {
    /// A point as a fraction of the display's width and height.
    public struct Point: Sendable, Equatable {
        public var x, y: Double
    }

    public struct Stroke: Sendable, Equatable {
        public var points: [Point]
    }

    public struct Mark: Sendable, Equatable {
        public var point: Point
        public var button: MouseButton
    }

    /// The modes the demo display offers (a Windows-like list).
    public static let modes: [(Int, Int)] = [
        (3840, 2160), (2560, 1600), (2560, 1440), (1920, 1200), (1920, 1080), (1680, 1050), (1600, 900),
        (1440, 900), (1366, 768), (1280, 1024), (1280, 800), (1280, 720), (1024, 768), (800, 600),
    ]
    public static let original = (1920, 1080)
    public static let maxPoints = 20_000
    static let maxText = 4_000
    static let maxMarks = 40

    public private(set) var width = DemoDesktop.original.0
    public private(set) var height = DemoDesktop.original.1
    public private(set) var cursor = Point(x: 0.5, y: 0.5)
    public private(set) var strokes: [Stroke] = []
    public private(set) var marks: [Mark] = []
    public private(set) var text = ""
    /// Scrolling, in wheel units (120 a notch; positive is up).
    public private(set) var scrolled = 0
    /// The last shortcut or special key, named ("Ctrl+C", "Left").
    public private(set) var lastKey: String?
    /// Goes up with every change to what the desktop looks like.
    public private(set) var version = 0

    private var drawing = false
    /// Physical modifier keys held (map mode), as HID usages.
    private var heldModifiers: Set<Int> = []

    public init() {}

    /// Lets go of every key and button: a new connection starts with
    /// nothing held, whatever releases the last one didn't send.
    public mutating func releaseInput() {
        drawing = false
        heldModifiers = []
    }

    /// Where a point is in the current resolution's pixels.
    public func pixel(_ p: Point) -> (Int, Int) {
        (Int((p.x * Double(width)).rounded(.down)), Int((p.y * Double(height)).rounded(.down)))
    }

    /// Switches to a listed mode; false (and no change) for any other size.
    @discardableResult
    public mutating func resize(width: Int, height: Int) -> Bool {
        guard Self.modes.contains(where: { $0 == (width, height) }) else { return false }
        if (width, height) != (self.width, self.height) {
            self.width = width
            self.height = height
            version += 1
        }
        return true
    }

    // MARK: Mouse

    public mutating func handle(_ event: Hbb_MouseEvent) {
        let type = event.mask & 7
        let button = MouseButton(rawValue: event.mask >> 3)
        switch type {
        case 0:  // move
            cursor = point(event.x, event.y)
            if drawing, !strokes.isEmpty {
                strokes[strokes.count - 1].points.append(cursor)
                trim()
                version += 1
            }
        case 1:  // down
            switch button {
            case .left:
                drawing = true
                strokes.append(Stroke(points: [cursor]))
                trim()
            case let other?:
                marks.append(Mark(point: cursor, button: other))
                if marks.count > Self.maxMarks { marks.removeFirst(marks.count - Self.maxMarks) }
            case nil:
                return
            }
            version += 1
        case 2:  // up
            if button == .left { drawing = false }
        case 3, 4:  // wheel, trackpad scroll
            scrolled += Int(event.y)
            version += 1
        default:
            break
        }
    }

    private func point(_ x: Int32, _ y: Int32) -> Point {
        let px = min(max(Int(x), 0), width - 1)
        let py = min(max(Int(y), 0), height - 1)
        // The pixel's own fraction, nudged inside it so it maps back exactly.
        return Point(x: (Double(px) + 0.5) / Double(width), y: (Double(py) + 0.5) / Double(height))
    }

    /// Drops the oldest drawing past the limit.
    private mutating func trim() {
        var total = strokes.reduce(0) { $0 + $1.points.count }
        while total > Self.maxPoints, !strokes.isEmpty {
            let excess = total - Self.maxPoints
            if strokes[0].points.count <= excess || strokes.count > 1 && strokes[0].points.count <= excess {
                total -= strokes.removeFirst().points.count
            } else {
                strokes[0].points.removeFirst(excess)
                total -= excess
            }
        }
    }

    // MARK: Keys

    public mutating func handle(_ event: Hbb_KeyEvent) {
        if event.mode == .map {
            mapped(event)
            return
        }
        switch event.union {
        case .seq(let s)?:
            type(s)
        case .chr(let c)?:
            guard event.down || event.press, let scalar = Unicode.Scalar(c) else { return }
            let shortcut = event.modifiers.filter { Input.hotkeyModifiers.contains($0) }
            if shortcut.isEmpty {
                type(String(Character(scalar)))
            } else {
                name(shortcut.map(Self.name) + [String(Character(scalar)).uppercased()])
            }
        case .controlKey(let key)?:
            guard event.down || event.press else { return }
            control(key, modifiers: event.modifiers)
        default:
            break
        }
    }

    private mutating func control(_ key: Hbb_ControlKey, modifiers: [Hbb_ControlKey]) {
        let shortcut = modifiers.filter { Input.hotkeyModifiers.contains($0) }
        guard shortcut.isEmpty else {
            name(shortcut.map(Self.name) + [Self.name(key)])
            return
        }
        switch key {
        case .backspace: erase()
        case .return: type("\n")
        case .tab: type("    ")
        case .escape: clear()
        default: name([Self.name(key)])
        }
    }

    /// Map mode: Windows scan codes, down and up, modifiers as keys of their own.
    private mutating func mapped(_ event: Hbb_KeyEvent) {
        guard case .chr(let raw)? = event.union, let hid = Self.hidUsage(windowsCode: Int32(bitPattern: raw))
        else { return }
        if MappedKeys.isModifier(hid) {
            if event.down { heldModifiers.insert(hid) } else { heldModifiers.remove(hid) }
            return
        }
        guard event.down else { return }
        let ctrl = !heldModifiers.isDisjoint(with: [0xE0, 0xE4])
        let alt = !heldModifiers.isDisjoint(with: [0xE2, 0xE6])
        let win = !heldModifiers.isDisjoint(with: [0xE3, 0xE7])
        let shift = !heldModifiers.isDisjoint(with: [0xE1, 0xE5])
        let caps = event.modifiers.contains(.capsLock)
        if ctrl || alt || win {
            let mods = (ctrl ? ["Ctrl"] : []) + (alt ? ["Alt"] : []) + (win ? ["Win"] : [])
            name(mods + [Self.keyName(hid) ?? Self.character(hid, shift: true, caps: false) ?? "?"])
            return
        }
        switch hid {
        case 0x28, 0x58: type("\n")
        case 0x29: clear()
        case 0x2A: erase()
        case 0x2B: type("    ")
        default:
            if let c = Self.character(hid, shift: shift, caps: caps) {
                type(c)
            } else {
                name([Self.keyName(hid) ?? String(format: "Key 0x%02X", hid)])
            }
        }
    }

    private mutating func type(_ s: String) {
        text += s
        if text.count > Self.maxText { text.removeFirst(text.count - Self.maxText) }
        lastKey = nil
        version += 1
    }

    private mutating func erase() {
        if !text.isEmpty { text.removeLast() }
        version += 1
    }

    private mutating func clear() {
        drawing = false
        text = ""
        strokes = []
        marks = []
        scrolled = 0
        lastKey = "Esc: cleared"
        version += 1
    }

    private mutating func name(_ parts: [String]) {
        lastKey = parts.joined(separator: "+")
        version += 1
    }

    // MARK: Names and layouts

    static func name(_ key: Hbb_ControlKey) -> String {
        switch key {
        case .control, .rcontrol: "Ctrl"
        case .alt, .ralt: "Alt"
        case .meta, .rwin: "Win"
        case .shift, .rshift: "Shift"
        case .leftArrow: "Left"
        case .rightArrow: "Right"
        case .upArrow: "Up"
        case .downArrow: "Down"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .delete: "Delete"
        case .home: "Home"
        case .end: "End"
        case .escape: "Esc"
        case .return: "Return"
        case .backspace: "Backspace"
        case .tab: "Tab"
        case .ctrlAltDel: "Ctrl+Alt+Del"
        default:
            // f1 → F1, capsLock → CapsLock
            String(describing: key).prefix(1).uppercased() + String(describing: key).dropFirst()
        }
    }

    private static let windowsToHID: [Int32: Int] = {
        var out: [Int32: Int] = [:]
        for (hid, code) in KeyCodes.windows where out[code] == nil || hid < out[code]! { out[code] = hid }
        return out
    }()

    static func hidUsage(windowsCode: Int32) -> Int? { windowsToHID[windowsCode] }

    /// A US layout.
    static func character(_ hid: Int, shift: Bool, caps: Bool) -> String? {
        switch hid {
        case 0x04...0x1D:
            let c = Character(Unicode.Scalar(UInt8(0x61 + hid - 0x04)))
            return shift != caps ? c.uppercased() : String(c)
        case 0x1E...0x27:
            let i = hid - 0x1E
            return String(Array(shift ? "!@#$%^&*()" : "1234567890")[i])
        case 0x2C: return " "
        default:
            let pairs: [Int: (String, String)] = [
                0x2D: ("-", "_"), 0x2E: ("=", "+"), 0x2F: ("[", "{"), 0x30: ("]", "}"), 0x31: ("\\", "|"),
                0x33: (";", ":"), 0x34: ("'", "\""), 0x35: ("`", "~"), 0x36: (",", "<"), 0x37: (".", ">"),
                0x38: ("/", "?"), 0x54: ("/", "/"), 0x55: ("*", "*"), 0x56: ("-", "-"), 0x57: ("+", "+"),
                0x59: ("1", "1"), 0x5A: ("2", "2"), 0x5B: ("3", "3"), 0x5C: ("4", "4"), 0x5D: ("5", "5"),
                0x5E: ("6", "6"), 0x5F: ("7", "7"), 0x60: ("8", "8"), 0x61: ("9", "9"), 0x62: ("0", "0"),
                0x63: (".", "."),
            ]
            return pairs[hid].map { shift ? $0.1 : $0.0 }
        }
    }

    static func keyName(_ hid: Int) -> String? {
        switch hid {
        case 0x3A...0x45: "F\(hid - 0x39)"
        case 0x4F: "Right"
        case 0x50: "Left"
        case 0x51: "Down"
        case 0x52: "Up"
        case 0x49: "Insert"
        case 0x4A: "Home"
        case 0x4B: "Page Up"
        case 0x4C: "Delete"
        case 0x4D: "End"
        case 0x4E: "Page Down"
        case 0x39: "CapsLock"
        case 0x46: "Print Screen"
        case 0x28: "Return"
        case 0x29: "Esc"
        case 0x2A: "Backspace"
        case 0x2B: "Tab"
        default: nil
        }
    }
}
