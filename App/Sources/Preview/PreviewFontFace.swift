import Compression
import CoreText
import Darwin
import Foundation
import zlib

enum PreviewFontError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge
    case tooManyFaces
}

// CTFontDescriptor is immutable.
struct PreviewFontFace: @unchecked Sendable {
    static let specimenSizes: [CGFloat] = [12, 16, 20, 28, 40, 64]
    static let maximumFileBytes: Int64 = 64 * 1024 * 1024
    static let maximumFaceCount = 64
    private static let ttcHeaderBytes = 12
    private static let woff1HeaderBytes = 44
    private static let woff2HeaderBytes = 48
    private static let woff1TableEntryBytes = 20
    private static let sfntHeaderBytes = 12
    private static let sfntTableEntryBytes = 16
    private static let scratchBytes = 64 * 1024
    private static let ttcTag: [UInt8] = Array("ttcf".utf8)
    private static let woff1Tag: [UInt8] = Array("wOFF".utf8)
    private static let woff2Tag: [UInt8] = Array("wOF2".utf8)
    private static let ttcTagValue: UInt32 = 0x7474_6366
    private static let ttcVersion1: UInt32 = 0x0001_0000
    private static let ttcVersion2: UInt32 = 0x0002_0000

    let displayName: String
    let styleName: String?
    let glyphCount: Int
    let index: Int
    let faceNames: [String]
    private let descriptors: [CTFontDescriptor]

    var faceCount: Int { descriptors.count }

    private init(index: Int, descriptors: [CTFontDescriptor], faceNames: [String]) {
        let font = CTFontCreateWithFontDescriptor(descriptors[index], Self.specimenSizes[0], nil)
        self.index = index
        self.descriptors = descriptors
        self.faceNames = faceNames
        displayName = faceNames[index]
        let style = CTFontCopyLocalizedName(font, kCTFontStyleNameKey, nil) as String?
        styleName = style?.isEmpty == false ? style : nil
        glyphCount = CTFontGetGlyphCount(font)
    }

    static func load(
        _ url: URL, maximumFileBytes: Int64 = maximumFileBytes, maximumFaceCount: Int = maximumFaceCount
    ) throws -> Self {
        try Task.checkCancellation()
        try validateBounds(url, maximumFileBytes: maximumFileBytes, maximumFaceCount: maximumFaceCount)
        try Task.checkCancellation()
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            !descriptors.isEmpty
        else {
            throw PreviewFontError.unreadable
        }
        guard descriptors.count <= maximumFaceCount else {
            throw PreviewFontError.tooManyFaces
        }
        let names = try descriptors.map { descriptor in
            try Task.checkCancellation()
            let sample = CTFontCreateWithFontDescriptor(descriptor, specimenSizes[0], nil)
            return resolvedName(for: sample, fallbackURL: url)
        }
        return Self(index: 0, descriptors: descriptors, faceNames: names)
    }

    func selecting(_ index: Int) -> Self? {
        guard descriptors.indices.contains(index) else { return nil }
        return Self(index: index, descriptors: descriptors, faceNames: faceNames)
    }

    func font(size: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(descriptors[index], size, nil)
    }

    // Reject oversized, compressed-bomb or huge collections upfront.
    private static func validateBounds(_ url: URL, maximumFileBytes: Int64, maximumFaceCount: Int) throws {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PreviewFontError.unreadable }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 0 else {
            throw PreviewFontError.unreadable
        }
        guard Int64(status.st_size) <= maximumFileBytes else {
            throw PreviewFontError.tooLarge
        }
        var header = [UInt8](repeating: 0, count: woff2HeaderBytes)
        let readCount = header.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, woff2HeaderBytes) }
        guard readCount >= ttcHeaderBytes else { return }
        if header.starts(with: ttcTag) {
            let version = uint32BE(header, at: 4)
            guard version == ttcVersion1 || version == ttcVersion2 else { return }
            let faceCount = uint32BE(header, at: 8)
            guard faceCount > 0 else { throw PreviewFontError.unreadable }
            guard faceCount <= UInt32(maximumFaceCount) else { throw PreviewFontError.tooManyFaces }
            return
        }
        if header.starts(with: woff1Tag), readCount >= woff1HeaderBytes {
            let bytes = try readAll(descriptor: descriptor, expectedSize: Int(status.st_size))
            try validateWOFF1(bytes, maximumFileBytes: maximumFileBytes)
            return
        }
        if header.starts(with: woff2Tag), readCount >= woff2HeaderBytes {
            let bytes = try readAll(descriptor: descriptor, expectedSize: Int(status.st_size))
            try validateWOFF2(bytes, maximumFileBytes: maximumFileBytes, maximumFaceCount: maximumFaceCount)
        }
    }

    private static func readAll(descriptor: Int32, expectedSize: Int) throws -> [UInt8] {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw PreviewFontError.unreadable }
        var bytes = [UInt8](repeating: 0, count: expectedSize)
        var offset = 0
        while offset < expectedSize {
            try Task.checkCancellation()
            let received = bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), expectedSize - offset)
            }
            if received == 0 { break }
            if received < 0 {
                if errno == EINTR { continue }
                throw PreviewFontError.unreadable
            }
            offset += received
        }
        return offset == expectedSize ? bytes : Array(bytes.prefix(offset))
    }

    private static func validateWOFF1(_ bytes: [UInt8], maximumFileBytes: Int64) throws {
        guard bytes.count >= woff1HeaderBytes else { throw PreviewFontError.unreadable }
        let numTables = Int(uint16BE(bytes, at: 12))
        let totalSFNTSize = Int64(uint32BE(bytes, at: 16))
        let metaOffset = Int(uint32BE(bytes, at: 24))
        let metaLength = Int(uint32BE(bytes, at: 28))
        let metaOrigLength = Int64(uint32BE(bytes, at: 32))
        guard totalSFNTSize <= maximumFileBytes, metaOrigLength <= maximumFileBytes else {
            throw PreviewFontError.tooLarge
        }
        let directoryEnd = woff1HeaderBytes + numTables * woff1TableEntryBytes
        guard directoryEnd <= bytes.count else { throw PreviewFontError.unreadable }
        var declaredTotal = Int64(sfntHeaderBytes + numTables * sfntTableEntryBytes)
        var expandedTotal: Int64 = 0
        for index in 0..<numTables {
            try Task.checkCancellation()
            let entry = woff1HeaderBytes + index * woff1TableEntryBytes
            let offset = Int(uint32BE(bytes, at: entry + 4))
            let compLength = Int(uint32BE(bytes, at: entry + 8))
            let origLength = Int64(uint32BE(bytes, at: entry + 12))
            declaredTotal += (origLength + 3) & ~3
            guard declaredTotal <= maximumFileBytes else { throw PreviewFontError.tooLarge }
            guard offset >= directoryEnd, compLength >= 0, offset + compLength <= bytes.count else {
                throw PreviewFontError.unreadable
            }
            if compLength < Int(origLength) {
                let remaining = maximumFileBytes - expandedTotal
                expandedTotal += try inflateBounded(
                    Array(bytes[offset..<(offset + compLength)]), limit: remaining)
            } else {
                expandedTotal += Int64(compLength)
                guard expandedTotal <= maximumFileBytes else { throw PreviewFontError.tooLarge }
            }
        }
        if metaLength > 0, metaOffset >= woff1HeaderBytes, metaOffset + metaLength <= bytes.count {
            _ = try inflateBounded(Array(bytes[metaOffset..<(metaOffset + metaLength)]), limit: maximumFileBytes)
        }
    }

    private static func validateWOFF2(
        _ bytes: [UInt8], maximumFileBytes: Int64, maximumFaceCount: Int
    ) throws {
        guard bytes.count >= woff2HeaderBytes else { throw PreviewFontError.unreadable }
        let flavor = uint32BE(bytes, at: 4)
        let numTables = Int(uint16BE(bytes, at: 12))
        let totalSFNTSize = Int64(uint32BE(bytes, at: 16))
        let totalCompressedSize = Int(uint32BE(bytes, at: 20))
        let metaOffset = Int(uint32BE(bytes, at: 28))
        let metaLength = Int(uint32BE(bytes, at: 32))
        let metaOrigLength = Int64(uint32BE(bytes, at: 36))
        guard totalSFNTSize <= maximumFileBytes, metaOrigLength <= maximumFileBytes else {
            throw PreviewFontError.tooLarge
        }
        var cursor = woff2HeaderBytes
        var declaredTotal = Int64(sfntHeaderBytes + numTables * sfntTableEntryBytes)
        for _ in 0..<numTables {
            guard cursor < bytes.count else { throw PreviewFontError.unreadable }
            let flags = bytes[cursor]
            cursor += 1
            let tagIndex = flags & 0x3F
            let transformVersion = (flags >> 6) & 0x03
            if tagIndex == 63 {
                guard cursor + 4 <= bytes.count else { throw PreviewFontError.unreadable }
                cursor += 4
            }
            let origLength = try readBase128(bytes, cursor: &cursor)
            declaredTotal += (Int64(origLength) + 3) & ~3
            guard declaredTotal <= maximumFileBytes else { throw PreviewFontError.tooLarge }
            let transformed =
                (tagIndex == 10 || tagIndex == 11) ? (transformVersion == 0) : (transformVersion != 0)
            if transformed {
                let transformLength = try readBase128(bytes, cursor: &cursor)
                guard Int64(transformLength) <= maximumFileBytes else { throw PreviewFontError.tooLarge }
            }
        }
        if flavor == ttcTagValue {
            guard cursor + 4 <= bytes.count else { throw PreviewFontError.unreadable }
            cursor += 4
            let numFonts = try read255UInt16(bytes, cursor: &cursor)
            guard numFonts > 0 else { throw PreviewFontError.unreadable }
            guard numFonts <= maximumFaceCount else { throw PreviewFontError.tooManyFaces }
            for _ in 0..<numFonts {
                let fontTables = try read255UInt16(bytes, cursor: &cursor)
                guard cursor + 4 <= bytes.count else { throw PreviewFontError.unreadable }
                cursor += 4
                for _ in 0..<fontTables {
                    _ = try read255UInt16(bytes, cursor: &cursor)
                }
            }
        }
        guard totalCompressedSize >= 0, cursor + totalCompressedSize <= bytes.count else {
            throw PreviewFontError.unreadable
        }
        _ = try brotliDecodeBounded(
            Array(bytes[cursor..<(cursor + totalCompressedSize)]), limit: maximumFileBytes)
        if metaLength > 0, metaOffset >= woff2HeaderBytes, metaOffset + metaLength <= bytes.count {
            _ = try brotliDecodeBounded(
                Array(bytes[metaOffset..<(metaOffset + metaLength)]), limit: maximumFileBytes)
        }
    }

    private static func inflateBounded(_ compressed: [UInt8], limit: Int64) throws -> Int64 {
        guard limit >= 0 else { throw PreviewFontError.tooLarge }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PreviewFontError.unreadable
        }
        defer { inflateEnd(&stream) }
        var scratch = [UInt8](repeating: 0, count: scratchBytes)
        var total: Int64 = 0
        return try compressed.withUnsafeBufferPointer { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            stream.avail_in = uInt(source.count)
            while true {
                try Task.checkCancellation()
                let status: Int32 = scratch.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = Int64(scratchBytes) - Int64(stream.avail_out)
                total += produced
                if total > limit { throw PreviewFontError.tooLarge }
                if status == Z_STREAM_END { return total }
                if status != Z_OK { throw PreviewFontError.unreadable }
                if produced == 0, stream.avail_in == 0 { throw PreviewFontError.unreadable }
            }
        }
    }

    private static func brotliDecodeBounded(_ compressed: [UInt8], limit: Int64) throws -> Int64 {
        guard limit >= 0 else { throw PreviewFontError.tooLarge }
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(
            dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard
            compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
                != COMPRESSION_STATUS_ERROR
        else {
            throw PreviewFontError.unreadable
        }
        defer { compression_stream_destroy(&stream) }
        var scratch = [UInt8](repeating: 0, count: scratchBytes)
        var total: Int64 = 0
        return try compressed.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else { return 0 }
            stream.src_ptr = sourceBase
            stream.src_size = source.count
            while true {
                try Task.checkCancellation()
                let status: compression_status = scratch.withUnsafeMutableBufferPointer { destination in
                    guard let destinationBase = destination.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.dst_ptr = destinationBase
                    stream.dst_size = destination.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = Int64(scratchBytes) - Int64(stream.dst_size)
                total += produced
                if total > limit { throw PreviewFontError.tooLarge }
                switch status {
                case COMPRESSION_STATUS_END: return total
                case COMPRESSION_STATUS_OK:
                    if produced == 0, stream.src_size == 0 { throw PreviewFontError.unreadable }
                default: throw PreviewFontError.unreadable
                }
            }
        }
    }

    private static func readBase128(_ bytes: [UInt8], cursor: inout Int) throws -> UInt32 {
        var accumulator: UInt32 = 0
        for index in 0..<5 {
            guard cursor < bytes.count else { throw PreviewFontError.unreadable }
            let byte = bytes[cursor]
            cursor += 1
            if index == 0, byte == 0x80 { throw PreviewFontError.unreadable }
            if accumulator & 0xFE00_0000 != 0 { throw PreviewFontError.tooLarge }
            accumulator = (accumulator << 7) | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 { return accumulator }
        }
        throw PreviewFontError.unreadable
    }

    private static func read255UInt16(_ bytes: [UInt8], cursor: inout Int) throws -> Int {
        guard cursor < bytes.count else { throw PreviewFontError.unreadable }
        let code = bytes[cursor]
        cursor += 1
        switch code {
        case 253:
            guard cursor + 2 <= bytes.count else { throw PreviewFontError.unreadable }
            let value = Int(uint16BE(bytes, at: cursor))
            cursor += 2
            return value
        case 254:
            guard cursor < bytes.count else { throw PreviewFontError.unreadable }
            let value = Int(bytes[cursor]) + 253 * 2
            cursor += 1
            return value
        case 255:
            guard cursor < bytes.count else { throw PreviewFontError.unreadable }
            let value = Int(bytes[cursor]) + 253
            cursor += 1
            return value
        default:
            return Int(code)
        }
    }

    private static func uint16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func resolvedName(for font: CTFont, fallbackURL: URL) -> String {
        let display = CTFontCopyDisplayName(font) as String
        if !display.isEmpty { return display }
        let full = CTFontCopyFullName(font) as String
        if !full.isEmpty { return full }
        let postScript = CTFontCopyPostScriptName(font) as String
        if !postScript.isEmpty { return postScript }
        return fallbackURL.deletingPathExtension().lastPathComponent
    }
}
