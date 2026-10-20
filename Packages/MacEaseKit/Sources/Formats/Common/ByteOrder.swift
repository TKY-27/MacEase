import Foundation

extension UInt16 {
    init(littleEndian bytes: [UInt8], at offset: Int) {
        self = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}

extension UInt32 {
    init(littleEndian bytes: [UInt8], at offset: Int) {
        self =
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    init(bigEndian bytes: [UInt8], at offset: Int) {
        self =
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
