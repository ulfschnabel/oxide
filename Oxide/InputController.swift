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
    enum Mode { case trackpad, touch }

    var mode: Mode = UserDefaults.standard.string(forKey: SettingsKey.inputMode) == InputMode.touch.rawValue
        ? .touch : .trackpad
    var keyboardShown = false
    private(set) var modifiers = StickyModifiers()
    private(set) var cursor: VirtualCursor
    /// Where the host's picture sits in the view; set by the view on layout.
    var content: CGRect = .zero

    /// Trackpad: host pixels per finger point, on top of the picture scale.
    private var trackpadSpeed: Double { UserDefaults.standard.double(forKey: SettingsKey.pointerSpeed) }
    /// Two-finger scroll: wheel units per finger point.
    private var scrollSpeed: Double { UserDefaults.standard.double(forKey: SettingsKey.scrollSpeed) }

    private let sendMessages: ([Hbb_Message]) -> Void
    private var dragging = false

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

    /// A hardware pointer pressed down where it is (hover already moved the cursor).
    func pointerDragBegan() {
        dragging = true
        send([Input.button(.left, down: true, modifiers: takeModifiers())])
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
        guard !dragging else { return }
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

    /// A hardware key; returns false for keys it doesn't send (modifier keys).
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
