import Foundation

/// ISO/IEC 11172-3 Layer III constants for MPEG-1.
enum MP3Constants {
    static let granuleSize = 576
    static let maximumQuantized = 8206
    static let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    struct RateTables {
        let frequencyIndex: UInt32
        let longBands: [Int]
        let shortBands: [Int]
    }

    static func tables(for sampleRate: Int) -> RateTables? {
        switch sampleRate {
        case 44_100:
            RateTables(
                frequencyIndex: 0,
                longBands: [
                    0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576,
                ],
                shortBands: [0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192]
            )
        case 48_000:
            RateTables(
                frequencyIndex: 1,
                longBands: [
                    0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576,
                ],
                shortBands: [0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192]
            )
        default:
            nil
        }
    }

    /// Scalefactor bit widths per scalefac_compress value.
    static let slen: [(Int, Int)] = [
        (0, 0), (0, 1), (0, 2), (0, 3), (3, 0), (1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (2, 3), (3, 1), (3, 2), (3, 3),
        (4, 2), (4, 3),
    ]

    static let preemphasis = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2]

    static let aliasCoefficients: [(cs: Double, ca: Double)] = [
        -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037,
    ]
    .map { c in
        let root = (1 + c * c).squareRoot()
        return (1 / root, c / root)
    }

    /// Big-value tables by largest representable value.
    static let tableLimits: [(table: Int, limit: Int)] = [
        (1, 1), (2, 2), (3, 2), (5, 3), (6, 3), (7, 5), (8, 5), (9, 5), (10, 7), (11, 7), (12, 7), (13, 15), (15, 15),
    ]

    static let linbits: [Int: Int] = [
        16: 1, 17: 2, 18: 3, 19: 4, 20: 6, 21: 8, 22: 10, 23: 13, 24: 4, 25: 5, 26: 6, 27: 7, 28: 8, 29: 9, 30: 11,
        31: 13,
    ]
}

/// Bits written most significant first.
struct MSBBitWriter {
    private(set) var bytes: [UInt8] = []
    private var accumulator: UInt64 = 0
    private var pending = 0

    var bitCount: Int { bytes.count * 8 + pending }

    mutating func write(_ value: UInt32, bits: Int) {
        guard bits > 0 else { return }
        accumulator = accumulator << UInt64(bits) | UInt64(value) & ((1 << UInt64(bits)) - 1)
        pending += bits
        while pending >= 8 {
            pending -= 8
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(pending)))
        }
    }

    /// Zero-pads to a byte boundary.
    mutating func alignedBytes() -> [UInt8] {
        if pending > 0 { write(0, bits: 8 - pending) }
        return bytes
    }
}
