import OxideKit
import Foundation
import Observation
import Security

/// Host passwords in the Keychain, synced through iCloud Keychain so a
/// computer saved on one device connects from the others too.
enum PasswordVault {
    private static let service = "com.ulfschnabel.duodesk.host"

    /// `synced`: nil matches both kinds (older passwords were this-device-only).
    private static func query(_ id: UUID, synced: Bool?) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: synced.map { $0 as Any } ?? kSecAttrSynchronizableAny]
    }

    static func password(for id: UUID) -> String? {
        var q = query(id, synced: nil)
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

    /// Saves or replaces the password, synced. The old one stays if this fails.
    static func set(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id, synced: true) as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id, synced: true)
            q[kSecValueData as String] = data
            // Synced items can't be this-device-only.
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
        // A this-device-only copy from before syncing is now superseded.
        SecItemDelete(query(id, synced: false) as CFDictionary)
    }

    static func remove(for id: UUID) {
        SecItemDelete(query(id, synced: nil) as CFDictionary)
    }

    /// Moves a this-device-only password (saved before syncing) to the synced keychain.
    static func migrate(_ id: UUID) {
        var q = query(id, synced: false)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return }
        try? set(password, for: id)
    }
}

/// The saved computers, kept on disk and in iCloud's key-value store, with
/// their passwords in the (iCloud) Keychain. Each device merges the other
/// devices' list into its own (`HostList.merge`).
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
        for host in list.hosts where host.passwordKind == .permanent { PasswordVault.migrate(host.id) }
        NotificationCenter.default.addObserver(self, selector: #selector(cloudChanged),
                                               name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: cloud)
        cloud.synchronize()
        syncWithCloud()
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private static let cloudKey = "hostList"

    /// Posted on a background queue.
    @objc nonisolated private func cloudChanged(_ note: Notification) {
        Task { @MainActor in self.syncWithCloud() }
    }

    /// Merges the list in iCloud into this one, and puts the result there if
    /// it differs. Without iCloud the store is local and this changes nothing.
    @discardableResult
    private func syncWithCloud() -> [UUID: UUID] {
        var remote = HostList()
        if let data = cloud.data(forKey: Self.cloudKey) {
            do {
                remote = try HostList.decoded(from: data)
            } catch {
                diag("iCloud: the synced computers couldn't be read: \(error.localizedDescription)")
            }
        }
        let now = Date.now
        var merged = list
        let replaced = merged.merge(remote, now: now)
        // A computer merged into another one: its password goes with it.
        for (gone, keeper) in replaced {
            if PasswordVault.password(for: keeper) == nil, let password = PasswordVault.password(for: gone) {
                try? PasswordVault.set(password, for: keeper)
            }
            PasswordVault.remove(for: gone)
        }
        if merged != list {
            list = merged
            saveFile()
        }
        // Compared with the remote list as this device would keep it, so
        // forgetting an old removal (a matter of each device's clock) isn't
        // a change worth sending back and forth.
        var settled = remote
        settled.merge(HostList(), now: now)
        if merged != settled {
            do {
                cloud.set(try merged.encoded(), forKey: Self.cloudKey)
            } catch {
                diag("iCloud: the computers couldn't be encoded: \(error.localizedDescription)")
            }
        }
        return replaced
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
        // Saved first: if it's the same as a computer already there, the
        // typed password goes to that one.
        let id = save()[host.id] ?? host.id
        if passwordKind == .permanent, let password, !password.isEmpty {
            do {
                try PasswordVault.set(password, for: id)
            } catch {
                if id == host.id {
                    list.remove(host.id)  // all or nothing: Save can simply be tried again
                    save()
                }
                throw error
            }
        }
        return list[id] ?? host
    }

    /// `password`: nil keeps the saved one, "" forgets it. One-time
    /// passwords are never kept.
    func update(_ host: SavedHost, name: String, address: String, passwordKind: PasswordKind,
                password: String?) throws {
        try list.update(host.id, name: name, address: address, passwordKind: passwordKind)
        // Now the same as another computer: that one stays, with this password.
        let id = save()[host.id] ?? host.id
        if passwordKind == .oneTime {
            PasswordVault.remove(for: id)
        } else if let password {
            if password.isEmpty { PasswordVault.remove(for: id) } else { try PasswordVault.set(password, for: id) }
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

    /// Returns the computers merged into another one (see `HostList.merge`).
    @discardableResult
    private func save() -> [UUID: UUID] {
        saveFile()
        return syncWithCloud()
    }

    private func saveFile() {
        do {
            try list.save(to: url)
        } catch {
            loadError = "Your computers couldn't be saved: \(error.localizedDescription)"
        }
    }
}
