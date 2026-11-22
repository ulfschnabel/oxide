import Testing

@testable import OxideKit

struct MappedKeysTests {
    @Test func knowsTheHostPlatformByItsName() {
        #expect(HostPlatform(peerPlatform: "Windows") == .windows)
        #expect(HostPlatform(peerPlatform: "Mac OS") == .macOS)
        #expect(HostPlatform(peerPlatform: "Linux") == .linux)
        #expect(HostPlatform(peerPlatform: "Android") == .other)
        #expect(HostPlatform(peerPlatform: "") == .other)
    }

    @Test func keysBecomeTheHostsOwnCodes() {
        // HID usage → Windows scan code / macOS virtual key / X11 key code.
        #expect(MappedKeys.code(hidUsage: 0x04, on: .windows) == 0x1E)  // A
        #expect(MappedKeys.code(hidUsage: 0x52, on: .windows) == 0xE048)  // Up: extended
        #expect(MappedKeys.code(hidUsage: 0xE3, on: .windows) == 0xE05B)  // left Win/Cmd
        #expect(MappedKeys.code(hidUsage: 0x04, on: .macOS) == 0)  // A is 0 on a Mac
        #expect(MappedKeys.code(hidUsage: 0x52, on: .macOS) == 0x7E)
        #expect(MappedKeys.code(hidUsage: 0x04, on: .linux) == 38)
        #expect(MappedKeys.code(hidUsage: 0x52, on: .linux) == 111)
    }

    @Test func keysWithoutACodeAreLeftToLegacyMode() {
        #expect(MappedKeys.code(hidUsage: 0x48, on: .windows) == nil)  // Pause: no scan code
        #expect(MappedKeys.code(hidUsage: 0x04, on: .other) == nil)
        #expect(MappedKeys.code(hidUsage: 0x00, on: .windows) == nil)
    }

    @Test func aKeyGoesDownAndUpAsItself() {
        let down = MappedKeys.message(hidUsage: 0x04, down: true, on: .windows, capsLock: false)
        #expect(down?.keyEvent.mode == .map)
        #expect(down?.keyEvent.chr == 0x1E)
        #expect(down?.keyEvent.down == true)
        #expect(down?.keyEvent.press == false)
        #expect(down?.keyEvent.modifiers == [])
        let up = MappedKeys.message(hidUsage: 0x04, down: false, on: .windows, capsLock: false)
        #expect(up?.keyEvent.down == false)
    }

    @Test func capsLockRidesOnLetterKeysOnly() {
        // As the official client does: the host syncs its Caps Lock to it.
        let a = MappedKeys.message(hidUsage: 0x04, down: true, on: .windows, capsLock: true)
        #expect(a?.keyEvent.modifiers == [.capsLock])
        let semicolon = MappedKeys.message(hidUsage: 0x33, down: true, on: .windows, capsLock: true)
        #expect(semicolon?.keyEvent.modifiers == [.capsLock])
        let one = MappedKeys.message(hidUsage: 0x1E, down: true, on: .windows, capsLock: true)
        #expect(one?.keyEvent.modifiers == [])
    }

    @Test func numpadKeysAskForNumLock() {
        // iOS can't tell Num Lock's state; a numpad key means digits.
        let kp5 = MappedKeys.message(hidUsage: 0x5D, down: true, on: .windows, capsLock: false)
        #expect(kp5?.keyEvent.modifiers == [.numLock])
    }

    @Test func barModifiersHaveKeys() {
        #expect(MappedKeys.hidUsage(for: .control) == 0xE0)
        #expect(MappedKeys.hidUsage(for: .shift) == 0xE1)
        #expect(MappedKeys.hidUsage(for: .alt) == 0xE2)
        #expect(MappedKeys.hidUsage(for: .meta) == 0xE3)
        #expect(MappedKeys.hidUsage(for: .escape) == nil)
    }
}

struct HeldKeysTests {
    @Test func downThenUp() {
        var keys = HeldKeys(platform: .windows)
        let down = keys.down(0x04, capsLock: false)
        #expect(down?.count == 1)
        #expect(down?.first?.keyEvent.down == true)
        #expect(keys.isHeld(0x04))
        let up = keys.up(0x04, capsLock: false)
        #expect(up.count == 1)
        #expect(up.first?.keyEvent.down == false)
        #expect(!keys.isHeld(0x04))
    }

    @Test func aKeyTheHostHasNoCodeForIsNotTaken() {
        var keys = HeldKeys(platform: .windows)
        let pause = keys.down(0x48, capsLock: false)
        #expect(pause == nil)
        #expect(!keys.isHeld(0x48))
        let up = keys.up(0x48, capsLock: false)
        #expect(up.isEmpty)
    }

    @Test func latchedModifiersAreHeldAroundTheKey() {
        // Ctrl latched on the bar, then C on a hardware keyboard: Ctrl+C.
        var keys = HeldKeys(platform: .windows)
        let down = keys.down(0x06, latching: [.control], capsLock: false) ?? []
        #expect(down.map(\.keyEvent.chr) == [0x1D, 0x2E])
        #expect(down.map(\.keyEvent.down) == [true, true])
        let up = keys.up(0x06, capsLock: false)
        #expect(up.map(\.keyEvent.chr) == [0x2E, 0x1D])
        #expect(up.map(\.keyEvent.down) == [false, false])
    }

    @Test func repeatingSendsAnotherDown() {
        var keys = HeldKeys(platform: .windows)
        _ = keys.down(0x04, capsLock: false)
        let again = keys.repeated(0x04, capsLock: false)
        #expect(again?.keyEvent.down == true)
        _ = keys.up(0x04, capsLock: false)
        let late = keys.repeated(0x04, capsLock: false)
        #expect(late == nil)
    }

    @Test func releaseAllLetsGoOfEverything() {
        // Switching sessions or the background: no key stays down on the host.
        var keys = HeldKeys(platform: .windows)
        _ = keys.down(0xE1, capsLock: false)  // Shift
        _ = keys.down(0x06, latching: [.control], capsLock: false)
        let ups = keys.releaseAll()
        #expect(Set(ups.map(\.keyEvent.chr)) == [0x2A, 0x2E, 0x1D])
        #expect(ups.allSatisfy { !$0.keyEvent.down })
        #expect(keys.releaseAll().isEmpty)
    }
}

struct PointerButtonsTests {
    @Test func buttonsComeFromTheEventsMask() {
        // UIKit's button mask uses the same bits as RustDesk.
        #expect(MouseButton.pressed(inMask: 0) == [])
        #expect(MouseButton.pressed(inMask: 0b1) == [.left])
        #expect(MouseButton.pressed(inMask: 0b110) == [.right, .middle])
        #expect(MouseButton.pressed(inMask: 0b11000) == [.back, .forward])
    }

    @Test func aChangeInTheMaskSendsDownsAndUps() {
        var held = HeldButtons()
        let first = held.set([.left], at: (5, 6))
        #expect(first.count == 2)  // move, left down
        #expect(first[1] == Input.button(.left, down: true))
        let both = held.set([.left, .right], at: (5, 6))
        #expect(both.last == Input.button(.right, down: true))
        let none = held.set([], at: (5, 6))
        #expect(Set(none.map(\.mouseEvent.mask)) == [Input.button(.left, down: false).mouseEvent.mask,
                                                     Input.button(.right, down: false).mouseEvent.mask])
        #expect(!held.any)
    }
}
