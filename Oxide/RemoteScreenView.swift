import AVFoundation
import GameController
import OxideKit
import SwiftUI
import UIKit

extension UIColor {
    /// Around the remote picture: a very dark grey, softer than pure black.
    static let sessionBackground = UIColor(white: 0.11, alpha: 1)
}

/// The remote screen: video, the cursor, gestures, and the keyboard.
struct RemoteScreen: UIViewRepresentable {
    let connection: RemoteConnection
    let input: InputController
    /// A three-finger swipe: +1 for the next session, -1 for the previous.
    var onSwitch: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(videoLayer: connection.renderer, input: input)
        view.onScreenChange = { [weak connection] size, scale in
            connection?.screenChanged(size: size, scale: scale)
        }
        view.onSwitch = onSwitch
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.onSwitch = onSwitch
        view.showsButtons = input.mode == .buttons
        view.videoSize = connection.videoSize
        view.placeholder = connection.placeholder
        if input.viewport != view.laidOutViewport { view.setNeedsLayout() }
        view.cursorView.center = input.cursorInView
        view.softKeyboard = input.keyboardShown
        view.takeKeys()
    }
}

final class RemoteScreenView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    let cursorView = UIImageView(image: UIImage(systemName: "cursorarrow",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)))
    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { setNeedsLayout() } }
    }
    /// The last picture, over the live one while that isn't there.
    var placeholder: UIImage? {
        didSet {
            placeholderView.image = placeholder
            placeholderView.isHidden = placeholder == nil
        }
    }
    private let placeholderView = UIImageView()
    /// Left and right mouse buttons along the bottom, in buttons mode.
    private let buttonBar = UIStackView()
    /// The zoom the last layout used.
    private(set) var laidOutViewport = Viewport()
    /// The window's size and scale: what the remote resolution should fit.
    /// The window, not this view, so the keyboard showing doesn't count.
    var onScreenChange: ((CGSize, CGFloat) -> Void)?
    var onSwitch: ((Int) -> Void)?
    private let videoLayer: AVSampleBufferDisplayLayer
    private let input: InputController
    private lazy var accessory: UIView = {
        let host = UIHostingController(rootView: AccessoryBar(input: input))
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
        host.view.autoresizingMask = .flexibleWidth
        host.sizingOptions = .intrinsicContentSize
        return host.view
    }()

    init(videoLayer: AVSampleBufferDisplayLayer, input: InputController) {
        self.videoLayer = videoLayer
        self.input = input
        super.init(frame: .zero)
        backgroundColor = .sessionBackground
        clipsToBounds = true  // a zoomed picture is larger than the view
        layer.addSublayer(videoLayer)
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.isHidden = true
        placeholderView.isUserInteractionEnabled = false
        addSubview(placeholderView)
        cursorView.tintColor = .white
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.9
        cursorView.layer.shadowRadius = 1.5
        cursorView.layer.shadowOffset = .zero
        // The arrow's tip, not its centre, is the hot spot.
        cursorView.layer.anchorPoint = CGPoint(x: 0.3, y: 0.15)
        cursorView.isUserInteractionEnabled = false
        addSubview(cursorView)
        isMultipleTouchEnabled = true  // a finger on a button, another moving the pointer
        addButtons()
        addGestures()
        addInteraction(UIPointerInteraction(delegate: self))
        #if targetEnvironment(macCatalyst)
        watchMice()
        #endif
        softInput.onResign = { [weak self] in self?.input.keyboardShown = false }
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        addSubview(softInput)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = input.viewport.rect(fitted: fitted, in: bounds)
        laidOutViewport = input.viewport
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // follow the fingers, don't animate
        videoLayer.frame = videoSize == .zero ? bounds : content
        CATransaction.commit()
        placeholderView.frame = videoSize == .zero ? bounds : content
        input.content = content
        cursorView.center = input.cursorInView
        if let window {
            #if targetEnvironment(macCatalyst)
            // Below the title bar, where the picture goes on a Mac.
            let size = window.bounds.inset(by: window.safeAreaInsets).size
            #else
            let size = window.bounds.size
            #endif
            onScreenChange?(size, window.traitCollection.displayScale)
        }
    }

    /// Where the whole picture fits unzoomed.
    private var fitted: CGRect { ViewMapping.contentRect(videoSize: videoSize, in: bounds) }

    // MARK: Gestures

    private func addGestures() {
        // Fingers and Pencil: a mouse or trackpad's clicks are its own (`touchesBegan`).
        let touches: [NSNumber] = [UITouch.TouchType.direct, .pencil].map { $0.rawValue as NSNumber }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onePan))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = touches

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(twoPan))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedTouchTypes = touches

        // Mouse wheel and trackpad scrolling from a hardware pointer.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(twoPan))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []

        let tap = UITapGestureRecognizer(target: self, action: #selector(oneTap))
        tap.allowedTouchTypes = touches

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(secondary))
        twoTap.numberOfTouchesRequired = 2
        twoTap.allowedTouchTypes = touches

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress))
        hold.minimumPressDuration = 0.35
        hold.allowedTouchTypes = touches

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))

        // Three fingers left or right: the next or previous open session.
        let next = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        next.direction = .left
        next.numberOfTouchesRequired = 3
        next.allowedTouchTypes = touches
        let previous = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        previous.direction = .right
        previous.numberOfTouchesRequired = 3
        previous.allowedTouchTypes = touches

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovering))
        #if DEBUG
        // When the host is the Mac running the simulator, the Mac's own pointer
        // hovers over the simulator and would chase itself (`-disableHover YES`).
        hover.isEnabled = !UserDefaults.standard.bool(forKey: "disableHover")
        #endif

        tap.require(toFail: twoTap)
        pan.require(toFail: hold)
        for g in [pan, scroll, wheel, tap, twoTap, hold, pinch, next, previous, hover] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    /// With buttons the screen is a trackpad too.
    private var gestureMode: InputController.Mode { input.mode == .touch ? .touch : .trackpad }

    private var lastPan: CGPoint = .zero
    private var lastPinch: CGPoint?
    private var lastHold: CGPoint = .zero

    @objc private func onePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch (gestureMode, g.state) {
        case (.trackpad, .began):
            // The recognizer starts after some movement; don't lose it.
            input.pan(by: t)
            lastPan = t
            followCursor()
        case (.trackpad, .changed):
            input.pan(by: CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y))
            lastPan = t
            followCursor()
        case (.touch, .began):
            // Press where the finger came down, not where the drag was recognised.
            let p = g.location(in: self)
            input.dragBegan(at: CGPoint(x: p.x - t.x, y: p.y - t.y))
            input.dragMoved(to: p)
        case (.touch, .changed):
            input.dragMoved(to: g.location(in: self))
        case (.touch, .ended), (.touch, .cancelled), (.touch, .failed):
            input.dragEnded()
        default:
            break
        }
    }

    @objc private func twoPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        input.scroll(by: t)
    }

    @objc private func oneTap(_ g: UITapGestureRecognizer) {
        input.tap(at: g.location(in: self))
    }

    @objc private func secondary(_ g: UITapGestureRecognizer) {
        input.secondaryTap(at: g.location(in: self))
    }

    /// Hold then move: drag with the left button (trackpad) or a right click (touch).
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        // A finger resting while an on-screen button is held is the pointer
        // finger getting ready, not a press of its own: it only moves the pointer.
        if g.state == .began, input.buttons.any, gestureMode == .trackpad {
            lastHold = p
            return
        }
        switch (gestureMode, g.state) {
        case (.touch, .began):
            input.secondaryTap(at: p)
        case (.trackpad, .began):
            lastHold = p
            input.dragBegan(at: p)
        case (.trackpad, .changed):
            input.pan(by: CGPoint(x: p.x - lastHold.x, y: p.y - lastHold.y))
            lastHold = p
            followCursor()
        case (.trackpad, .ended), (.trackpad, .cancelled):
            input.dragEnded()
        default:
            break
        }
    }

    /// Pinch to zoom; moving both fingers meanwhile pans.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began, .changed:
            // With one finger lifted the centre jumps; pan only from two.
            if g.numberOfTouches >= 2, let last = lastPinch {
                input.viewport.pan(by: CGPoint(x: p.x - last.x, y: p.y - last.y), fitted: fitted, in: bounds)
            }
            lastPinch = g.numberOfTouches >= 2 ? p : nil
            input.viewport.zoom(by: g.scale, at: p, fitted: fitted, in: bounds)
            g.scale = 1
            layoutNow()
        default:
            lastPinch = nil
        }
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        onSwitch?(g.direction == .left ? 1 : -1)
    }

    /// A finger on a mouse button is only that: no gesture sees it.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is MouseButtonView)
    }

    // MARK: Mouse buttons

    private func addButtons() {
        let left = MouseButtonView(title: "Left") { [weak self] down in
            guard let self else { return }
            if down { self.input.buttonPressed(.left) } else { self.input.buttonReleased(.left) }
        }
        let right = MouseButtonView(title: "Right") { [weak self] down in
            guard let self else { return }
            if down { self.input.buttonPressed(.right) } else { self.input.buttonReleased(.right) }
        }
        buttonBar.axis = .horizontal
        buttonBar.distribution = .fillEqually
        buttonBar.spacing = 8
        buttonBar.addArrangedSubview(left)
        buttonBar.addArrangedSubview(right)
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.isHidden = true
        addSubview(buttonBar)
        NSLayoutConstraint.activate([
            buttonBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            buttonBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            // Above the keyboard when it's up.
            buttonBar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -8),
            buttonBar.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    /// Shown in buttons mode only.
    var showsButtons = false {
        didSet { buttonBar.isHidden = !showsButtons }
    }

    /// The view's say on its recognizers: a pinch is two fingers, three are a switch.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UIPinchGestureRecognizer { return g.numberOfTouches <= 2 }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// Trackpad mode, zoomed: keep the pointer in sight.
    private func followCursor() {
        guard input.viewport.isZoomed else { return }
        input.viewport.reveal(input.cursorInView, margin: 32, fitted: fitted, in: bounds)
        layoutNow()
    }

    private func layoutNow() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: Mouse and trackpad

    // A hardware pointer's buttons, as they go down and up: any button, held
    // as long as it's held (hover moves the pointer while none is down).
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointer(touches, event, ended: false)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointer(touches, event, ended: false)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointer(touches, event, ended: true)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointer(touches, event, ended: true)
        super.touchesCancelled(touches, with: event)
    }

    private func pointer(_ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return }
        let point = touch.location(in: self)
        // A trackpad's tap-to-click has no button in its mask: it's the left one.
        let mask = ended ? 0 : (event?.buttonMask.rawValue).map { $0 == 0 ? 1 : $0 } ?? 1
        let pressed = MouseButton.pressed(inMask: mask)
        input.pointerMoved(to: point)
        input.pointerButtons(pressed, at: point)
    }

    /// The remote pointer is drawn over the picture: this device's own one
    /// would be a second pointer on top. Over the mouse buttons it stays.
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        if !buttonBar.isHidden, buttonBar.frame.contains(request.location) { return nil }
        return defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func hovering(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            pointerInside = true
            input.pointerMoved(to: g.location(in: self))
        default:
            pointerInside = false
        }
    }

    /// The pointer is over the picture (hovering or with a button down).
    private var pointerInside = false

    #if targetEnvironment(macCatalyst)
    /// On a Mac only the primary button arrives as a touch; a secondary click
    /// becomes a context-menu request. The others come from GameController's
    /// mouse, while the pointer is over the picture in the front window.
    private func watchMice() {
        GCMouse.mice().forEach(watch)
        NotificationCenter.default.addObserver(self, selector: #selector(mouseConnected),
                                               name: .GCMouseDidConnect, object: nil)
    }

    @objc private func mouseConnected(_ note: Notification) {
        if let mouse = note.object as? GCMouse { watch(mouse) }
    }

    private func watch(_ mouse: GCMouse) {
        guard let m = mouse.mouseInput else { return }
        let buttons: [(GCControllerButtonInput?, MouseButton)] = [
            (m.rightButton, .right), (m.middleButton, .middle),
            (m.auxiliaryButtons?.first, .back), (m.auxiliaryButtons?.dropFirst().first, .forward),
        ]
        for (control, button) in buttons {
            control?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.extraButton(button, pressed: pressed) }
            }
        }
    }

    private func extraButton(_ button: MouseButton, pressed: Bool) {
        // A press elsewhere isn't for the host; a release always goes, so
        // nothing stays down.
        if pressed {
            guard pointerInside, window?.isKeyWindow == true else { return }
        }
        input.extraButton(button, down: pressed)
    }
    #endif

    // MARK: Keyboard

    // Two responders. This view takes a hardware keyboard's keys as presses,
    // which UIKit only delivers in full to a responder that isn't a text
    // input; `softInput` is one, for the on-screen keyboard. One of them is
    // first responder whenever the session is on screen.

    override var canBecomeFirstResponder: Bool { true }
    /// iOS's three-finger undo/redo swipes would take the session switch.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private lazy var softInput = SoftKeyboardInput(input: input, accessory: accessory)

    /// The on-screen keyboard is up.
    var softKeyboard = false {
        didSet {
            guard softKeyboard != oldValue else { return }
            takeKeys()
        }
    }

    /// Makes the right responder first (after a sheet with its own text
    /// field, too).
    func takeKeys() {
        guard window != nil else { return }
        let responder: UIResponder = softKeyboard ? softInput : self
        guard !responder.isFirstResponder else { return }
        // A sheet or alert over the session keeps its own focus; look again
        // once it's gone.
        if window?.rootViewController?.presentedViewController != nil {
            guard retake == nil else { return }
            retake = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.retake = nil
                self?.takeKeys()
            }
            return
        }
        responder.becomeFirstResponder()
    }

    private var retake: Task<Void, Never>?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dropPresses() }
        takeKeys()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Keys held now may never report their release here.
        if resigned { dropPresses() }
        return resigned
    }

    /// Forgets the keys held here, stops their repeats and lets go of them on
    /// the host: for when their releases won't arrive (focus moved, Spotlight,
    /// the app switcher).
    private func dropPresses() {
        repeatTasks.values.forEach { $0.cancel() }
        repeatTasks.removeAll()
        guard !handledPresses.isEmpty else { return }
        handledPresses.removeAll()
        input.releaseKeys()
    }

    @objc private func appWillResignActive() { dropPresses() }

    /// Hardware keys.
    /// The host never repeats keys, so a held key is repeated here.
    private var handledPresses: [UIPress: InputController.KeySent] = [:]
    private var repeatTasks: [UIPress: Task<Void, Never>] = [:]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key,
                  let sent = input.keyDown(hidUsage: key.keyCode.rawValue, characters: key.characters,
                                           charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                           modifiers: Self.modifiers(key.modifierFlags),
                                           capsLock: key.modifierFlags.contains(.alphaShift))
            else { unhandled.insert(press); continue }
            handledPresses[press] = sent
            if !MappedKeys.isModifier(key.keyCode.rawValue) { startRepeating(press, key: key, sent: sent) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = finish(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = finish(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func startRepeating(_ press: UIPress, key: UIKey, sent: InputController.KeySent) {
        let usage = key.keyCode.rawValue
        let capsLock = key.modifierFlags.contains(.alphaShift)
        repeatTasks[press] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled, let self, self.handledPresses[press] != nil {
                switch sent {
                case .physical:
                    self.input.keyRepeated(hidUsage: usage, capsLock: capsLock)
                case .character:
                    _ = self.input.hardwareKey(hidUsage: usage, characters: key.characters,
                                               charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                               modifiers: Self.modifiers(key.modifierFlags))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Stops repeating the presses this view handled; returns the others.
    private func finish(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let sent = handledPresses.removeValue(forKey: press) {
                repeatTasks.removeValue(forKey: press)?.cancel()
                if sent == .physical, let key = press.key {
                    input.keyUp(hidUsage: key.keyCode.rawValue, capsLock: key.modifierFlags.contains(.alphaShift))
                }
            } else {
                unhandled.insert(press)
            }
        }
        return unhandled
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> [Hbb_ControlKey] {
        var keys: [Hbb_ControlKey] = []
        if flags.contains(.control) { keys.append(.control) }
        if flags.contains(.alternate) { keys.append(.alt) }
        if flags.contains(.shift) { keys.append(.shift) }
        if flags.contains(.command) { keys.append(.meta) }
        return keys
    }
}

/// The on-screen keyboard's text input: typed text goes to the host as
/// characters. Invisible; first responder only while the keyboard is up.
final class SoftKeyboardInput: UIView, UIKeyInput {
    private let input: InputController
    private let accessory: UIView
    /// It stopped being first responder (the keyboard's dismiss key, a sheet).
    var onResign: (() -> Void)?

    init(input: InputController, accessory: UIView) {
        self.input = input
        self.accessory = accessory
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var inputAccessoryView: UIView? { accessory }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    var hasText: Bool { true }  // so Backspace always reaches deleteBackward
    func insertText(_ text: String) { input.insert(text) }
    func deleteBackward() { input.deleteBackward() }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var inlinePredictionType: UITextInlinePredictionType { get { .no } set {} }
}

/// Above the keyboard: sticky modifiers and the keys iOS doesn't have.
struct AccessoryBar: View {
    let input: InputController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { input.press(.escape) }
                key("tab") { input.press(.tab) }
                modifier("ctrl", .control)
                modifier("alt", .alt)
                modifier("win", .meta)
                modifier("shift", .shift)
                key(symbol: "arrow.left") { input.press(.leftArrow) }
                key(symbol: "arrow.up") { input.press(.upArrow) }
                key(symbol: "arrow.down") { input.press(.downArrow) }
                key(symbol: "arrow.right") { input.press(.rightArrow) }
                Menu {
                    ForEach(Array(functionKeys.enumerated()), id: \.offset) { i, k in
                        Button("F\(i + 1)") { input.press(k) }
                    }
                } label: { Text("Fn").frame(minWidth: 36, minHeight: 34) }
                .buttonStyle(.glass)
                key("del") { input.press(.delete) }
                key("ctrl·alt·del") { input.ctrlAltDel() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .font(.callout.weight(.medium))
    }

    private let functionKeys: [Hbb_ControlKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 36, minHeight: 34) }
            .buttonStyle(.glass)
    }

    private func key(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 34, minHeight: 34) }
            .buttonStyle(.glass)
    }

    private func modifier(_ title: String, _ k: Hbb_ControlKey) -> some View {
        let state = input.modifiers.state(k)
        let label = Text(title).underline(state == .locked).frame(minWidth: 40, minHeight: 34)
        return Group {
            if state == .off {
                Button { input.tapModifier(k) } label: { label }.buttonStyle(.glass)
            } else {
                Button { input.tapModifier(k) } label: { label }.buttonStyle(.glassProminent)
            }
        }
        .accessibilityValue(state == .off ? "off" : state == .once ? "once" : "locked")
    }
}

/// A mouse button on the screen: down while a finger is on it, up when it
/// lifts (or iOS cancels the touch).
final class MouseButtonView: UIView {
    private let onChange: (Bool) -> Void
    private let label = UILabel()
    private let background = UIVisualEffectView(effect: UIGlassEffect())
    private var touching = 0

    init(title: String, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 18
        background.clipsToBounds = true
        addSubview(background)
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.textAlignment = .center
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = "\(title) mouse button"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touching == 0 { set(down: true) }
        touching += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lifted(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lifted(touches) }

    private func lifted(_ touches: Set<UITouch>) {
        touching = max(touching - touches.count, 0)
        if touching == 0 { set(down: false) }
    }

    private func set(down: Bool) {
        UIView.animate(withDuration: 0.1) {
            self.background.alpha = down ? 0.5 : 1
            self.transform = down ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        }
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        onChange(down)
    }

    /// VoiceOver: a click.
    override func accessibilityActivate() -> Bool {
        onChange(true)
        onChange(false)
        return true
    }
}
