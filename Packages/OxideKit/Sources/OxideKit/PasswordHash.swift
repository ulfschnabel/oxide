import CryptoKit
import Foundation

/// The login proof a RustDesk host checks: SHA256(SHA256(password ‖ salt) ‖ challenge),
/// raw bytes. The host sends salt and challenge in its first `Hash` message.
public enum PasswordHash {
    public static func compute(password: String, salt: String, challenge: String) -> Data {
        let first = SHA256.hash(data: Data((password + salt).utf8))
        let second = SHA256.hash(data: Data(first) + Data(challenge.utf8))
        return Data(second)
    }
}
