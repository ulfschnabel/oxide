import Foundation

/// What the user typed: `host`, `host:port`, `[ipv6]:port` or a bare IPv6
/// address. The port defaults to RustDesk's direct-access port.
public struct HostAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Nil for an empty host, one with a space, or a port that isn't 1–65535.
    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces)
        var host = s
        var portText = ""
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            portText = String(rest.dropFirst())
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            host = String(s[..<colon])
            portText = String(s[s.index(after: colon)...])
        }
        // More than one colon without brackets: a bare IPv6 address.
        // No host name or IP address has whitespace inside.
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        if portText.isEmpty {
            port = TCPTransport.defaultPort
        } else {
            guard let p = UInt16(portText), p > 0 else { return nil }
            port = p
        }
        self.host = host
    }
}
