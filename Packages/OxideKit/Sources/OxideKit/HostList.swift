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
extension SavedHost {
    /// The demo computer inside the app: always in the list, never saved or synced.
    public static let demo = SavedHost(
        id: UUID(uuidString: "0E1D0E70-0000-4000-8000-00000000DE70")!, name: "Demo Computer",
        address: DemoHost.address, passwordKind: .permanent, createdAt: Date(timeIntervalSince1970: 0))

    public var isDemo: Bool { id == Self.demo.id }
}

public struct SavedHost: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public var passwordKind: PasswordKind
    public var createdAt: Date
    /// The last edit (name, address, password kind): the newer edit wins
    /// when devices sync.
    public var modifiedAt: Date
    public var lastConnected: Date?

    public var displayName: String { name.isEmpty ? address : name }

    init(id: UUID, name: String, address: String, passwordKind: PasswordKind, createdAt: Date) {
        self.id = id
        self.name = name
        self.address = address
        self.passwordKind = passwordKind
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, passwordKind, createdAt, modifiedAt, lastConnected
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        // Saved before there was a choice: those were all permanent.
        passwordKind = try c.decodeIfPresent(PasswordKind.self, forKey: .passwordKind) ?? .permanent
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }
}

public enum HostListError: Error, Equatable {
    case invalidAddress
}

/// A computer removed, remembered for a while so other devices remove it too.
public struct HostRemoval: Codable, Equatable, Sendable {
    public let id: UUID
    public let at: Date
}

/// The saved computers, as stored on disk and synced through iCloud.
public struct HostList: Codable, Equatable, Sendable {
    public private(set) var hosts: [SavedHost] = []
    public private(set) var removals: [HostRemoval] = []

    /// How long a removal is remembered: a device offline for longer may
    /// bring the computer back.
    public static let removalMemory: TimeInterval = 90 * 86_400

    public init() {}

    private enum CodingKeys: String, CodingKey { case hosts, removals }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decode([SavedHost].self, forKey: .hosts)
        removals = try c.decodeIfPresent([HostRemoval].self, forKey: .removals) ?? []
    }

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
                                passwordKind: PasswordKind? = nil, now: Date = .now) throws {
        let (name, address) = try Self.clean(name, address)
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].name = name
        hosts[i].address = address
        if let passwordKind { hosts[i].passwordKind = passwordKind }
        hosts[i].modifiedAt = now
    }

    public mutating func markConnected(_ id: UUID, at date: Date) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].lastConnected = date
    }

    public mutating func remove(_ id: UUID, at date: Date = .now) {
        hosts.removeAll { $0.id == id }
        removals.removeAll { $0.id == id }
        removals.append(HostRemoval(id: id, at: date))
    }

    /// Takes in another device's list. Per computer the newer edit wins, a
    /// removal wins over older edits, and "last connected" is the latest from
    /// either. The same computer (address, password kind and name) saved on
    /// both under different ids becomes one: the first one created stays. Returns those merged away, mapped to
    /// the one that stayed. The result doesn't depend on which side merges.
    @discardableResult
    public mutating func merge(_ other: HostList, now: Date) -> [UUID: UUID] {
        let before = hosts + other.hosts
        var byID: [UUID: SavedHost] = [:]
        for host in hosts + other.hosts {
            guard let mine = byID[host.id] else { byID[host.id] = host; continue }
            var winner = Self.newer(mine, host)
            winner.lastConnected = Self.latest(mine.lastConnected, host.lastConnected)
            byID[host.id] = winner
        }

        var removedAt: [UUID: Date] = [:]
        for r in removals + other.removals {
            removedAt[r.id] = max(removedAt[r.id] ?? r.at, r.at)
        }
        for (id, at) in removedAt where (byID[id]?.modifiedAt).map({ at >= $0 }) ?? false {
            byID[id] = nil
        }

        // The same computer saved on two devices: one entry.
        let bySameness = Dictionary(grouping: byID.values, by: Self.sameness)
        for group in bySameness.values where group.count > 1 {
            let ordered = group.sorted(by: Self.creationOrder)
            var keeper = ordered[0]
            for loser in ordered.dropFirst() {
                keeper.lastConnected = Self.latest(keeper.lastConnected, loser.lastConnected)
                byID[loser.id] = nil
                removedAt[loser.id] = max(removedAt[loser.id] ?? loser.modifiedAt, loser.modifiedAt)
            }
            byID[keeper.id] = keeper
        }

        // A fixed order, so both devices end up with equal lists.
        hosts = byID.values.sorted(by: Self.creationOrder)
        removals = removedAt
            .filter { now.timeIntervalSince($0.value) < Self.removalMemory }
            .map { HostRemoval(id: $0.key, at: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        // Gone, with the same computer left under another id: that one
        // replaces it (here or, earlier, on the other device).
        let survivors = Dictionary(hosts.map { (Self.sameness($0), $0.id) }, uniquingKeysWith: { a, _ in a })
        var replaced: [UUID: UUID] = [:]
        for host in before where byID[host.id] == nil {
            if let keeper = survivors[Self.sameness(host)], keeper != host.id { replaced[host.id] = keeper }
        }
        return replaced
    }

    /// Entries that are the same computer: address, password kind and name
    /// alike (case aside). Two entries for one address that differ are
    /// meant to be separate.
    private static func sameness(_ h: SavedHost) -> String {
        [h.address.lowercased(), h.passwordKind.rawValue, h.name.lowercased()].joined(separator: "\u{1F}")
    }

    private static func creationOrder(_ a: SavedHost, _ b: SavedHost) -> Bool {
        (a.createdAt, a.id.uuidString) < (b.createdAt, b.id.uuidString)
    }

    /// The later edit; on a tie, a fixed choice so both sides agree.
    private static func newer(_ a: SavedHost, _ b: SavedHost) -> SavedHost {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt ? a : b }
        return (a.name, a.address, a.passwordKind.rawValue) >= (b.name, b.address, b.passwordKind.rawValue) ? a : b
    }

    private static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): max(x, y)
        default: a ?? b
        }
    }

    /// JSON with dates as seconds since 1970, which round-trip exactly: a
    /// list read back equals the one written (for the file and for iCloud).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> HostList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            // Files from before syncing have ISO 8601 dates.
            let text = try c.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a date: \(text)")
        }
        return try decoder.decode(HostList.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: [.atomic, .completeFileProtection])
    }

    public static func load(from url: URL) throws -> HostList {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostList() }
        return try decoded(from: Data(contentsOf: url))
    }
}
