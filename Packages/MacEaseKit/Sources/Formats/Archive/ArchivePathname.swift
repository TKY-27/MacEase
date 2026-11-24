import CArchive
import Foundation

public enum ArchivePathname {
    private static let cp932 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    public static func decode(_ entry: OpaquePointer) throws -> String {
        guard let pathname = try decode(utf8: archive_entry_pathname_utf8(entry), raw: archive_entry_pathname(entry))
        else {
            throw ArchiveError.unsupportedNameEncoding
        }
        return pathname
    }

    static func symlink(_ entry: OpaquePointer) throws -> String? {
        try decode(utf8: archive_entry_symlink_utf8(entry), raw: archive_entry_symlink(entry))
    }

    static func hardlink(_ entry: OpaquePointer) throws -> String? {
        try decode(utf8: archive_entry_hardlink_utf8(entry), raw: archive_entry_hardlink(entry))
    }

    private static func decode(utf8: UnsafePointer<CChar>?, raw: UnsafePointer<CChar>?) throws -> String? {
        if let utf8, let pathname = String(validatingCString: utf8) { return pathname }
        guard let raw else { return nil }
        let bytes = Array(
            UnsafeBufferPointer(start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self), count: strlen(raw)))
        return try decode(bytes)
    }

    static func decode(_ bytes: [UInt8]) throws -> String {
        if let pathname = String(bytes: bytes, encoding: .utf8) { return pathname }
        guard validCP932(bytes), let pathname = String(bytes: bytes, encoding: cp932),
            pathname.unicodeScalars.allSatisfy({ scalar in
                scalar.properties.generalCategory != .privateUse
                    && (scalar.properties.generalCategory != .control || [9, 10, 13].contains(scalar.value))
            })
        else { throw ArchiveError.unsupportedNameEncoding }
        return pathname
    }

    private static func validCP932(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead <= 0x7F || (0xA1...0xDF).contains(lead) {
                index += 1
                continue
            }
            guard (0x81...0x9F).contains(lead) || (0xE0...0xFC).contains(lead), index + 1 < bytes.count else {
                return false
            }
            let trail = bytes[index + 1]
            guard (0x40...0x7E).contains(trail) || (0x80...0xFC).contains(trail), assignedCP932(lead, trail) else {
                return false
            }
            index += 2
        }
        return true
    }

    // Foundation also accepts non-CP932 Apple extensions.
    private static func assignedCP932(_ lead: UInt8, _ trail: UInt8) -> Bool {
        switch lead {
        case 0x81:
            return [0x40...0x7E, 0x80...0xAC, 0xB8...0xBF, 0xC8...0xCE, 0xDA...0xE8, 0xF0...0xF7, 0xFC...0xFC]
                .contains { $0.contains(trail) }
        case 0x82:
            return [0x4F...0x58, 0x60...0x79, 0x81...0x9A, 0x9F...0xF1].contains { $0.contains(trail) }
        case 0x83:
            return trail <= 0x96 || (0x9F...0xB6).contains(trail) || (0xBF...0xD6).contains(trail)
        case 0x84:
            return trail <= 0x60 || (0x70...0x91).contains(trail) || (0x9F...0xBE).contains(trail)
        case 0x87:
            return trail <= 0x5D || (0x5F...0x75).contains(trail) || (0x7E...0x9C).contains(trail)
        case 0x88: return trail >= 0x9F
        case 0x89...0x97, 0x99...0x9F, 0xE0...0xE9, 0xED, 0xFA, 0xFB: return true
        case 0x98: return trail <= 0x72 || trail >= 0x9F
        case 0xEA: return trail <= 0xA4
        case 0xEE: return trail <= 0xEC || trail >= 0xEF
        case 0xFC: return trail <= 0x4B
        default: return false
        }
    }
}
