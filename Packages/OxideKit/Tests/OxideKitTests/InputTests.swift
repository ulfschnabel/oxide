import CoreGraphics
import Foundation
import Testing

@testable import OxideKit

struct MouseMessageTests {
    @Test func maskIsButtonShiftedOverType() {
        #expect(Input.move(10, 20).mouseEvent.mask == 0)
        #expect(Input.button(.left, down: true).mouseEvent.mask == 0x09)
        #expect(Input.button(.left, down: false).mouseEvent.mask == 0x0A)
        #expect(Input.button(.right, down: true).mouseEvent.mask == 0x11)
        #expect(Input.button(.middle, down: false).mouseEvent.mask == 0x22)
        #expect(Input.scroll(dx: 3, dy: -40).mouseEvent.mask == 4)
    }

    @Test func moveCarriesAbsoluteHostPixels() {
        let m = Input.move(-1280, 400, modifiers: [.control]).mouseEvent
        #expect(m.x == -1280 && m.y == 400)
        #expect(m.modifiers == [.control])
    }

    @Test func clickIsMoveThenDownThenUp() {
        let events = Input.click(.right, at: (100, 200), modifiers: [.shift]).map(\.mouseEvent)
        #expect(events.map(\.mask) == [0, 0x11, 0x12])
        #expect(events[0].x == 100 && events[0].y == 200)
        // Modifiers on every event, or the host releases them in between.
        #expect(events.allSatisfy { $0.modifiers == [.shift] })
    }

    @Test func scrollKeepsTheSignsAndUnits() {
        let m = Input.scroll(dx: -5, dy: 12).mouseEvent
        #expect(m.x == -5 && m.y == 12)
    }
}

struct KeyMessageTests {
    @Test func controlKeyIsAPressInLegacyMode() {
        let k = Input.key(.return, modifiers: [.alt]).keyEvent
        #expect(k.controlKey == .return)
        #expect(k.press && k.down)
        #expect(k.mode == .legacy)
        #expect(k.modifiers == [.alt])
    }

    @Test func characterIsAUnicodeCodePoint() {
        #expect(Input.character("é").keyEvent.chr == 0xE9)
        #expect(Input.character("é").keyEvent.press)
    }

    @Test func shortcutsUseLowercaseLetters() {
        // An uppercase letter with Ctrl makes the host add Shift (Ctrl+Shift+C).
        let k = Input.character("C", modifiers: [.control]).keyEvent
        #expect(k.chr == UInt32(("c" as Unicode.Scalar).value))
        #expect(k.modifiers == [.control])
        // Without a hotkey modifier the case is the text.
        #expect(Input.character("C").keyEvent.chr == UInt32(("C" as Unicode.Scalar).value))
    }

    @Test func textIsASequence() {
        #expect(Input.text("hello 👋").keyEvent.seq == "hello 👋")
    }

    @Test func ctrlAltDelIsTheSpecialKeyHeldDown() {
        let k = Input.ctrlAltDel.keyEvent
        #expect(k.controlKey == .ctrlAltDel)
        #expect(k.down && !k.press)
    }
}

struct StickyModifierTests {
    @Test func tapAppliesOnceThenClears() {
        var mods = StickyModifiers()
        mods.tap(.control)
        #expect(mods.state(.control) == .once)
        #expect(mods.active == [.control])
        mods.consume()
        #expect(mods.active == [])
    }

    @Test func secondTapLocksThirdReleases() {
        var mods = StickyModifiers()
        mods.tap(.alt)
        mods.tap(.alt)
        #expect(mods.state(.alt) == .locked)
        mods.consume()
        #expect(mods.active == [.alt])
        mods.tap(.alt)
        #expect(mods.state(.alt) == .off)
    }

    @Test func activeIsInAStableOrder() {
        var mods = StickyModifiers()
        mods.tap(.meta)
        mods.tap(.shift)
        mods.tap(.control)
        #expect(mods.active == [.control, .shift, .meta])
    }
}

struct SoftKeyboardTests {
    @Test func typedCharacter() {
        #expect(SoftKeyboard.insert("a", modifiers: []).map(\.keyEvent) == [Input.character("a").keyEvent])
    }

    @Test func newlineAndTabAreKeys() {
        #expect(SoftKeyboard.insert("\n", modifiers: []).first?.keyEvent.controlKey == .return)
        #expect(SoftKeyboard.insert("\t", modifiers: []).first?.keyEvent.controlKey == .tab)
    }

    @Test func autocorrectAndPasteAreSequences() {
        #expect(SoftKeyboard.insert("Hello", modifiers: []).map(\.keyEvent.seq) == ["Hello"])
    }

    @Test func modifiedTextIsSentPerCharacter() {
        // Ctrl latched, then a word: each letter is a shortcut, not text.
        let keys = SoftKeyboard.insert("ab", modifiers: [.control]).map(\.keyEvent)
        #expect(keys.map(\.chr) == [97, 98])
        #expect(keys.allSatisfy { $0.modifiers == [.control] })
    }

    @Test func latchedShiftWithACharacterThatUppercasesToTwo() {
        // "ß".uppercased() is "SS": must not trap, and must type both letters.
        var shift = StickyModifiers()
        shift.tap(.shift)
        #expect(SoftKeyboard.insert("ß", modifiers: shift.active).map(\.keyEvent.seq) == ["SS"])
    }

    @Test func charactersOfSeveralCodePointsAreSentWhole() {
        for c in ["🇳🇱", "👨‍👩‍👧", "e\u{301}"] {
            #expect(SoftKeyboard.insert(c, modifiers: []).map(\.keyEvent.seq) == [c])
        }
    }

    @Test func deleteBackwardIsBackspace() {
        #expect(SoftKeyboard.deleteBackward(modifiers: [.control]).keyEvent.controlKey == .backspace)
        #expect(SoftKeyboard.deleteBackward(modifiers: [.control]).keyEvent.modifiers == [.control])
    }
}

struct HardwareKeyTests {
    // UIKeyboardHIDUsage raw values.
    @Test func specialKeysMapToControlKeys() {
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x28) == .return)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x29) == .escape)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x2A) == .backspace)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x50) == .leftArrow)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x3A) == .f1)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x3B) == .f2)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x45) == .f12)
        #expect(HardwareKeys.controlKey(forHIDUsage: 0x04) == nil)  // 'a' is text
    }

    @Test func plainTypingIsText() {
        let m = HardwareKeys.message(hidUsage: 0x04, characters: "A", charactersIgnoringModifiers: "a",
                                     modifiers: [.shift])
        #expect(m?.keyEvent.chr == UInt32(("A" as Unicode.Scalar).value))
        #expect(m?.keyEvent.modifiers == [])  // the character already says it
    }

    @Test func shortcutsCarryModifiersAndTheBareKey() {
        let m = HardwareKeys.message(hidUsage: 0x06, characters: "\u{3}", charactersIgnoringModifiers: "c",
                                     modifiers: [.control])
        #expect(m?.keyEvent.chr == UInt32(("c" as Unicode.Scalar).value))
        #expect(m?.keyEvent.modifiers == [.control])
    }

    @Test func specialKeysKeepTheirModifiers() {
        let m = HardwareKeys.message(hidUsage: 0x2B, characters: "\t", charactersIgnoringModifiers: "\t",
                                     modifiers: [.shift])
        #expect(m?.keyEvent.controlKey == .tab)
        #expect(m?.keyEvent.modifiers == [.shift])
    }

    @Test func latchedShiftUppercasesAnUnshiftedKey() {
        let m = HardwareKeys.message(hidUsage: 0x04, characters: "a", charactersIgnoringModifiers: "a",
                                     modifiers: [.shift])
        #expect(m?.keyEvent.chr == UInt32(("A" as Unicode.Scalar).value))
    }

    @Test func multiScalarHardwareCharactersAreText() {
        let m = HardwareKeys.message(hidUsage: 0x08, characters: "e\u{301}", charactersIgnoringModifiers: "e",
                                     modifiers: [])
        #expect(m?.keyEvent.seq == "e\u{301}")
    }

    @Test func modifierKeysAloneSendNothing() {
        #expect(HardwareKeys.message(hidUsage: 0xE0, characters: "", charactersIgnoringModifiers: "",
                                     modifiers: [.control]) == nil)
    }
}

struct CursorTests {
    let display = DisplayRect(x: -1920, y: 0, width: 1920, height: 1080)

    @Test func startsInTheMiddleOfTheDisplay() {
        let c = VirtualCursor(display: display)
        #expect(c.hostPoint == (-960, 540))
    }

    @Test func movesAndClampsToTheDisplay() {
        var c = VirtualCursor(display: display)
        c.move(by: 100, dy: -20)
        #expect(c.hostPoint == (-860, 520))
        c.move(by: 5000, dy: 5000)
        // The right/bottom edge itself is allowed (edge snapping on Windows).
        #expect(c.hostPoint == (0, 1080))
        c.move(by: -9000, dy: -9000)
        #expect(c.hostPoint == (-1920, 0))
    }

    @Test func viewPointsMapThroughTheLetterboxedVideo() {
        // A 1920×1080 picture fitted into a 1000×1000 view: 1000×562.5, centred.
        let content = ViewMapping.contentRect(videoSize: CGSize(width: 1920, height: 1080),
                                              in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(abs(content.height - 562.5) < 0.01)
        #expect(abs(content.minY - 218.75) < 0.01)
        let p = ViewMapping.hostPoint(CGPoint(x: 500, y: 500), content: content, display: display)
        #expect(p == (-960, 540))
        let corner = ViewMapping.hostPoint(CGPoint(x: 0, y: 218.75), content: content, display: display)
        #expect(corner == (-1920, 0))
        #expect(abs(ViewMapping.hostPixelsPerPoint(content: content, display: display) - 1.92) < 0.001)
    }

    @Test func pointsOutsideThePictureClampToIt() {
        let content = CGRect(x: 0, y: 100, width: 1920, height: 1080)
        #expect(ViewMapping.hostPoint(CGPoint(x: -50, y: 0), content: content, display: display) == (-1920, 0))
    }
}

func == (a: (Int32, Int32), b: (Int32, Int32)) -> Bool { a.0 == b.0 && a.1 == b.1 }
