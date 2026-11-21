import Foundation
import Synchronization
import Testing

@testable import OxideKit

/// A host that plays a script: it sends what the test pushes, and records
/// what the client sends.
final class FakeHost: Transport, Sendable {
    // The session reads serially, so one iterator without locking is fine.
    nonisolated(unsafe) private var inbound: AsyncStream<Data>.Iterator
    private let push: AsyncStream<Data>.Continuation
    private let sent = Mutex<[Hbb_Message]>([])
    private let onSend: @Sendable (Hbb_Message, FakeHost) -> Void

    init(onSend: @escaping @Sendable (Hbb_Message, FakeHost) -> Void = { _, _ in }) {
        let (stream, push) = AsyncStream.makeStream(of: Data.self)
        inbound = stream.makeAsyncIterator()
        self.push = push
        self.onSend = onSend
    }

    func host(_ message: Hbb_Message) {
        push.yield(Framing.encode(try! message.serializedData()))
    }

    func hangUp() { push.finish() }

    var received: [Hbb_Message] { sent.withLock { $0 } }

    // Transport
    func send(_ data: Data) async throws {
        var decoder = FrameDecoder()
        for body in try decoder.append(data) {
            let message = try Hbb_Message(serializedBytes: body)
            sent.withLock { $0.append(message) }
            onSend(message, self)
        }
    }

    func receive() async throws -> Data? {
        await inbound.next()
    }

    func close() { push.finish() }
}

func hashMessage() -> Hbb_Message {
    var m = Hbb_Message()
    m.hash = .with { $0.salt = "3sw43b8vdbub38zv9c42jcjcdtfwj5cc"; $0.challenge = "2qa9b3" }
    return m
}

func loginOK() -> Hbb_Message {
    var m = Hbb_Message()
    m.loginResponse = .with {
        $0.peerInfo = .with {
            $0.hostname = "gamer"
            $0.displays = [.with { $0.width = 1920; $0.height = 1080 }]
        }
    }
    return m
}

func videoMessage(_ data: Data, key: Bool, codec: VideoCodec = .h264) -> Hbb_Message {
    var frames = Hbb_EncodedVideoFrames()
    frames.frames = [.with { $0.data = data; $0.key = key; $0.pts = 7 }]
    var m = Hbb_Message()
    m.videoFrame = .with {
        switch codec {
        case .h264: $0.h264S = frames
        case .h265: $0.h265S = frames
        }
    }
    return m
}

/// Collects session events until the stream ends or `count` arrive.
func events(_ session: Session, count: Int) async -> [SessionEvent] {
    var out: [SessionEvent] = []
    for await event in session.events {
        out.append(event)
        if out.count == count { break }
    }
    return out
}

struct SessionTests {
    @Test func logsInWithTheHashedPasswordAndAsksForHardwareCodecs() async throws {
        let host = FakeHost { message, host in
            if case .loginRequest = message.union { host.host(loginOK()) }
        }
        let session = Session(transport: host, host: "192.168.1.8", password: "secret")
        host.host(hashMessage())
        Task { await session.run() }

        let first = await events(session, count: 1)
        guard case .loggedIn(let info) = first.first else {
            Issue.record("expected loggedIn, got \(first)")
            return
        }
        #expect(info.hostname == "gamer")

        let login = try #require(host.received.first?.loginRequest)
        #expect(login.username == "192.168.1.8")
        #expect(login.password.hex == "84f5644681cbd1d0e70d2957483cfef0a131036391112e1a12b6f5a1fb340751")
        #expect(login.version == "1.5.3")
        #expect(login.myPlatform == "iOS")
        #expect(login.option.supportedDecoding.abilityH264 == 1)
        #expect(login.option.supportedDecoding.abilityH265 == 1)
        #expect(login.option.supportedDecoding.abilityVp9 == 0)
        #expect(login.option.disableAudio == .yes)
        // Without it the host never reports its cursor position.
        #expect(login.option.showRemoteCursor == .yes)
        #expect(login.videoAckRequired == false)
        #expect(login.sessionID != 0)
    }

    @Test func reportsAWrongPassword() async {
        let host = FakeHost { message, host in
            if case .loginRequest = message.union {
                var m = Hbb_Message()
                m.loginResponse = .with { $0.error = "Wrong Password" }
                host.host(m)
            }
        }
        let session = Session(transport: host, host: "h", password: "nope")
        host.host(hashMessage())
        Task { await session.run() }
        let got = await events(session, count: 1)
        #expect(got.first == .loginFailed(.wrongPassword))
    }

    @Test func echoesTestDelayUnchanged() async throws {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        var delay = Hbb_Message()
        delay.testDelay = .with { $0.time = 123_456; $0.lastDelay = 9 }
        host.host(hashMessage())
        host.host(loginOK())
        host.host(delay)
        host.hangUp()
        await session.run()
        #expect(host.received.contains { $0.testDelay == delay.testDelay })
    }

    @Test func deliversVideoFramesAndEndsWhenTheHostHangsUp() async throws {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        host.host(hashMessage())
        host.host(loginOK())
        host.host(videoMessage(Data([0, 0, 0, 1, 0x65]), key: true))
        host.host(videoMessage(Data([0, 0, 0, 1, 0x41]), key: false, codec: .h265))
        host.hangUp()
        Task { await session.run() }
        let got = await events(session, count: 4)
        #expect(got.count == 4)
        #expect(got[1] == .video(VideoFrameUnit(codec: .h264, data: Data([0, 0, 0, 1, 0x65]), key: true, pts: 7, display: 0)))
        #expect(got[2] == .video(VideoFrameUnit(codec: .h265, data: Data([0, 0, 0, 1, 0x41]), key: false, pts: 7, display: 0)))
        #expect(got[3] == .closed(nil))
    }

    @Test func reportsTheHostsCursorPosition() async {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        var cursor = Hbb_Message()
        cursor.cursorPosition = .with { $0.x = -300; $0.y = 42 }
        host.host(hashMessage())
        host.host(loginOK())
        host.host(cursor)
        Task { await session.run() }
        let got = await events(session, count: 2)
        #expect(got.last == .cursorPosition(x: -300, y: 42))
    }

    @Test func refusesACodecItCannotDecode() async {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        var vp9 = Hbb_Message()
        vp9.videoFrame = .with { $0.vp9S = .with { $0.frames = [.with { $0.data = Data([1]) }] } }
        host.host(hashMessage())
        host.host(loginOK())
        host.host(vp9)
        Task { await session.run() }
        let got = await events(session, count: 2)
        #expect(got.last == .unsupportedCodec("vp9"))
    }
}
