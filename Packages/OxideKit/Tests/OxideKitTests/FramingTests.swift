import Foundation
import Testing

@testable import OxideKit

struct FramingTests {
    @Test func headerSizeGrowsWithLength() {
        // (len << 2) | (headerBytes - 1), little-endian.
        #expect(Framing.encode(Data(count: 44)).prefix(1) == Data([0xB0]))
        #expect(Framing.encode(Data(count: 63)).count == 64)
        #expect(Framing.encode(Data(count: 64)).prefix(2) == Data([0x01, 0x01]))
        #expect(Framing.encode(Data(count: 0x3FFF)).count == 0x3FFF + 2)
        #expect(Framing.encode(Data(count: 0x4000)).prefix(3) == Data([0x02, 0x00, 0x01]))
        #expect(Framing.encode(Data(count: 0x400000)).prefix(4) == Data([0x03, 0x00, 0x00, 0x01]))
    }

    @Test func decodesFramesSplitAcrossReads() throws {
        let bodies = [Data(repeating: 1, count: 44), Data(repeating: 2, count: 300), Data()]
        let stream = bodies.reduce(Data()) { $0 + Framing.encode($1) }
        var decoder = FrameDecoder()
        var out: [Data] = []
        // Feed one byte at a time: headers and bodies arrive in pieces.
        for byte in stream {
            out += try decoder.append(Data([byte]))
        }
        #expect(out == bodies)
    }

    @Test func decodesSeveralFramesInOneRead() throws {
        let bodies = [Data([1, 2, 3]), Data([4])]
        var decoder = FrameDecoder()
        #expect(try decoder.append(bodies.reduce(Data()) { $0 + Framing.encode($1) }) == bodies)
    }

    @Test func rejectsOversizeFrames() {
        var decoder = FrameDecoder(maxLength: 100)
        #expect(throws: FramingError.tooLarge(101)) {
            try decoder.append(Framing.encode(Data(count: 101)).prefix(2))
        }
    }
}

struct PasswordHashTests {
    @Test func matchesTheHostsAlgorithm() {
        // SHA256(SHA256(password ‖ salt) ‖ challenge), computed independently in Python.
        let hash = PasswordHash.compute(
            password: "secret", salt: "3sw43b8vdbub38zv9c42jcjcdtfwj5cc", challenge: "2qa9b3")
        #expect(hash.hex == "84f5644681cbd1d0e70d2957483cfef0a131036391112e1a12b6f5a1fb340751")
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct HostAddressTests {
    @Test func rejectsABadPort() {
        #expect(HostAddress("host:abc") == nil)
        #expect(HostAddress("host:0") == nil)
        #expect(HostAddress("host:70000") == nil)
        #expect(HostAddress("") == nil)
        #expect(HostAddress("host:") == HostAddress(host: "host", port: 21118))
    }

    @Test func defaultsToTheDirectAccessPort() {
        #expect(HostAddress("192.168.1.8") == HostAddress(host: "192.168.1.8", port: 21118))
        #expect(HostAddress(" gamer.lan ") == HostAddress(host: "gamer.lan", port: 21118))
    }

    @Test func takesAPort() {
        #expect(HostAddress("127.0.0.1:21119") == HostAddress(host: "127.0.0.1", port: 21119))
    }

    @Test func handlesIPv6() {
        #expect(HostAddress("[fe80::1]:5000") == HostAddress(host: "fe80::1", port: 5000))
        #expect(HostAddress("fe80::1") == HostAddress(host: "fe80::1", port: 21118))
    }
}
