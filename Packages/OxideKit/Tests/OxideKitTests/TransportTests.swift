import Foundation
import Testing

@testable import OxideKit

struct ConnectWaitTests {
    @Test func waitsWhileTheLocalNetworkPromptIsUp() {
        // iOS asks for Local Network access on the first LAN connection; until
        // the user answers, the connection waits with this reason.
        #expect(ConnectWait.onWaiting(localNetworkDenied: true) == .keepWaiting)
    }

    @Test func otherWaitsFailAtOnce() {
        // Refused or unreachable: retrying in the background helps nobody.
        #expect(ConnectWait.onWaiting(localNetworkDenied: false) == .fail)
    }

    @Test func explainsWhereToAllowLocalNetworkAccess() {
        let message = TransportError.localNetworkDenied.localizedDescription
        #expect(message.contains("Local Network"))
        #expect(TransportError.failed("Connection refused").localizedDescription == "Connection refused")
    }
}
