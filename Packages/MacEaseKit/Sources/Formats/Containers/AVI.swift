import Foundation

/// RIFF AVI and OpenDML 1.02 layout constants.
enum AVI {
    static let keyframeFlag: UInt32 = 0x10
    static let deltaFrameBit: UInt32 = 0x8000_0000
    static let indexOfIndexes: UInt8 = 0
    static let indexOfChunks: UInt8 = 1
    static let mainHeaderSize = 56
    static let streamHeaderSize = 56
    static let minimumStreamHeaderSize = 48
    static let bitmapInfoSize = 40
    static let waveFormatSize = 16
    static let waveFormatExSize = 18
    static let indexHeaderSize = 24
    static let superIndexEntrySize = 16
    static let standardIndexEntrySize = 8
    static let legacyIndexEntrySize = 16
    static let extendedHeaderSize = 248

    static func fourCC(_ code: String) -> Data {
        Data(code.utf8)
    }

    static func chunkID(stream: Int, suffix: String) -> Data {
        fourCC(String(format: "%02d", stream) + suffix)
    }
}
