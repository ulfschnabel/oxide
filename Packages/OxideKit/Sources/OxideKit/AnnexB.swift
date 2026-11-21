import Foundation

/// H.264/H.265 byte streams as the host sends them: NAL units separated by
/// 00 00 01 or 00 00 00 01 start codes, parameter sets in-band.
public enum AnnexB {
    /// The NAL units of a byte stream, without start codes.
    public static func nalUnits(in stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    // A 4-byte start code's leading zero belongs to it, not the unit.
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[s..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count {
            units.append(Data(bytes[s...]))
        }
        return units
    }

    /// NAL units as AVCC/HVCC: each prefixed with its 4-byte big-endian length.
    public static func avcc(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let n = UInt32(unit.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(unit)
        }
        return out
    }
}
