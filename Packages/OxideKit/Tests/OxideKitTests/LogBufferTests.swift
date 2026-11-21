import Foundation
import Testing

@testable import OxideKit

struct LogBufferTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00:00 UTC

    @Test func keepsTheNewestLines() {
        var log = LogBuffer(capacity: 3)
        for i in 1...5 { log.append("line \(i)", at: t0) }
        #expect(log.lines.map(\.message) == ["line 3", "line 4", "line 5"])
    }

    @Test func formatsWithTimeOfDay() {
        var log = LogBuffer(capacity: 10)
        log.append("connecting to 192.168.1.7", at: t0.addingTimeInterval(1.25))
        #expect(log.text(timeZone: TimeZone(identifier: "UTC")!) == "2027-01-15 08:00:01.250  connecting to 192.168.1.7")
    }

    @Test func roundTripsThroughItsText() {
        var log = LogBuffer(capacity: 10)
        log.append("one", at: t0)
        log.append("two: with  spaces", at: t0.addingTimeInterval(2))
        let utc = TimeZone(identifier: "UTC")!
        let restored = LogBuffer(text: log.text(timeZone: utc), capacity: 10, timeZone: utc)
        #expect(restored.lines == log.lines)
    }

    @Test func multiLineMessagesStayOneLine() {
        var log = LogBuffer(capacity: 10)
        log.append("a\nb", at: t0)
        #expect(log.lines.first?.message == "a b")
    }
}
