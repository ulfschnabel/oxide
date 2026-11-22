import CoreGraphics
import Foundation
import OxideKit
import Observation
import os

let inputLog = Logger(subsystem: "com.ulfschnabel.duodesk", category: "input")

/// Turns gestures, keys and the accessory bar into input messages, and keeps
/// the cursor the trackpad mode moves.
@MainActor @Observable
final class InputController {
    /// Trackpad; trackpad with on-screen mouse buttons; touch.
    enum Mode: CaseIterable { case trackpad, buttons, touch }

    var mode: Mode = {
        switch UserDefaults.standard.string(forKey: SettingsKey.inputMode) {
        case InputMode.touch.rawValue: .touch
        case InputMode.buttons.rawValue: .buttons
        default: .trackpad
        }
    }()

    /// Fingers move the pointer (trackpad, buttons) rather than act where they touch.
    var movesPointer: Bool { mode != .touch }

    /// The next mode, for the toolbar button.
    func cycleMode() {
        let all = Mode.allCases
        mode = all[(all.firstIndex(of: mode)! + 1) % all.count]
        if mode == .touch { releaseButtons() }
    }
    var keyboardShown = false
    private(set) var modifiers = StickyModifiers()
    private(set) var cursor: VirtualCursor
    /// Where the host's picture sits in the view; set by the view on layout.
    var content: CGRect = .zero
    /// The zoom into the picture; kept for the whole session.
    var viewport = Viewport()

    /// Trackpad: host pixels per finger point, on top of the picture scale.
    private var trackpadSpeed: Double { UserDefaults.standard.double(forKey: SettingsKey.pointerSpeed) }
    /// Two-finger scroll: wheel units per finger point.
    private var scrollSpeed: Double { UserDefaults.standard.double(forKey: SettingsKey.scrollSpeed) }

    private let sendMessages: ([Hbb_Message]) -> Void
    private var dragging = false
    /// The on-screen mouse buttons held down.
    private(set) var buttons = HeldButtons()
    /// A hardware mouse's buttons held down.
    private var pointerButtons = HeldButtons()
    /// Hardware keys down on the host (physical-keys mode).
    private var keys = HeldKeys(platform: .other)

    /// The host's platform, from the login: it decides the key codes.
    var platform: HostPlatform {
        get { keys.platform }
        set {
            guard newValue != keys.platform else { return }
            send(keys.releaseAll())
            keys = HeldKeys(platform: newValue)
        }
    }

    init(display: DisplayRect, send: @escaping ([Hbb_Message]) -> Void) {
        cursor = VirtualCursor(display: display)
        sendMessages = send
    }

    private func send(_ messages: [Hbb_Message]) {
        for m in messages {
            switch m.union {
            case .mouseEvent(let e): inputLog.debug("mouse mask=\(e.mask) x=\(e.x) y=\(e.y)")
            case .keyEvent(let e): inputLog.debug("key \(String(describing: e.union))")
            default: break
            }
        }
        sendMessages(messages)
    }

    var display: DisplayRect {
        get { cursor.display }
        set { cursor.display = newValue }
    }

    /// The cursor's position in the view, for drawing it.
    var cursorInView: CGPoint {
        ViewMapping.viewPoint(cursor.hostPoint, content: content, display: display)
    }

    private func host(_ point: CGPoint) -> (Int32, Int32) {
        ViewMapping.hostPoint(point, content: content, display: display)
    }

    /// Modifiers for the next event; one-shot ones are used up by keys and clicks.
    private func takeModifiers(plus extra: [Hbb_ControlKey] = []) -> [Hbb_ControlKey] {
        let active = StickyModifiers.all.filter { modifiers.active.contains($0) || extra.contains($0) }
        modifiers.consume()
        return active
    }

    // MARK: Pointer

    /// One finger moving: the cursor in trackpad mode, a drag in touch mode.
    func pan(by delta: CGPoint) {
        let scale = ViewMapping.hostPixelsPerPoint(content: content, display: display) * trackpadSpeed
        cursor.move(by: delta.x * scale, dy: delta.y * scale)
        send([Input.move(cursor.hostPoint.0, cursor.hostPoint.1, modifiers: dragging ? modifiers.active : [])])
    }

    func tap(at point: CGPoint) {
        if mode == .touch { cursor.move(to: host(point)) }
        send(Input.click(.left, at: cursor.hostPoint, modifiers: takeModifiers()))
    }

    func secondaryTap(at point: CGPoint) {
        if mode == .touch { cursor.move(to: host(point)) }
        send(Input.click(.right, at: cursor.hostPoint, modifiers: takeModifiers()))
    }

    /// A hardware mouse or trackpad pointer hovering: it is the cursor.
    func pointerMoved(to point: CGPoint) {
        cursor.move(to: host(point))
        send([Input.move(cursor.hostPoint.0, cursor.hostPoint.1)])
    }

    func dragBegan(at point: CGPoint) {
        if mode == .touch { cursor.move(to: host(point)) }
        dragging = true
        let mods = takeModifiers()
        send([Input.move(cursor.hostPoint.0, cursor.hostPoint.1, modifiers: mods),
              Input.button(.left, down: true, modifiers: mods)])
    }

    /// A hardware mouse's buttons changed: each goes down and up on the host
    /// as it does here, wherever the pointer is.
    func pointerButtons(_ pressed: Set<MouseButton>, at point: CGPoint) {
        cursor.move(to: host(point))
        // The bar's modifiers go with a new press, and are used up by it.
        let pressing = !pressed.isSubset(of: pointerButtons.down)
        send(pointerButtons.set(pressed, at: cursor.hostPoint, modifiers: pressing ? takeModifiers() : []))
    }

    func dragMoved(to point: CGPoint) {
        cursor.move(to: host(point))
        send([Input.move(cursor.hostPoint.0, cursor.hostPoint.1)])
    }

    func dragEnded() {
        guard dragging else { return }
        dragging = false
        send([Input.button(.left, down: false)])
    }

    /// An on-screen mouse button pressed: down at the cursor, held until released.
    func buttonPressed(_ button: MouseButton) {
        let mods = takeModifiers()
        send(buttons.press(button, at: cursor.hostPoint, modifiers: mods))
    }

    func buttonReleased(_ button: MouseButton) {
        send(buttons.release(button))
    }

    /// Nothing stays pressed on the host: a drag or held buttons. For when
    /// the session is hidden, paused or closed.
    func releaseAll() {
        dragEnded()
        releaseButtons()
        send(pointerButtons.releaseAll())
        send(keys.releaseAll())
    }

    private func releaseButtons() {
        send(buttons.releaseAll())
    }

    /// Two fingers moving: content follows the fingers.
    func scroll(by delta: CGPoint) {
        let dx = Int32((delta.x * scrollSpeed).rounded())
        let dy = Int32((delta.y * scrollSpeed).rounded())
        guard dx != 0 || dy != 0 else { return }
        send([Input.scroll(dx: dx, dy: dy)])
    }

    /// The host moved its cursor (someone at the machine, or the host warping it).
    func hostCursorMoved(x: Int32, y: Int32) {
        inputLog.debug("host cursor at \(x),\(y) (display \(self.display.width)x\(self.display.height))")
        // During a drag the cursor is ours; the host's reports lag behind.
        guard !dragging, !buttons.any, !pointerButtons.any else { return }
        cursor.move(to: (x, y))
    }

    // MARK: Keys

    func tapModifier(_ key: Hbb_ControlKey) {
        modifiers.tap(key)
    }

    func insert(_ text: String) {
        send(SoftKeyboard.insert(text, modifiers: takeModifiers()))
    }

    func deleteBackward() {
        send([SoftKeyboard.deleteBackward(modifiers: takeModifiers())])
    }

    func press(_ key: Hbb_ControlKey) {
        send([Input.key(key, modifiers: takeModifiers())])
    }

    func ctrlAltDel() {
        send([Input.ctrlAltDel])
    }

    /// How a hardware key went to the host, if it did.
    enum KeySent { case physical, character }

    /// A hardware key went down. Physical keys mode sends it as the host's own
    /// key, held until `keyUp`; otherwise (or with no such key on the host) as
    /// a character.
    func keyDown(hidUsage: Int, characters: String, charactersIgnoringModifiers: String,
                 modifiers held: [Hbb_ControlKey], capsLock: Bool) -> KeySent? {
        if physicalKeys,
           let messages = keys.down(hidUsage, latching: StickyModifiers.all.filter { modifiers.active.contains($0) },
                                    capsLock: capsLock) {
            // A modifier key on its own doesn't use up the bar's modifiers.
            if !MappedKeys.isModifier(hidUsage) { modifiers.consume() }
            send(messages)
            return .physical
        }
        return hardwareKey(hidUsage: hidUsage, characters: characters,
                           charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: held) ? .character : nil
    }

    /// A physical key held down: the host's apps see a repeat.
    func keyRepeated(hidUsage: Int, capsLock: Bool) {
        if let message = keys.repeated(hidUsage, capsLock: capsLock) { send([message]) }
    }

    func keyUp(hidUsage: Int, capsLock: Bool) {
        send(keys.up(hidUsage, capsLock: capsLock))
    }

    /// Lets go of every physical key down on the host.
    func releaseKeys() {
        send(keys.releaseAll())
    }

    private var physicalKeys: Bool {
        UserDefaults.standard.string(forKey: SettingsKey.keyboardMode) != KeyboardMode.characters.rawValue
    }

    /// A hardware key as a character; returns false for keys it doesn't send (modifier keys).
    func hardwareKey(hidUsage: Int, characters: String, charactersIgnoringModifiers: String,
                     modifiers held: [Hbb_ControlKey]) -> Bool {
        let mods = StickyModifiers.all.filter { modifiers.active.contains($0) || held.contains($0) }
        guard let message = HardwareKeys.message(
            hidUsage: hidUsage, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: mods)
        else { return false }
        modifiers.consume()
        send([message])
        return true
    }
}
