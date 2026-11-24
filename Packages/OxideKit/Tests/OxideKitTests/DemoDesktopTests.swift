import Foundation
import Testing

@testable import OxideKit

/// The demo computer's desktop: what the input the client sends does to it.
struct DemoDesktopTests {
    private func mouse(_ messages: [Hbb_Message], into desktop: inout DemoDesktop) {
        for m in messages { desktop.handle(m.mouseEvent) }
    }

    private func key(_ m: Hbb_Message, into desktop: inout DemoDesktop) {
        desktop.handle(m.keyEvent)
    }

    @Test func startsAtTheOriginalResolution() {
        let desktop = DemoDesktop()
        #expect(desktop.width == 1920 && desktop.height == 1080)
        #expect(DemoDesktop.modes.contains { $0 == (1920, 1080) })
    }

    @Test func switchesOnlyToListedModes() {
        var desktop = DemoDesktop()
        let listed = desktop.resize(width: 1024, height: 768)
        #expect(listed)
        #expect(desktop.width == 1024 && desktop.height == 768)
        let unlisted = desktop.resize(width: 1000, height: 700)
        #expect(!unlisted)
        #expect(desktop.width == 1024)
    }

    @Test func dragWithTheLeftButtonDraws() {
        var desktop = DemoDesktop()
        mouse([Input.move(100, 100), Input.button(.left, down: true), Input.move(200, 150),
               Input.move(300, 200), Input.button(.left, down: false), Input.move(400, 400)], into: &desktop)
        #expect(desktop.strokes.count == 1)
        let stroke = desktop.strokes[0]
        #expect(stroke.points.count == 3)
        #expect(desktop.pixel(stroke.points[0]) == (100, 100))
        #expect(desktop.pixel(stroke.points[2]) == (300, 200))
    }

    @Test func aClickLeavesADot() {
        var desktop = DemoDesktop()
        mouse(Input.click(.left, at: (50, 60)), into: &desktop)
        #expect(desktop.strokes.count == 1)
        #expect(desktop.strokes[0].points.count == 1)
    }

    @Test func otherButtonsLeaveMarks() {
        var desktop = DemoDesktop()
        mouse(Input.click(.right, at: (500, 300)), into: &desktop)
        mouse(Input.click(.middle, at: (600, 300)), into: &desktop)
        #expect(desktop.marks.map(\.button) == [.right, .middle])
        #expect(desktop.pixel(desktop.marks[0].point) == (500, 300))
        #expect(desktop.strokes.isEmpty)
    }

    @Test func drawingSurvivesAResolutionChange() {
        var desktop = DemoDesktop()
        mouse(Input.click(.left, at: (960, 540)), into: &desktop)
        desktop.resize(width: 1280, height: 800)
        #expect(desktop.pixel(desktop.strokes[0].points[0]) == (640, 400))
    }

    @Test func scrollingAddsUp() {
        var desktop = DemoDesktop()
        mouse([Input.scroll(dx: 0, dy: 120), Input.scroll(dx: 0, dy: 120), Input.scroll(dx: 0, dy: -60)], into: &desktop)
        #expect(desktop.scrolled == 180)
    }

    @Test func typedCharactersAndText() {
        var desktop = DemoDesktop()
        key(Input.typed("H"), into: &desktop)
        key(Input.typed("i"), into: &desktop)
        key(Input.text(" 👋🏽"), into: &desktop)
        #expect(desktop.text == "Hi 👋🏽")
    }

    @Test func backspaceReturnAndEscape() {
        var desktop = DemoDesktop()
        for c in "abc" { key(Input.typed(String(c)), into: &desktop) }
        key(Input.key(.backspace), into: &desktop)
        key(Input.key(.return), into: &desktop)
        key(Input.typed("d"), into: &desktop)
        #expect(desktop.text == "ab\nd")
        mouse(Input.click(.left, at: (10, 10)), into: &desktop)
        key(Input.key(.escape), into: &desktop)
        #expect(desktop.text.isEmpty)
        #expect(desktop.strokes.isEmpty)
    }

    @Test func shortcutsAreShownNotTyped() {
        var desktop = DemoDesktop()
        key(Input.typed("c", modifiers: [.control]), into: &desktop)
        #expect(desktop.text.isEmpty)
        #expect(desktop.lastKey == "Ctrl+C")
        key(Input.key(.leftArrow), into: &desktop)
        #expect(desktop.lastKey == "Left")
    }

    @Test func physicalKeysTypeWithShift() {
        var desktop = DemoDesktop()
        var held = HeldKeys(platform: .windows)
        func press(_ hid: Int) {
            for m in held.down(hid, capsLock: false) ?? [] { key(m, into: &desktop) }
            for m in held.up(hid, capsLock: false) { key(m, into: &desktop) }
        }
        for m in held.down(0xE1, capsLock: false) ?? [] { key(m, into: &desktop) }  // Shift down
        press(0x0B)  // H
        for m in held.up(0xE1, capsLock: false) { key(m, into: &desktop) }
        press(0x0C)  // i
        press(0x1E)  // 1
        press(0x2A)  // Backspace
        press(0x2C)  // Space
        press(0x2D)  // -
        #expect(desktop.text == "Hi -")
    }

    @Test func physicalShortcutIsShown() {
        var desktop = DemoDesktop()
        var held = HeldKeys(platform: .windows)
        for m in held.down(0xE0, capsLock: false) ?? [] { key(m, into: &desktop) }  // Ctrl
        for m in held.down(0x19, capsLock: false) ?? [] { key(m, into: &desktop) }  // V
        #expect(desktop.lastKey == "Ctrl+V")
        #expect(desktop.text.isEmpty)
    }

    /// The pointer isn't part of the picture (the client draws its own, as
    /// with a real host): moving it alone needs no new frame.
    @Test func everyVisibleChangeBumpsTheVersion() {
        var desktop = DemoDesktop()
        let start = desktop.version
        mouse([Input.move(5, 5)], into: &desktop)
        #expect(desktop.version == start)
        mouse([Input.button(.left, down: true), Input.move(50, 50)], into: &desktop)
        #expect(desktop.version > start)
        let afterDrag = desktop.version
        key(Input.typed("x"), into: &desktop)
        #expect(desktop.version > afterDrag)
        desktop.resize(width: 1024, height: 768)
        #expect(desktop.version > afterDrag + 1)
    }

    @Test func drawingIsBounded() {
        var desktop = DemoDesktop()
        mouse([Input.move(0, 0), Input.button(.left, down: true)], into: &desktop)
        for i in 0..<(DemoDesktop.maxPoints + 500) {
            desktop.handle(Input.move(Int32(i % 1900), Int32(i % 1000)).mouseEvent)
        }
        #expect(desktop.strokes.reduce(0) { $0 + $1.points.count } <= DemoDesktop.maxPoints)
    }

    @Test func pointsOutsideTheDisplayAreClamped() {
        var desktop = DemoDesktop()
        mouse([Input.move(-50, 5000)], into: &desktop)
        #expect(desktop.pixel(desktop.cursor) == (0, 1079))
    }

    @Test func escapeWhileDrawingThenMovingIsFine() {
        var desktop = DemoDesktop()
        mouse([Input.move(10, 10), Input.button(.left, down: true), Input.move(20, 20)], into: &desktop)
        key(Input.key(.escape), into: &desktop)
        mouse([Input.move(30, 30), Input.button(.left, down: false)], into: &desktop)
        #expect(desktop.strokes.isEmpty)
    }

    /// A new connection starts with nothing held (the old one's releases
    /// may never have arrived).
    @Test func releasingInputUnsticksKeysAndButtons() {
        var desktop = DemoDesktop()
        var held = HeldKeys(platform: .windows)
        for m in held.down(0xE0, capsLock: false) ?? [] { key(m, into: &desktop) }  // Ctrl stays down
        mouse([Input.move(10, 10), Input.button(.left, down: true)], into: &desktop)
        desktop.releaseInput()
        var fresh = HeldKeys(platform: .windows)
        for m in fresh.down(0x04, capsLock: false) ?? [] { key(m, into: &desktop) }  // a
        #expect(desktop.text == "a")
        let strokes = desktop.strokes.count
        mouse([Input.move(50, 50)], into: &desktop)
        #expect(desktop.strokes.count == strokes)
        #expect(desktop.strokes.last?.points.count == 1)
    }
}
