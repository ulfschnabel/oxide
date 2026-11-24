import Foundation
import Testing

@testable import OxideKit

/// The demo computer, driven by the real client session over the in-app link.
struct DemoHostTests {
    /// A logged-in session and its events, with the host serving it.
    private func connect(password: String = DemoHost.password) -> (Session, AsyncStream<SessionEvent>.Iterator) {
        let (client, end) = DemoLink.pair()
        let host = DemoHost()
        Task { await host.serve(end) }
        let session = Session(transport: client, host: DemoHost.address, password: password)
        Task { await session.run() }
        return (session, session.events.makeAsyncIterator())
    }

    /// The next event that matches, skipping others (with a time limit).
    private func next(_ events: inout AsyncStream<SessionEvent>.Iterator,
                      where match: (SessionEvent) -> Bool) async -> SessionEvent? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            guard let event = await events.next() else { return nil }
            if match(event) { return event }
        }
        return nil
    }

    private func isVideo(_ e: SessionEvent) -> Bool { if case .video = e { true } else { false } }

    @Test func logsInAsADemoComputer() async throws {
        var (session, events) = connect()
        let event = await next(&events) { if case .loggedIn = $0 { true } else { false } }
        guard case .loggedIn(let info)? = event else { Issue.record("no login: \(String(describing: event))"); return }
        #expect(info.platform == "Windows")
        #expect(info.displays.first?.width == 1920)
        #expect(info.resolutions.resolutions.count == DemoDesktop.modes.count)
        let video = await next(&events, where: isVideo)
        guard case .video(let frame)? = video else { Issue.record("no video"); return }
        #expect(frame.key && frame.codec == .h264)
        await session.close()
    }

    @Test func refusesAWrongPassword() async {
        var (session, events) = connect(password: "nope")
        let event = await next(&events) { if case .loginFailed = $0 { true } else { false } }
        guard case .loginFailed(let failure)? = event else { Issue.record("no failure"); return }
        #expect(failure == .wrongPassword)
        await session.close()
    }

    @Test func inputMakesANewFrame() async throws {
        var (session, events) = connect()
        _ = await next(&events, where: isVideo)
        try await session.send(Input.typed("a"))
        let event = await next(&events, where: isVideo)
        guard case .video(let frame)? = event else { Issue.record("no frame after input"); return }
        #expect(!frame.key)
        await session.close()
    }

    @Test func switchesResolutionAndStartsWithAKeyFrame() async throws {
        var (session, events) = connect()
        _ = await next(&events, where: isVideo)
        var change = Hbb_Message()
        change.misc.changeDisplayResolution = .with {
            $0.display = 0
            $0.resolution = .with { $0.width = 1280; $0.height = 800 }
        }
        try await session.send(change)
        let switched = await next(&events) { if case .switchDisplay = $0 { true } else { false } }
        guard case .switchDisplay(let s)? = switched else { Issue.record("no switch"); return }
        #expect(s.width == 1280 && s.height == 800)
        let event = await next(&events, where: isVideo)
        guard case .video(let frame)? = event else { Issue.record("no frame"); return }
        #expect(frame.key)
        await session.close()
    }

    @Test func refreshAsksForAKeyFrame() async throws {
        var (session, events) = connect()
        _ = await next(&events, where: isVideo)
        var refresh = Hbb_Message()
        refresh.misc.refreshVideo = true
        try await session.send(refresh)
        let event = await next(&events, where: isVideo)
        guard case .video(let frame)? = event else { Issue.record("no frame"); return }
        #expect(frame.key)
        await session.close()
    }

    @Test func closingEndsTheHost() async {
        let (client, end) = DemoLink.pair()
        let host = DemoHost()
        let served = Task { await host.serve(end) }
        let session = Session(transport: client, host: DemoHost.address, password: DemoHost.password)
        Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(200))
        await session.close()
        // serve returns once the client side is gone.
        await served.value
    }
}

struct DemoComputerEntryTests {
    /// No computer the user adds can have the demo's address.
    @Test func theDemoIsNotARealAddress() {
        #expect(SavedHost.demo.isDemo)
        #expect(HostAddress(DemoHost.address) == nil)
        #expect(HostAddress("demo") != nil)
    }

    @Test func aReconnectKeepsTheDrawing() async throws {
        let host = DemoHost()
        for round in 0..<2 {
            let (client, end) = DemoLink.pair()
            Task { await host.serve(end) }
            let session = Session(transport: client, host: DemoHost.address, password: DemoHost.password)
            Task { await session.run() }
            var events = session.events.makeAsyncIterator()
            var gotKey = false
            while let e = await events.next() {
                if case .video(let f) = e { gotKey = f.key; break }
            }
            #expect(gotKey, "round \(round) starts with a key frame")
            if round == 0 { try await session.send(Input.typed("q")) }
            try await Task.sleep(for: .milliseconds(100))
            await session.close()
        }
        #expect(await host.typed == "q")
    }
}
