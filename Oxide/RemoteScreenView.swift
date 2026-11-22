import AVFoundation
import OxideKit
import SwiftUI
import UIKit

/// The remote screen: video, the cursor, gestures, and the keyboard.
struct RemoteScreen: UIViewRepresentable {
    let connection: RemoteConnection
    let input: InputController

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(videoLayer: connection.renderer, input: input)
        view.onScreenChange = { [weak connection] size, scale in
            connection?.screenChanged(size: size, scale: scale)
        }
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.videoSize = connection.videoSize
        view.placeholder = connection.placeholder
        if input.viewport != view.laidOutViewport { view.setNeedsLayout() }
        view.cursorView.center = input.cursorInView
        if input.keyboardShown != view.isFirstResponder {
            if input.keyboardShown { view.becomeFirstResponder() } else { view.resignFirstResponder() }
        }
    }
}

final class RemoteScreenView: UIView, UIKeyInput {
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
    /// The zoom the last layout used.
    private(set) var laidOutViewport = Viewport()
    /// The window's size and scale: what the remote resolution should fit.
    /// The window, not this view, so the keyboard showing doesn't count.
    var onScreenChange: ((CGSize, CGFloat) -> Void)?
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
        backgroundColor = .black
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
        addGestures()
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
            onScreenChange?(window.bounds.size, window.traitCollection.displayScale)
        }
    }

    /// Where the whole picture fits unzoomed.
    private var fitted: CGRect { ViewMapping.contentRect(videoSize: videoSize, in: bounds) }

    // MARK: Gestures

    private func addGestures() {
        let touches: [NSNumber] = [UITouch.TouchType.direct.rawValue as NSNumber]
        let pointerClicks: [NSNumber] = [UITouch.TouchType.direct, .indirectPointer].map { $0.rawValue as NSNumber }

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
        tap.allowedTouchTypes = pointerClicks

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(secondary))
        twoTap.numberOfTouchesRequired = 2
        twoTap.allowedTouchTypes = touches

        let rightClick = UITapGestureRecognizer(target: self, action: #selector(secondary))
        rightClick.buttonMaskRequired = .secondary
        rightClick.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress))
        hold.minimumPressDuration = 0.35
        hold.allowedTouchTypes = touches

        // A hardware mouse or trackpad dragging with the button down.
        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged))
        pointerDrag.maximumNumberOfTouches = 1
        pointerDrag.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovering))
        #if DEBUG
        // When the host is the Mac running the simulator, the Mac's own pointer
        // hovers over the simulator and would chase itself (`-disableHover YES`).
        hover.isEnabled = !UserDefaults.standard.bool(forKey: "disableHover")
        #endif

        tap.require(toFail: twoTap)
        pan.require(toFail: hold)
        for g in [pan, scroll, wheel, tap, twoTap, rightClick, hold, pointerDrag, pinch, hover] {
            addGestureRecognizer(g)
        }
    }

    private var lastPan: CGPoint = .zero
    private var lastPinch: CGPoint?
    private var lastHold: CGPoint = .zero

    @objc private func onePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch (input.mode, g.state) {
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
        switch (input.mode, g.state) {
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

    @objc private func pointerDragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            input.pointerMoved(to: CGPoint(x: p.x - t.x, y: p.y - t.y))
            input.pointerDragBegan()
            input.pointerMoved(to: p)
        case .changed:
            input.pointerMoved(to: p)
        case .ended, .cancelled, .failed:
            input.dragEnded()
        default:
            break
        }
    }

    @objc private func hovering(_ g: UIHoverGestureRecognizer) {
        if g.state == .changed || g.state == .began {
            input.pointerMoved(to: g.location(in: self))
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

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

    /// Hardware keys: handled here, so they don't also arrive as insertText.
    /// The host never repeats keys, so a held key is repeated here.
    private var handledPresses = Set<UIPress>()
    private var repeatTasks: [UIPress: Task<Void, Never>] = [:]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, send(key) else { unhandled.insert(press); continue }
            handledPresses.insert(press)
            startRepeating(press, key: key)
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

    private func send(_ key: UIKey) -> Bool {
        input.hardwareKey(hidUsage: key.keyCode.rawValue, characters: key.characters,
                          charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                          modifiers: Self.modifiers(key.modifierFlags))
    }

    private func startRepeating(_ press: UIPress, key: UIKey) {
        repeatTasks[press] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled, let self, self.handledPresses.contains(press) {
                _ = self.send(key)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Stops repeating the presses this view handled; returns the others.
    private func finish(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            if handledPresses.remove(press) != nil {
                repeatTasks.removeValue(forKey: press)?.cancel()
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
