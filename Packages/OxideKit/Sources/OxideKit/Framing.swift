import Foundation

/// RustDesk's `BytesCodec` framing: a 1–4 byte little-endian header holding
/// `(length << 2) | (headerBytes - 1)`, then the protobuf body.
public enum Framing {
    public static let maxLength = 0x3FFF_FFFF

    public static func encode(_ body: Data) -> Data {
        let n = body.count
        precondition(n <= maxLength, "frame too large")
        let size = n <= 0x3F ? 1 : n <= 0x3FFF ? 2 : n <= 0x3F_FFFF ? 3 : 4
        var header = UInt32(n) << 2 | UInt32(size - 1)
        var out = Data(capacity: size + n)
        for _ in 0..<size {
            out.append(UInt8(header & 0xFF))
            header >>= 8
        }
        out.append(body)
        return out
    }
}

public enum FramingError: Error, Equatable {
    case tooLarge(Int)
}

/// Reassembles frames from a byte stream that arrives in arbitrary pieces.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private let maxLength: Int

    public init(maxLength: Int = Framing.maxLength) {
        self.maxLength = maxLength
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let first = buffer.first {
            let size = Int(first & 3) + 1
            guard buffer.count >= size else { break }
            var header = 0
            for (i, byte) in buffer.prefix(size).enumerated() {
                header |= Int(byte) << (8 * i)
            }
            let length = header >> 2
            guard length <= maxLength else { throw FramingError.tooLarge(length) }
            guard buffer.count >= size + length else { break }
            let start = buffer.startIndex + size
            frames.append(Data(buffer[start..<start + length]))
            buffer.removeFirst(size + length)
        }
        return frames
    }
}
