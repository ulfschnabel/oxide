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

/// Two sessions on screen at once, one in each pane.
struct SessionRingSplitTests {
    @Test func splittingShowsTheNextOneInTheSecondPane() {
        var ring = SessionRing<String>()
        for id in ["a", "b", "c"] { ring.open(id) }
        ring.open("a")
        #expect(ring.split() == "b")
        #expect(ring.current == "a")
        #expect(ring.second == "b")
    }

    @Test func noSplitWithOneSession() {
        var ring = SessionRing<String>()
        ring.open("a")
        #expect(ring.split() == nil)
        #expect(ring.second == nil)
    }

    @Test func eachPaneSwipesPastTheOther() {
        var ring = SessionRing<String>()
        for id in ["a", "b", "c", "d"] { ring.open(id) }
        ring.open("a")
        ring.split()  // a | b
        #expect(ring.step(1, pane: 0) == "c")  // skips b, shown below
        #expect(ring.current == "c")
        #expect(ring.step(1, pane: 1) == "d")
        #expect(ring.second == "d")
        #expect(ring.step(1, pane: 1) == "a")  // skips c, shown above
        #expect(ring.step(-1, pane: 0) == "b")  // c → b, skipping nothing; a is below
        #expect(Set([ring.current, ring.second]) == ["b", "a"])
    }

    @Test func withTwoSessionsThereIsNothingToSwipeTo() {
        var ring = SessionRing<String>()
        for id in ["a", "b"] { ring.open(id) }
        ring.split()
        #expect(ring.step(1, pane: 0) == nil)
        #expect(ring.step(1, pane: 1) == nil)
    }

    @Test func closingAPaneEndsTheSplit() {
        var ring = SessionRing<String>()
        for id in ["a", "b", "c"] { ring.open(id) }
        ring.open("a")
        ring.split()  // a | b
        ring.close("b")
        #expect(ring.second == nil)
        #expect(ring.current == "a")
        ring.split()  // a | c
        ring.close("a")
        #expect(ring.second == nil)
        #expect(ring.current == "c")  // the other pane's session stays on screen
    }

    @Test func openingTheSecondPanesSessionEndsTheSplit() {
        var ring = SessionRing<String>()
        for id in ["a", "b"] { ring.open(id) }
        ring.open("a")
        ring.split()
        ring.open("b")
        #expect(ring.current == "b")
        #expect(ring.second == nil)
    }

    @Test func unsplitKeepsTheTopOne() {
        var ring = SessionRing<String>()
        for id in ["a", "b"] { ring.open(id) }
        ring.open("a")
        ring.split()
        ring.unsplit()
        #expect(ring.current == "a")
        #expect(ring.second == nil)
    }
}
