import Testing

@testable import OxideKit

struct SessionRingTests {
    @Test func openingAddsAndShowsIt() {
        var ring = SessionRing<String>()
        ring.open("jabiru")
        ring.open("caiman")
        #expect(ring.ids == ["jabiru", "caiman"])
        #expect(ring.current == "caiman")
    }

    @Test func openingAnOpenOneJustShowsIt() {
        var ring = SessionRing<String>()
        ring.open("a")
        ring.open("b")
        ring.open("a")
        #expect(ring.ids == ["a", "b"])
        #expect(ring.current == "a")
    }

    @Test func swipingWrapsAround() {
        var ring = SessionRing<String>()
        for id in ["a", "b", "c"] { ring.open(id) }
        #expect(ring.step(1) == "a")
        #expect(ring.step(1) == "b")
        #expect(ring.step(-1) == "a")
        #expect(ring.step(-1) == "c")
    }

    @Test func swipingWithOneOpenDoesNothing() {
        var ring = SessionRing<String>()
        ring.open("a")
        #expect(ring.step(1) == nil)
        #expect(ring.current == "a")
    }

    @Test func closingTheShownOneShowsTheNext() {
        var ring = SessionRing<String>()
        for id in ["a", "b", "c"] { ring.open(id) }
        ring.open("b")
        ring.close("b")
        #expect(ring.current == "c")
        // The last one closed: the one before it.
        ring.close("c")
        #expect(ring.current == "a")
        ring.close("a")
        #expect(ring.current == nil)
        #expect(ring.ids.isEmpty)
    }

    @Test func closingAnotherKeepsTheShownOne() {
        var ring = SessionRing<String>()
        for id in ["a", "b", "c"] { ring.open(id) }
        ring.close("a")
        #expect(ring.current == "c")
        #expect(ring.ids == ["b", "c"])
    }

    @Test func saysWhereTheShownOneIs() {
        var ring = SessionRing<String>()
        #expect(ring.position == nil)
        for id in ["a", "b", "c"] { ring.open(id) }
        ring.open("b")
        #expect(ring.position?.index == 1)
        #expect(ring.position?.count == 3)
    }
}
