import CDeflate
import Darwin
import Foundation

struct ZIPDirectory {
    let entries: Int
    let endOffset: Int64
    let members: [ZIPMember]
}

struct ZIPMember {
    private(set) var name: [UInt8]
    private let unicodeName: [UInt8]?
    let rawName: [UInt8]
    let localOffset: Int64
    let size: UInt64
    let method: UInt16
    let flags: UInt16
    let isSymlink: Bool
    private let modeIsDirectory: Bool
    var isDirectory: Bool { modeIsDirectory || name.last == 47 }

    init(header: [UInt8], fields: [UInt8], adjustment: Int64) throws {
        let nameCount = Int(UInt16(littleEndian: header, at: 28))
        rawName = Array(fields.prefix(nameCount))
        flags = UInt16(littleEndian: header, at: 8)
        var selectedUnicode: [UInt8]?
        var compression = UInt16(littleEndian: header, at: 10)
        var uncompressed = UInt64(UInt32(littleEndian: header, at: 24))
        var local = UInt64(UInt32(littleEndian: header, at: 42))
        var resolvedSize = false
        var resolvedOffset = false
        let extras = Array(fields[nameCount..<(nameCount + Int(UInt16(littleEndian: header, at: 30)))])
        for field in try Self.extraFields(extras) {
            let payload = field.payload
            switch field.kind {
            case 0x7075:
                if let candidate = Self.unicodePath(payload, raw: rawName) { selectedUnicode = candidate }
            case 0x9901 where payload.count == 7 && compression == 99:
                compression = UInt16(littleEndian: payload, at: 5)
            case 1:
                var cursor = 0
                if uncompressed == UInt64(UInt32.max) {
                    uncompressed = try Self.read64(payload, at: cursor)
                    resolvedSize = true
                    cursor += 8
                }
                if UInt32(littleEndian: header, at: 20) == .max { cursor += 8 }
                if UInt32(littleEndian: header, at: 42) == .max {
                    local = try Self.read64(payload, at: cursor)
                    resolvedOffset = true
                }
            default: break
            }
        }
        guard (UInt32(littleEndian: header, at: 42) != .max || resolvedOffset),
            (UInt32(littleEndian: header, at: 24) != .max || resolvedSize),
            local <= UInt64(Int64.max), adjustment >= 0, Int64(local) <= Int64.max - adjustment
        else { throw ZIPBrowserError.invalidZIP }
        unicodeName = selectedUnicode
        name = selectedUnicode ?? rawName
        size = uncompressed
        localOffset = Int64(local) + adjustment
        method = compression
        let unix = header[5] == 3 || header[5] == 19
        let mode = UInt32(littleEndian: header, at: 38) >> 16
        isSymlink = unix && mode & UInt32(S_IFMT) == UInt32(S_IFLNK)
        modeIsDirectory =
            (unix && mode & UInt32(S_IFMT) == UInt32(S_IFDIR))
            || (header[5] == 0 && UInt32(littleEndian: header, at: 38) & 0x10 != 0)
    }

    mutating func useLocalName(_ raw: [UInt8], extras: [UInt8]) throws {
        guard unicodeName == nil else { return }
        name = raw
        for field in try Self.extraFields(extras) where field.kind == 0x7075 {
            if let candidate = Self.unicodePath(field.payload, raw: raw) { name = candidate }
        }
    }

    private static func unicodePath(_ payload: [UInt8], raw: [UInt8]) -> [UInt8]? {
        guard payload.count >= 5, payload[0] == 1 else { return nil }
        let candidate = Array(payload.dropFirst(5))
        let crc = raw.withUnsafeBytes { libdeflate_crc32(0, $0.baseAddress, $0.count) }
        guard UInt32(littleEndian: payload, at: 1) == crc, String(bytes: candidate, encoding: .utf8) != nil else {
            return nil
        }
        return candidate
    }

    static func sanitizeNames(
        _ source: ArchiveReadSource, raw: [UInt8], extras: [UInt8], flags: UInt16,
        flagsOffset: Int64, extrasOffset: Int64
    ) throws {
        if flags & 0x800 != 0, String(bytes: raw, encoding: .utf8) == nil {
            source.replaceByte(at: flagsOffset + 1, with: UInt8(truncatingIfNeeded: flags >> 8) & ~8)
        }
        for field in try extraFields(extras) where field.kind == 0x7075 {
            if unicodePath(field.payload, raw: raw) == nil {
                source.replaceByte(at: extrasOffset + Int64(field.offset), with: 0)
                source.replaceByte(at: extrasOffset + Int64(field.offset + 1), with: 0)
            }
        }
    }

    private static func read64(_ bytes: [UInt8], at offset: Int) throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw ZIPBrowserError.invalidZIP }
        return UInt64(UInt32(littleEndian: bytes, at: offset)) | UInt64(UInt32(littleEndian: bytes, at: offset + 4))
            << 32
    }

    private static func extraFields(_ bytes: [UInt8]) throws -> [(kind: UInt16, offset: Int, payload: [UInt8])] {
        var result: [(UInt16, Int, [UInt8])] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(UInt16(littleEndian: bytes, at: offset + 2))
            let end = offset + 4 + length
            guard end <= bytes.count else { throw ZIPBrowserError.invalidZIP }
            result.append((UInt16(littleEndian: bytes, at: offset), offset, Array(bytes[(offset + 4)..<end])))
            offset = end
        }
        return result
    }
}
