import Testing

@testable import OxideKit

struct PictureHoldTests {
    @Test func notHeldUntilASessionBegins() {
        var hold = PictureHold()
        #expect(!hold.isHeld)
        let released = hold.release()
        #expect(!released)
    }

    @Test func heldUntilTheResolutionSettles() {
        var hold = PictureHold()
        hold.begin(now: .now)
        #expect(hold.isHeld)
        let first = hold.release()
        #expect(first)
        #expect(!hold.isHeld)
        // Only the first release restarts the picture.
        let second = hold.release()
        #expect(!second)
    }

    @Test func aHostThatNeverAnswersDoesntHoldItForever() {
        var hold = PictureHold()
        let start = ContinuousClock.Instant.now
        hold.begin(now: start)
        let early = hold.expire(now: start + .seconds(1))
        #expect(!early)
        #expect(hold.isHeld)
        let due = hold.expire(now: start + PictureHold.limit)
        #expect(due)
        #expect(!hold.isHeld)
        let again = hold.expire(now: start + PictureHold.limit + .seconds(1))
        #expect(!again)
    }

    @Test func outlastsOneResolutionRequest() {
        // A request the host ignores times out first; then the picture shows.
        #expect(PictureHold.limit > .seconds(ResolutionController.confirmTimeout))
    }
}
