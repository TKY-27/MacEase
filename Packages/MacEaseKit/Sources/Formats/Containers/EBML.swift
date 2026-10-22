import Foundation

/// EBML variable-length integers (RFC 8794).
enum EBML {
    struct Header {
        let id: UInt32
        /// `nil` for unknown-size elements.
        let size: Int64?
        let dataStart: Int64
    }

    static func readHeader(_ file: RandomAccessFile, at offset: Int64) throws -> Header {
        let (id, idLength) = try readVint(file, at: offset, keepMarker: true)
        guard idLength <= 4 else { throw FormatError.corrupt("EBML ID too long") }
        let (size, sizeLength) = try readVint(file, at: offset + Int64(idLength), keepMarker: false)
        let allOnes = (UInt64(1) << UInt64(7 * sizeLength)) - 1
        return Header(
            id: UInt32(id), size: size == allOnes ? nil : Int64(size), dataStart: offset + Int64(idLength + sizeLength)
        )
    }

    static func readVint(_ file: RandomAccessFile, at offset: Int64, keepMarker: Bool) throws -> (UInt64, Int) {
        let first = try file.byte(at: offset)
        guard first != 0 else { throw FormatError.corrupt("invalid EBML length marker") }
        let length = first.leadingZeroBitCount + 1
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        if length > 1 {
            for byte in try file.bytes(at: offset + 1, count: length - 1) { value = value << 8 | UInt64(byte) }
        }
        return (value, length)
    }

    /// Parses a vint inside an in-memory block.
    static func readVint(_ bytes: [UInt8], at offset: Int) throws -> (UInt64, Int) {
        guard offset < bytes.count, bytes[offset] != 0 else { throw FormatError.corrupt("invalid block vint") }
        let length = bytes[offset].leadingZeroBitCount + 1
        guard offset + length <= bytes.count else { throw FormatError.corrupt("truncated block vint") }
        var value = UInt64(bytes[offset] & (0xFF >> length))
        for index in 1..<length { value = value << 8 | UInt64(bytes[offset + index]) }
        return (value, length)
    }

    static func unsigned(_ bytes: [UInt8]) throws -> UInt64 {
        guard bytes.count <= 8 else { throw FormatError.corrupt("EBML integer over 8 bytes") }
        return bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func signed(_ bytes: [UInt8]) throws -> Int64 {
        guard let first = bytes.first else { return 0 }
        let value = Int64(bitPattern: try unsigned(bytes))
        let unused = Int64(64 - 8 * bytes.count)
        return first & 0x80 == 0 || unused == 0 ? value : (value << unused) >> unused
    }

    static func integer(_ bytes: [UInt8]) throws -> Int {
        guard let value = Int(exactly: try unsigned(bytes)) else { throw FormatError.corrupt("EBML integer too large") }
        return value
    }

    /// RFC 8794: an empty float is 0.
    static func float(_ bytes: [UInt8]) throws -> Double {
        switch bytes.count {
        case 0: 0
        case 4: Double(Float(bitPattern: UInt32(try unsigned(bytes))))
        case 8: Double(bitPattern: try unsigned(bytes))
        default: throw FormatError.corrupt("EBML float of \(bytes.count) bytes")
        }
    }

    static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func encodeID(_ id: UInt32) -> [UInt8] {
        let bytes = [UInt8(id >> 24), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
        return Array(bytes.drop { $0 == 0 })
    }

    /// Smallest size, or fixed width for patching.
    static func encodeSize(_ size: Int64, width: Int? = nil) -> [UInt8] {
        var length = width ?? 1
        while width == nil, length < 8, size >= (Int64(1) << Int64(7 * length)) - 1 { length += 1 }
        var bytes = [UInt8](repeating: 0, count: length)
        var remaining = UInt64(size)
        for index in stride(from: length - 1, through: 0, by: -1) {
            bytes[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    static func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        encodeID(id) + encodeSize(Int64(payload.count)) + payload
    }

    static func element(_ id: UInt32, unsigned value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return element(id, bytes)
    }

    static func element(_ id: UInt32, signed value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        } while !(remaining == 0 && bytes[0] & 0x80 == 0 || remaining == -1 && bytes[0] & 0x80 != 0)
        return element(id, bytes)
    }

    static func element(_ id: UInt32, float value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0..<8).map { UInt8(bits >> UInt64(56 - 8 * $0) & 0xFF) })
    }

    static func element(_ id: UInt32, string value: String) -> [UInt8] {
        element(id, Array(value.utf8))
    }
}
