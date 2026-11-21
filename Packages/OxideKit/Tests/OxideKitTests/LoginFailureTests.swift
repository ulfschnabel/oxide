import Testing

@testable import OxideKit

struct LoginFailureTests {
    @Test func readsTheHostsMessages() {
        // The strings RustDesk 1.5.3 sends (src/client.rs LOGIN_MSG_*).
        #expect(LoginFailure("Wrong Password") == .wrongPassword)
        #expect(LoginFailure("Empty Password") == .wrongPassword)
        #expect(LoginFailure("No Password Access") == .needsApproval)
        #expect(LoginFailure("2FA Required") == .twoFactorRequired)
        #expect(LoginFailure("Wrong 2FA Code") == .twoFactorRequired)
        #expect(LoginFailure("Offline") == .offline)
        #expect(LoginFailure("Something new") == .other("Something new"))
    }
}
