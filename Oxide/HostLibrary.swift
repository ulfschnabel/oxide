import OxideKit
import Foundation
import Observation
import Security

/// Host passwords in the Keychain, on this device only (not synced to iCloud).
enum PasswordVault {
    private static let service = "com.ulfschnabel.duodesk.host"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The password couldn't be saved in the keychain (\(reason))."
        }
    }

    /// Saves or replaces the password. The old one stays if this fails.
    static func set(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var q = query(id)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    static func remove(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// The saved computers, kept on disk, with their passwords in the Keychain.
@MainActor @Observable
final class HostLibrary {
    private(set) var list: HostList
    private(set) var loadError: String?
    private let url: URL

    init(url: URL = HostLibrary.defaultURL) {
        self.url = url
        do {
            list = try HostList.load(from: url)
        } catch {
            // Keep the unreadable file instead of saving over it.
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            list = HostList()
            loadError = "Your saved computers couldn't be read (\(error.localizedDescription)). The file was kept as \(aside.lastPathComponent)."
        }
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "hosts.json")
    }

    var hosts: [SavedHost] { list.sorted }

    func hasPassword(_ host: SavedHost) -> Bool { PasswordVault.password(for: host.id) != nil }
    func password(for host: SavedHost) -> String? {
        host.passwordKind == .permanent ? PasswordVault.password(for: host.id) : nil
    }

    @discardableResult
    func add(name: String, address: String, passwordKind: PasswordKind, password: String?) throws -> SavedHost {
        let host = try list.add(name: name, address: address, passwordKind: passwordKind, now: .now)
        if passwordKind == .permanent, let password, !password.isEmpty {
            do {
                try PasswordVault.set(password, for: host.id)
            } catch {
                list.remove(host.id)  // all or nothing: Save can simply be tried again
                throw error
            }
        }
        save()
        return host
    }

    /// `password`: nil keeps the saved one, "" forgets it. One-time
    /// passwords are never kept.
    func update(_ host: SavedHost, name: String, address: String, passwordKind: PasswordKind,
                password: String?) throws {
        try list.update(host.id, name: name, address: address, passwordKind: passwordKind)
        save()
        if passwordKind == .oneTime {
            PasswordVault.remove(for: host.id)
        } else if let password {
            if password.isEmpty { PasswordVault.remove(for: host.id) } else { try PasswordVault.set(password, for: host.id) }
        }
    }

    /// Saves a password typed at connect time; a failure is shown in the list.
    func remember(_ password: String, for host: SavedHost) {
        // Not for one-time passwords, nor a computer deleted meanwhile.
        guard let current = list[host.id], current.passwordKind == .permanent else { return }
        do {
            try PasswordVault.set(password, for: host.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func forgetPassword(of host: SavedHost) {
        PasswordVault.remove(for: host.id)
    }

    func markConnected(_ host: SavedHost) {
        list.markConnected(host.id, at: .now)
        save()
    }

    func remove(_ host: SavedHost) {
        list.remove(host.id)
        PasswordVault.remove(for: host.id)
        save()
    }

    private func save() {
        do {
            try list.save(to: url)
        } catch {
            loadError = "Your computers couldn't be saved: \(error.localizedDescription)"
        }
    }
}
