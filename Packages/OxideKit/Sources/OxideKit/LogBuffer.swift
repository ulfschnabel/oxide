import Foundation

/// The newest diagnostic lines, oldest first, as text one can paste into a
/// bug report. Callers never pass secrets.
public struct LogBuffer: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let date: Date
        public let message: String
    }

    public let capacity: Int
    public private(set) var lines: [Line] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// Restores a buffer from `text(timeZone:)`; lines it can't read are skipped.
    public init(text: String, capacity: Int, timeZone: TimeZone = .current) {
        self.init(capacity: capacity)
        let format = Self.format(timeZone)
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let date = format.date(from: "\(parts[0]) \(parts[1])") else { continue }
            append(String(parts[2].dropFirst()), at: date)  // two spaces separate time and message
        }
    }

    public mutating func append(_ message: String, at date: Date) {
        lines.append(Line(date: date, message: message.replacingOccurrences(of: "\n", with: " ")))
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    public mutating func removeAll() {
        lines.removeAll()
    }

    public func text(timeZone: TimeZone = .current) -> String {
        let format = Self.format(timeZone)
        return lines.map { "\(format.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
    }

    private static func format(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }
}
