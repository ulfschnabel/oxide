import Testing

@testable import OxideKit

struct HeldButtonsTests {
    @Test func pressAndReleaseSendDownAndUp() {
        var held = HeldButtons()
        let down = held.press(.left, at: (10, 20))
        #expect(down.count == 2)  // positioned first, then down
        #expect(down[0].mouseEvent.mask == 0)
        #expect(down[0].mouseEvent.x == 10)
        #expect(down[1] == Input.button(.left, down: true))
        #expect(held.isHeld(.left))
        #expect(held.release(.left) == [Input.button(.left, down: false)])
        #expect(!held.isHeld(.left))
    }

    @Test func aSecondPressOrAStrayReleaseSendsNothing() {
        // Two fingers on the same button, or a release after the session reset.
        var held = HeldButtons()
        _ = held.press(.right, at: (0, 0))
        #expect(held.press(.right, at: (0, 0)).isEmpty)
        #expect(held.release(.left).isEmpty)
    }

    @Test func releaseAllLetsGoOfEverything() {
        // Switching sessions, the background, disconnecting: nothing stays down.
        var held = HeldButtons()
        _ = held.press(.left, at: (0, 0))
        _ = held.press(.right, at: (0, 0))
        let ups = held.releaseAll()
        #expect(ups.count == 2)
        #expect(ups.contains(Input.button(.left, down: false)))
        #expect(ups.contains(Input.button(.right, down: false)))
        #expect(held.releaseAll().isEmpty)
    }

    @Test func modifiersRideOnThePress() {
        var held = HeldButtons()
        let down = held.press(.left, at: (1, 2), modifiers: [.shift])
        #expect(down.allSatisfy { $0.mouseEvent.modifiers == [.shift] })
    }
}
