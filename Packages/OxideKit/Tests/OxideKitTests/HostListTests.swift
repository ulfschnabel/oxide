import Foundation
import Testing

@testable import OxideKit

struct HostListTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func addsAndFindsHosts() throws {
        var list = HostList()
        let office = try list.add(name: "Office PC", address: "192.168.1.8", now: t0)
        #expect(list.hosts == [office])
        #expect(list[office.id]?.address == "192.168.1.8")
    }

    @Test func refusesAnInvalidAddress() {
        var list = HostList()
        #expect(throws: HostListError.invalidAddress) { try list.add(name: "x", address: "host:abc", now: t0) }
        #expect(throws: HostListError.invalidAddress) { try list.add(name: "x", address: "  ", now: t0) }
    }

    @Test func trimsAndFallsBackToTheAddressForAName() throws {
        var list = HostList()
        let h = try list.add(name: "  ", address: " gamer.lan ", now: t0)
        #expect(h.address == "gamer.lan")
        #expect(h.displayName == "gamer.lan")
        #expect(try list.add(name: " Mac ", address: "mac.lan", now: t0).displayName == "Mac")
    }

    @Test func recentlyUsedComeFirstThenByName() throws {
        var list = HostList()
        let b = try list.add(name: "Beta", address: "b", now: t0)
        let a = try list.add(name: "alpha", address: "a", now: t0)
        let c = try list.add(name: "Charlie", address: "c", now: t0)
        #expect(list.sorted.map(\.id) == [a.id, b.id, c.id])  // never used: by name, case-insensitive
        list.markConnected(c.id, at: t0.addingTimeInterval(60))
        list.markConnected(b.id, at: t0.addingTimeInterval(120))
        #expect(list.sorted.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func updatesAHost() throws {
        var list = HostList()
        let h = try list.add(name: "Old", address: "a", now: t0)
        try list.update(h.id, name: "New", address: "b:5000")
        #expect(list[h.id]?.name == "New")
        #expect(list[h.id]?.address == "b:5000")
        #expect(throws: HostListError.invalidAddress) { try list.update(h.id, name: "New", address: "b:0") }
        #expect(list[h.id]?.address == "b:5000")  // unchanged on failure
    }

    @Test func removesAHost() throws {
        var list = HostList()
        let h = try list.add(name: "x", address: "a", now: t0)
        list.remove(h.id)
        #expect(list.hosts.isEmpty)
    }

    @Test func savesAndLoads() throws {
        var list = HostList()
        let h = try list.add(name: "Office", address: "10.0.0.5:21118", now: t0)
        list.markConnected(h.id, at: t0.addingTimeInterval(5))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try list.save(to: url)
        #expect(try HostList.load(from: url) == list)
    }

    @Test func aMissingFileIsAnEmptyList() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nothing-\(UUID()).json")
        #expect(try HostList.load(from: url).hosts.isEmpty)
    }

    @Test func passwordsAreNeverInTheFile() throws {
        var list = HostList()
        _ = try list.add(name: "x", address: "a", now: t0)
        let data = try JSONEncoder().encode(list)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let host = try #require((root["hosts"] as? [[String: Any]])?.first)
        // Only these fields: nothing that could hold a password.
        #expect(Set(host.keys) == ["id", "name", "address", "passwordKind", "createdAt"])
    }

    @Test func newHostsUseTheKindGiven() throws {
        var list = HostList()
        let h = try list.add(name: "Laptop", address: "a", passwordKind: .oneTime, now: t0)
        #expect(h.passwordKind == .oneTime)
        #expect(try list.add(name: "x", address: "b", now: t0).passwordKind == .permanent)
        try list.update(h.id, name: "Laptop", address: "a", passwordKind: .permanent)
        #expect(list[h.id]?.passwordKind == .permanent)
    }

    @Test func filesFromBeforePasswordKindsLoadAsPermanent() throws {
        let json = """
            {"hosts":[{"address":"10.0.0.5","createdAt":"2026-11-21T22:00:00Z",
              "id":"6F1D2A2E-4C1B-4D59-9C55-5B7D8B2E0A11","name":"Office"}]}
            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let list = try HostList.load(from: url)
        #expect(list.hosts.first?.passwordKind == .permanent)
        #expect(list.hosts.first?.name == "Office")
    }
}
