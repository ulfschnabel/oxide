import Foundation
import Network
import Testing

@testable import OxideKit

struct TransportErrorTests {
    @Test func namesTheCommonNetworkFailures() {
        #expect(TransportError(.posix(.ECONNREFUSED)) == .refused)
        for code: POSIXErrorCode in [.ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN] {
            #expect(TransportError(.posix(code)) == .unreachable, "\(code)")
        }
        #expect(TransportError(.dns(-65554)) == .notFound)  // kDNSServiceErr_NoSuchRecord
        #expect(TransportError(.posix(.ECONNRESET)) == .connectionLost)
        #expect(TransportError(.posix(.EPIPE)) == .connectionLost)
    }

    @Test func keepsTheDetailOfAnythingElse() {
        guard case .failed(let detail) = TransportError(.posix(.EACCES)) else {
            Issue.record("expected .failed")
            return
        }
        #expect(!detail.isEmpty)
    }
}

struct ConnectionProblemTests {
    @Test func comesFromTransportErrors() {
        #expect(ConnectionProblem(TransportError.refused) == .refused)
        #expect(ConnectionProblem(TransportError.unreachable) == .unreachable)
        #expect(ConnectionProblem(TransportError.notFound) == .notFound)
        #expect(ConnectionProblem(TransportError.localNetworkDenied) == .localNetworkDenied)
        #expect(ConnectionProblem(TransportError.connectionLost) == .dropped)
        #expect(ConnectionProblem(ConnectionProblem.login(.wrongPassword)) == .login(.wrongPassword))
        #expect(ConnectionProblem(TransportError.failed("NWError 99")) == .other("NWError 99"))
    }

    @Test func onlyNetworkTroubleIsWorthRetryingAlone() {
        for p: ConnectionProblem in [.unreachable, .refused, .notFound, .dropped, .notRustDesk, .other("x")] {
            #expect(p.isTransient, "\(p)")
        }
        for p: ConnectionProblem in [.invalidAddress, .localNetworkDenied, .login(.wrongPassword),
                                     .login(.needsApproval), .closedByHost("Closed manually by the peer"),
                                     .unsupportedCodec("vp9")] {
            #expect(!p.isTransient, "\(p)")
        }
    }

    @Test func groupsCausesForTheDialog() {
        #expect(ConnectionProblem.unreachable.cause == .unreachable)
        #expect(ConnectionProblem.refused.cause == .unreachable)
        #expect(ConnectionProblem.notFound.cause == .unreachable)
        #expect(ConnectionProblem.dropped.cause == .unreachable)
        #expect(ConnectionProblem.login(.wrongPassword).cause == .authentication)
        #expect(ConnectionProblem.login(.twoFactorRequired).cause == .authentication)
        #expect(ConnectionProblem.notRustDesk.cause == .timedOut)
        #expect(ConnectionProblem.closedByHost("x").cause == .closedByHost)
    }

    @Test func neverShowsRawErrorText() {
        let raw = "The operation couldn't be completed. (Network.NWError error 61 - Connection refused)"
        let all: [ConnectionProblem] = [.invalidAddress, .notFound, .refused, .unreachable, .localNetworkDenied,
                                        .login(.wrongPassword), .login(.needsApproval), .login(.twoFactorRequired),
                                        .login(.offline), .notRustDesk, .dropped, .other(raw)]
        for p in all {
            #expect(!p.message.contains("NWError"), "\(p)")
            #expect(!p.message.contains("error 61"), "\(p)")
            #expect(!p.cause.title.isEmpty)
            #expect(p.localizedDescription == p.message)
        }
    }

    @Test func namesACodecItCantShow() {
        // The host falls back to VP9 when its hardware encoder fails; every
        // reconnect would get VP9 again.
        #expect(ConnectionProblem.unsupportedCodec("vp9").message.contains("VP9"))
    }

    @Test func saysWhatTheHostSaidWhenItClosed() {
        #expect(ConnectionProblem.closedByHost("Closed manually by the peer").message.contains("Closed manually by the peer"))
    }
}

struct ReconnectPolicyTests {
    let policy = ReconnectPolicy(delays: [.zero, .seconds(1), .seconds(2), .seconds(4)], deadline: .seconds(30))

    @Test func backsOffBetweenAttempts() {
        #expect(policy.next(failures: 0, elapsed: .zero, last: nil) == .retry(after: .zero))
        #expect(policy.next(failures: 1, elapsed: .seconds(1), last: .unreachable) == .retry(after: .seconds(1)))
        #expect(policy.next(failures: 2, elapsed: .seconds(3), last: .dropped) == .retry(after: .seconds(2)))
        #expect(policy.next(failures: 3, elapsed: .seconds(6), last: .refused) == .retry(after: .seconds(4)))
    }

    @Test func givesUpWhenTheAttemptsAreUsed() {
        #expect(policy.next(failures: 4, elapsed: .seconds(12), last: .unreachable) == .giveUp)
    }

    @Test func givesUpAtTheDeadline() {
        #expect(policy.next(failures: 2, elapsed: .seconds(29), last: .unreachable) == .giveUp)
    }

    @Test func givesUpAtOnceOnWhatRetryingCantFix() {
        #expect(policy.next(failures: 1, elapsed: .seconds(1), last: .login(.wrongPassword)) == .giveUp)
        #expect(policy.next(failures: 1, elapsed: .seconds(1), last: .closedByHost("bye")) == .giveUp)
    }
}

struct ReconnectSessionTests {
    @Test func reusesTheSessionIDItIsGiven() async throws {
        // The host lets a recent session back in on its old password, even a
        // one-time one that has rotated since, if my_id, my_name and
        // session_id all match (RustDesk 1.5.3 connection.rs is_recent_session).
        let host = FakeHost { message, host in
            if case .loginRequest = message.union { host.host(loginOK()) }
        }
        let session = Session(transport: host, host: "h", password: "p", clientName: "Duo", sessionID: 4242)
        host.host(hashMessage())
        Task { await session.run() }
        _ = await events(session, count: 1)
        let login = try #require(host.received.first?.loginRequest)
        #expect(login.sessionID == 4242)
        #expect(login.myName == "Duo")
        #expect(login.myID == "oxide")
    }

    @Test func reportsWhyTheHostClosed() async {
        let host = FakeHost()
        let session = Session(transport: host, host: "h", password: "p")
        var close = Hbb_Message()
        close.misc = .with { $0.closeReason = "Closed manually by the peer" }
        host.host(hashMessage())
        host.host(loginOK())
        host.host(close)
        Task { await session.run() }
        let got = await events(session, count: 3)
        #expect(got.count == 3)
        #expect(got[1] == .hostClosed("Closed manually by the peer"))
        #expect(got[2] == .closed(nil))
    }

    @Test func asksForAFreshPicture() {
        // After the app was in the background the decoder needs a key frame.
        #expect(Control.refreshVideo().misc.refreshVideo == true)
    }
}
