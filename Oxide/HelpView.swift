import SwiftUI

/// How to drive the remote computer: gestures, keyboard, mouse.
struct HelpView: View {
    var body: some View {
        List {
            Section {
                Text("Like a laptop trackpad: your finger moves the remote pointer, wherever you touch. Best for precise work.")
                    .foregroundStyle(.secondary)
                gesture("hand.point.up.left", "Drag one finger", "Move the pointer")
                gesture("hand.tap", "Tap", "Click at the pointer")
                gesture("hand.tap", "Tap with two fingers", "Right-click")
                gesture("hand.draw", "Drag two fingers", "Scroll")
                gesture("hand.point.up.braille", "Touch and hold, then drag", "Drag with the button held (select text, move windows)")
            } header: {
                Label("Trackpad mode", systemImage: "rectangle.and.hand.point.up.left")
            }

            Section {
                Text("Trackpad mode with Left and Right mouse buttons along the bottom, like a laptop.")
                    .foregroundStyle(.secondary)
                gesture("computermouse", "Hold Left, move another finger", "Drag: select text, move windows, draw")
                gesture("computermouse", "Hold Right, move another finger", "Right-drag")
                gesture("hand.tap", "Tap a button", "Click; tapping the trackpad area clicks too")
            } header: {
                Label("Trackpad + buttons", systemImage: "computermouse")
            }

            Section {
                Text("Like a touchscreen: you act where you touch. Quick for buttons and links.")
                    .foregroundStyle(.secondary)
                gesture("hand.tap", "Tap", "Click there")
                gesture("hand.point.up.left", "Drag one finger", "Drag from there")
                gesture("hand.tap", "Touch and hold", "Right-click there")
                gesture("hand.draw", "Drag two fingers", "Scroll")
            } header: {
                Label("Touch mode", systemImage: "hand.point.up.left")
            } footer: {
                Text("Switch modes with the mode button at the top of the screen: trackpad, trackpad + buttons, touch.")
            }

            Section {
                gesture("keyboard", "Keyboard button", "Show or hide the keyboard")
                gesture("command", "ctrl, alt, win, shift", "Tap once: the next key gets it. Tap twice: it stays on (underlined). Tap again: off.")
                gesture("arrow.up.arrow.down", "esc, tab, arrows, Fn, del", "Keys the iOS keyboard doesn't have; swipe the bar for more")
                gesture("lock.shield", "ctrl·alt·del", "The Windows security screen (the remote computer needs RustDesk installed as a service)")
            } header: {
                Label("Keyboard", systemImage: "keyboard")
            } footer: {
                Text("Shortcuts: tap ctrl, then type the letter: ctrl + c copies. On a Mac host, win is the ⌘ key.")
            }

            Section {
                gesture("keyboard.badge.ellipsis", "Hardware keyboard", "Works like a keyboard plugged into the remote computer, no Keyboard button needed: keys can be held, and its layout applies. Settings → Hardware Keyboard switches to characters for a different layout.")
                gesture("computermouse", "Mouse or trackpad", "The pointer is the remote pointer: every button goes down and up as you press it, so clicks, right-clicks, middle-clicks and drags with any button work. Scrolling too.")
            } header: {
                Label("Keyboard and mouse", systemImage: "computermouse")
            }

            Section {
                gesture("plus.magnifyingglass", "Pinch", "Zoom in up to 4×; move both fingers while pinching to look around")
                gesture("arrow.down.right.and.arrow.up.left", "Fit button", "Back to the whole screen (or pinch out)")
                gesture("cursorarrow.motionlines", "Pointer at the edge", "In trackpad mode the zoomed view follows the pointer")
                gesture("rectangle.portrait.rotate", "Rotate, fold or resize", "With Settings → Match the remote screen on, the remote computer switches to a resolution that fits; it switches back when you disconnect")
                gesture("rectangle.stack", "Computers button", "Back to the list with the session left open, to open another")
                gesture("hand.draw", "Swipe three fingers left or right", "Switch between open sessions")
                gesture("xmark", "Close button", "Disconnect this session")
                gesture("arrow.triangle.2.circlepath", "Switching apps", "The session stays up for a while (Settings → In the Background), then pauses and reconnects when you come back")
            } header: {
                Label("Screen", systemImage: "display")
            }
        }
        .navigationTitle("Gestures & keyboard")
    }

    private func gesture(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

#Preview {
    NavigationStack { HelpView() }
}
