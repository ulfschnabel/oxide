import Foundation
import Testing

@testable import OxideKit

/// Merging the saved computers of two devices (through iCloud).
struct HostSyncTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func computersFromAnotherDeviceAreAdded() throws {
        var phone = HostList()
        try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        var mac = HostList()
        try mac.add(name: "caiman", address: "192.168.1.9", now: at(5))
        phone.merge(mac, now: at(10))
        #expect(Set(phone.hosts.map(\.name)) == ["jabiru", "caiman"])
    }

    @Test func theNewerEditWins() throws {
        var phone = HostList()
        let host = try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        var mac = phone
        try mac.update(host.id, name: "WoW box", address: "192.168.1.7", now: at(20))
        try phone.update(host.id, name: "Gaming", address: "192.168.1.7", now: at(10))
        var a = phone
        a.merge(mac, now: at(30))
        #expect(a[host.id]?.name == "WoW box")
        var b = mac
        b.merge(phone, now: at(30))
        #expect(b[host.id]?.name == "WoW box")
    }

    @Test func aRemovalWinsOverOlderEdits() throws {
        var phone = HostList()
        let host = try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        let mac = phone
        phone.remove(host.id, at: at(10))
        var merged = mac
        merged.merge(phone, now: at(20))
        #expect(merged[host.id] == nil)
        // And it stays removed when the other device's list comes back.
        merged.merge(mac, now: at(30))
        #expect(merged[host.id] == nil)
    }

    @Test func anEditAfterARemovalKeepsTheComputer() throws {
        // Edited on one device after it was removed on another: the edit is newer.
        var phone = HostList()
        let host = try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        var mac = phone
        phone.remove(host.id, at: at(10))
        try mac.update(host.id, name: "jabiru 2", address: "192.168.1.7", now: at(20))
        phone.merge(mac, now: at(30))
        #expect(phone[host.id]?.name == "jabiru 2")
    }

    @Test func lastConnectedIsTheLatestFromAnyDevice() throws {
        var phone = HostList()
        let host = try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        var mac = phone
        phone.markConnected(host.id, at: at(50))
        mac.markConnected(host.id, at: at(40))
        try mac.update(host.id, name: "renamed", address: "192.168.1.7", now: at(45))
        phone.merge(mac, now: at(60))
        #expect(phone[host.id]?.name == "renamed")
        #expect(phone[host.id]?.lastConnected == at(50))
    }

    @Test func mergingEitherWayGivesTheSameList() throws {
        // Otherwise two devices would keep sending each other their version.
        var phone = HostList()
        let shared = try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        var mac = phone
        try phone.add(name: "a", address: "10.0.0.1", now: at(5))
        try mac.add(name: "b", address: "10.0.0.2", now: at(6))
        try mac.update(shared.id, name: "x", address: "192.168.1.7", now: at(7))
        phone.remove(shared.id, at: at(3))
        var ab = phone
        ab.merge(mac, now: at(10))
        var ba = mac
        ba.merge(phone, now: at(10))
        #expect(ab == ba)
    }

    @Test func theSameComputerAddedOnTwoDevicesBecomesOne() throws {
        var phone = HostList()
        let first = try phone.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        var mac = HostList()
        let second = try mac.add(name: "Jabiru", address: " 192.168.1.7", now: at(5))
        mac.markConnected(second.id, at: at(8))
        let replaced = phone.merge(mac, now: at(10))
        #expect(phone.hosts.map(\.id) == [first.id])
        #expect(phone[first.id]?.lastConnected == at(8))
        #expect(replaced == [second.id: first.id])
        // The other device ends up with the same one.
        let replacedThere = mac.merge(phone, now: at(11))
        #expect(mac.hosts.map(\.id) == [first.id])
        #expect(replacedThere == [second.id: first.id])
    }

    @Test func differentEntriesForOneAddressStay() throws {
        // Another name or another password kind: meant as separate entries.
        var phone = HostList()
        try phone.add(name: "Mac", address: "127.0.0.1", passwordKind: .permanent, now: at(0))
        try phone.add(name: "Mac one-time", address: "127.0.0.1", passwordKind: .oneTime, now: at(1))
        var mac = HostList()
        try mac.add(name: "Mac", address: "127.0.0.1", passwordKind: .oneTime, now: at(2))
        let replaced = phone.merge(mac, now: at(10))
        #expect(phone.hosts.count == 3)
        #expect(replaced.isEmpty)
    }

    @Test func oldRemovalsAreForgotten() throws {
        var list = HostList()
        let host = try list.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        list.remove(host.id, at: at(10))
        #expect(list.removals.count == 1)
        list.merge(HostList(), now: at(10 + 91 * 86_400))
        #expect(list.removals.isEmpty)
    }

    @Test func editsRecordWhenTheyWereMade() throws {
        var list = HostList()
        let host = try list.add(name: "jabiru", address: "192.168.1.7", now: at(0))
        #expect(list[host.id]?.modifiedAt == at(0))
        try list.update(host.id, name: "j", address: "192.168.1.7", now: at(5))
        #expect(list[host.id]?.modifiedAt == at(5))
        // Connecting isn't an edit.
        list.markConnected(host.id, at: at(9))
        #expect(list[host.id]?.modifiedAt == at(5))
    }

    @Test func readsAListSavedBeforeSyncing() throws {
        let json = """
            {"hosts":[{"id":"5B1E7A2C-8F7E-4C0B-9A57-2C1D3E4F5A6B","name":"jabiru","address":"192.168.1.7",
            "passwordKind":"permanent","createdAt":"2026-11-21T10:00:00Z"}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode(HostList.self, from: Data(json.utf8))
        #expect(list.hosts.first?.modifiedAt == list.hosts.first?.createdAt)
        #expect(list.removals.isEmpty)
    }
}

struct HostListEncodingTests {
    @Test func roundTripsExactly() throws {
        // Fractions of a second included: a list read back must equal the
        // one written, or devices would keep sending each other "changes".
        var list = HostList()
        let host = try list.add(name: "jabiru", address: "192.168.1.7", now: Date(timeIntervalSince1970: 1_800_000_000.123456))
        list.markConnected(host.id, at: Date(timeIntervalSince1970: 1_800_000_100.5))
        list.remove(UUID(), at: Date(timeIntervalSince1970: 1_800_000_200.25))
        let back = try HostList.decoded(from: list.encoded())
        #expect(back == list)
    }

    @Test func readsWholeSecondDatesToo() throws {
        let json = """
            {"hosts":[{"id":"5B1E7A2C-8F7E-4C0B-9A57-2C1D3E4F5A6B","name":"jabiru","address":"192.168.1.7",
            "passwordKind":"permanent","createdAt":"2026-11-21T10:00:00Z"}]}
            """
        let list = try HostList.decoded(from: Data(json.utf8))
        #expect(list.hosts.first?.createdAt == ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z"))
    }
}
