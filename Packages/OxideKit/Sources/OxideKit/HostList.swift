import Foundation

/// How a computer is logged in to.
public enum PasswordKind: String, Codable, Sendable, CaseIterable {
    /// RustDesk's default: a new password on the remote screen after every
    /// connection, so it's asked for each time and never saved.
    case oneTime
    /// A password set in RustDesk; may be saved in the Keychain.
    case permanent
}

/// A computer the user saved. Its password is kept in the Keychain under
/// `id`, never here.
public struct SavedHost: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public var passwordKind: PasswordKind
    public var createdAt: Date
    public var lastConnected: Date?

    public var displayName: String { name.isEmpty ? address : name }

    init(id: UUID, name: String, address: String, passwordKind: PasswordKind, createdAt: Date) {
        self.id = id
        self.name = name
        self.address = address
        self.passwordKind = passwordKind
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, passwordKind, createdAt, lastConnected
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        // Saved before there was a choice: those were all permanent.
        passwordKind = try c.decodeIfPresent(PasswordKind.self, forKey: .passwordKind) ?? .permanent
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }
}

public enum HostListError: Error, Equatable {
    case invalidAddress
}

/// The saved computers, as stored on disk.
public struct HostList: Codable, Equatable, Sendable {
    public private(set) var hosts: [SavedHost] = []

    public init() {}

    public subscript(id: UUID) -> SavedHost? {
        hosts.first { $0.id == id }
    }

    /// Recently used first, then the rest by name.
    public var sorted: [SavedHost] {
        hosts.sorted { a, b in
            switch (a.lastConnected, b.lastConnected) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }

    private static func clean(_ name: String, _ address: String) throws -> (String, String) {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard HostAddress(address) != nil else { throw HostListError.invalidAddress }
        return (name.trimmingCharacters(in: .whitespaces), address)
    }

    @discardableResult
    public mutating func add(name: String, address: String, passwordKind: PasswordKind = .permanent,
                             now: Date) throws -> SavedHost {
        let (name, address) = try Self.clean(name, address)
        let host = SavedHost(id: UUID(), name: name, address: address, passwordKind: passwordKind, createdAt: now)
        hosts.append(host)
        return host
    }

    public mutating func update(_ id: UUID, name: String, address: String,
                                passwordKind: PasswordKind? = nil) throws {
        let (name, address) = try Self.clean(name, address)
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].name = name
        hosts[i].address = address
        if let passwordKind { hosts[i].passwordKind = passwordKind }
    }

    public mutating func markConnected(_ id: UUID, at date: Date) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].lastConnected = date
    }

    public mutating func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtection])
    }

    public static func load(from url: URL) throws -> HostList {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostList() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HostList.self, from: Data(contentsOf: url))
    }
}
