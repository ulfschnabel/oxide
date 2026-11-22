import Foundation
import Testing

@testable import OxideKit

/// A Windows monitor's typical list, plus an ultrawide.
let windowsModes: [Mode] = [
    Mode(5120, 1440), Mode(3840, 2160), Mode(2560, 1440), Mode(1920, 1080), Mode(1680, 1050),
    Mode(1600, 900), Mode(1440, 900), Mode(1280, 1024), Mode(1280, 800), Mode(1024, 768),
]
/// A MacBook Air's list.
let macModes: [Mode] = [
    Mode(2880, 1864), Mode(2560, 1664), Mode(1920, 1243), Mode(1710, 1107), Mode(1440, 932),
    Mode(2880, 1800), Mode(2560, 1600), Mode(1920, 1200), Mode(1440, 900),
]

struct ResolutionPickerTests {
    @Test func picksTheClosestAspect() {
        // iPhone Duo inner display, landscape, 1.42:1.
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(2002, 1404)) == Mode(1680, 1050))
        // A 19.5:9 phone in landscape: 16:9 is closer than the 32:9 ultrawide.
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(2556, 1179)) == Mode(2560, 1440))
        // Aspect is weighed against size: not the 4:3 1024×768 for the Duo,
        // though its shape is closer.
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(2002, 1404)) != Mode(1024, 768))
    }

    @Test func amongEqualAspectsTakesTheSmallestThatCovers() {
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(1800, 1000)) == Mode(1920, 1080))
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(1500, 840)) == Mode(1600, 900))
    }

    @Test func otherwiseTheLargest() {
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(4800, 2700)) == Mode(3840, 2160))
    }

    @Test func uprightAgainstALandscapeOnlyHostFitsTheWidth() {
        // A phone held upright against a landscape-only monitor (Windows lists
        // modes for the current orientation only). No mode has the right
        // shape, so the picture is letterboxed and its width sets the scale:
        // the width closest to the target wins, a squarer mode on a near tie
        // (it fills more of the upright screen).
        // Duo outer screen upright, Balanced text: 699×1017.
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(699, 1017)) == Mode(1024, 768))
        // Sharp: 1398×2034.
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(1398, 2034)) == Mode(1280, 1024))
        // An iPhone upright at Sharp: 1179×2556.
        #expect(ResolutionPicker.best(from: windowsModes, for: Mode(1179, 2556)) == Mode(1280, 1024))
    }

    @Test func letterboxedStaysUsable() {
        // Windows dialogs need about 1024×768: smaller modes only when the
        // host has nothing that size.
        let small = [Mode(640, 480), Mode(800, 600), Mode(1024, 600), Mode(1024, 768), Mode(1920, 1080)]
        #expect(ResolutionPicker.best(from: small, for: Mode(466, 678)) == Mode(1024, 768))
        #expect(ResolutionPicker.best(from: [Mode(640, 480), Mode(800, 600)], for: Mode(466, 678)) == Mode(640, 480))
    }

    @Test func nothingFromAnEmptyList() {
        #expect(ResolutionPicker.best(from: [], for: Mode(1920, 1080)) == nil)
    }
}

struct ResolutionControllerTests {
    func controller(current: Mode = Mode(2560, 1440), modes: [Mode] = windowsModes) -> ResolutionController {
        var c = ResolutionController()
        c.update(display: 0, current: current, original: current, modes: modes)
        return c
    }

    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func requestsTheBestModeForTheTarget() throws {
        var c = controller()
        let request = c.target(Mode(2002, 1404), now: t0)
        let m = try #require(request)
        #expect(m.misc.changeDisplayResolution.display == 0)
        #expect(m.misc.changeDisplayResolution.resolution.width == 1680)
        #expect(m.misc.changeDisplayResolution.resolution.height == 1050)
    }

    @Test func doesNothingWhenAlreadyThere() {
        var c = controller(current: Mode(1680, 1050))
        #expect(c.target(Mode(2002, 1404), now: t0) == nil)
    }

    @Test func doesNotRepeatAPendingRequest() {
        var c = controller()
        #expect(c.target(Mode(2002, 1404), now: t0) != nil)
        #expect(c.target(Mode(2002, 1404), now: t0.addingTimeInterval(1)) == nil)
    }

    @Test func aConfirmedChangeBecomesCurrent() {
        var c = controller()
        _ = c.target(Mode(2002, 1404), now: t0)
        c.update(display: 0, current: Mode(1680, 1050), original: Mode(2560, 1440), modes: windowsModes)
        #expect(c.current == Mode(1680, 1050))
        #expect(c.pending == nil)
        #expect(c.target(Mode(2002, 1404), now: t0.addingTimeInterval(1)) == nil)
    }

    @Test func aModeTheHostIgnoredIsNotTriedAgain() {
        var c = controller(current: Mode(1024, 768))
        _ = c.target(Mode(2002, 1404), now: t0)
        // No SwitchDisplay within 3 s: the host (silently) refused it.
        c.tick(now: t0.addingTimeInterval(3.5))
        #expect(c.pending == nil)
        let next = c.target(Mode(2002, 1404), now: t0.addingTimeInterval(4))
        // The next best instead.
        #expect(next?.misc.changeDisplayResolution.resolution.width == 2560)
    }

    @Test func aLateConfirmationClearsTheFailure() {
        var c = controller(current: Mode(1024, 768))
        _ = c.target(Mode(2002, 1404), now: t0)
        c.tick(now: t0.addingTimeInterval(3.5))  // timed out: 1680×1050 marked failed
        // ...then the host confirms it after all.
        c.update(display: 0, current: Mode(1680, 1050), original: Mode(1024, 768), modes: windowsModes)
        #expect(c.target(Mode(2002, 1404), now: t0.addingTimeInterval(4)) == nil)  // stays, no flapping
    }

    @Test func failuresAreForgottenWhenTheModeListChanges() {
        var c = controller(current: Mode(1024, 768))
        _ = c.target(Mode(2002, 1404), now: t0)
        c.tick(now: t0.addingTimeInterval(3.5))
        c.update(display: 0, current: Mode(1024, 768), original: nil, modes: windowsModes + [Mode(800, 600)])
        let again = c.target(Mode(2002, 1404), now: t0.addingTimeInterval(4))
        #expect(again?.misc.changeDisplayResolution.resolution.width == 1680)
    }

    @Test func macHostsReportPixelsButListPoints() {
        // A Mac at 2× reports 2880×1864 for the 1440×932 mode.
        #expect(Mode(pixels: 2880, 1864, scale: 2) == Mode(1440, 932))
        #expect(Mode(pixels: 1920, 1080, scale: 1) == Mode(1920, 1080))
        #expect(Mode(pixels: 1920, 1080, scale: 0) == Mode(1920, 1080))  // unset
    }

    @Test func aHostThatSwitchesElsewhereIsNotPushedAgain() {
        var c = controller(current: Mode(1024, 768))
        #expect(c.target(Mode(2002, 1404), now: t0) != nil)  // asks for 1680×1050
        // The host switches, but reports something else (other units, its own choice).
        c.update(display: 0, current: Mode(3360, 2100), original: nil, modes: windowsModes)
        #expect(c.pending == nil)
        #expect(c.target(Mode(2002, 1404), now: t0.addingTimeInterval(1)) == nil)
        #expect(c.target(Mode(2002, 1404), now: t0.addingTimeInterval(10)) == nil)
        // A different window size is a new attempt.
        #expect(c.target(Mode(2556, 1179), now: t0.addingTimeInterval(11)) != nil)
    }

    @Test func turningItOffRestoresTheOriginal() throws {
        var c = controller()
        _ = c.target(Mode(2002, 1404), now: t0)
        c.update(display: 0, current: Mode(1680, 1050), original: Mode(2560, 1440), modes: windowsModes)
        let request = c.restore()
        let m = try #require(request)
        #expect(m.misc.changeDisplayResolution.resolution.width == 2560)
        #expect(c.restore() == nil)  // already asked
    }

    @Test func noRestoreWhenNothingChanged() {
        var c = controller()
        #expect(c.restore() == nil)
    }

    @Test func rotatingUprightPicksTheBestLetterboxedMode() {
        var c = controller(current: Mode(1680, 1050))
        // Rotated to portrait after matching: a landscape mode as wide as the
        // upright screen asks for.
        let request = c.target(Mode(1404, 2002), now: t0)
        #expect(request?.misc.changeDisplayResolution.resolution.width == 1440)
        #expect(request?.misc.changeDisplayResolution.resolution.height == 900)
    }
}

struct SessionDisplayEventTests {
    @Test func reportsSwitchDisplay() async {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        var m = Hbb_Message()
        m.misc.switchDisplay = .with {
            $0.display = 0
            $0.x = 0; $0.y = 0; $0.width = 1680; $0.height = 1050
            $0.resolutions = .with { $0.resolutions = [.with { $0.width = 1680; $0.height = 1050 }] }
            $0.originalResolution = .with { $0.width = 2560; $0.height = 1440 }
        }
        host.host(hashMessage())
        host.host(loginOK())
        host.host(m)
        Task { await session.run() }
        let got = await events(session, count: 2)
        guard case .switchDisplay(let s) = got.last else {
            Issue.record("expected switchDisplay, got \(got)")
            return
        }
        #expect(s.width == 1680 && s.originalResolution.width == 2560)
    }

    @Test func reportsLaterDisplayListUpdates() async {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        var m = Hbb_Message()
        m.peerInfo = .with { $0.displays = [.with { $0.x = -1920; $0.width = 1920; $0.height = 1080 }] }
        host.host(hashMessage())
        host.host(loginOK())
        host.host(m)
        Task { await session.run() }
        let got = await events(session, count: 2)
        guard case .displays(let displays) = got.last else {
            Issue.record("expected displays, got \(got)")
            return
        }
        #expect(displays.first?.x == -1920)
    }
}
