import CArchive
import CDeflate
import Darwin
import Foundation

public struct ArchiveNameInspection: Sendable {
    public static let maximumDuration: Duration = .seconds(10)
    private static let maximumPathDepth = 256
    private static let maximumLinkBytes = 64 * 1024
    private static let supportedZIPMethods: Set<UInt16> = [0, 8, 12, 14, 93, 95, 98]

    public let source: URL
    private var nameBytes = 0
    private var containsZIPLinks = false
    private var uninspectableZIPLinks = false
    public let prefersJapanese: Bool
    private let bounded: Bool
    private var hasLegacyNames = false
    private var allLegacyNamesAreCP932 = true
    public var needsLegacyDecoder: Bool { hasLegacyNames && prefersJapanese && allLegacyNamesAreCP932 }
    private var zipEncoding: ArchivePathname.LegacyEncoding {
        prefersJapanese && allLegacyNamesAreCP932 ? .cp932 : .cp437
    }
    public private(set) var unsupportedNativeFeature: ArchiveExtractionFeature?
    public private(set) var isSplit = false

    public static func inspect(
        _ location: URL, password: String? = nil,
        prefersJapanese: Bool = ArchivePathname.prefersJapanese(in: Locale.preferredLanguages),
        check: () throws -> Void = {}
    ) throws -> Self {
        let deadline = ContinuousClock.now + maximumDuration
        return try withoutActuallyEscaping(check) { check in
            let check = {
                try check()
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ArchiveError.nameInspectionLimit }
            }
            let urls = try volumes(location, check: check)
            let source = try ArchiveReadSource(urls, check: check)
            let prefix = try source.read(at: 0, count: min(512, Int(source.size)), check: check)
            var result = Self(source: location.standardizedFileURL, prefersJapanese: prefersJapanese, bounded: true)
            result.isSplit = urls.count > 1 || Int(location.pathExtension) != nil
            // 7z validates its UTF-16 names strictly.
            if prefix.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return result }
            let compressed = prefix.starts(with: [0x1F, 0x8B])
            let tar = prefix.count >= 263 && Array(prefix[257..<262]) == Array("ustar".utf8)
            let namedTAR = location.path.lowercased().contains(".tar")
            let signature =
                prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) || prefix.starts(with: [0x50, 0x4B, 0x05, 0x06])
            if !signature && (compressed || tar || namedTAR) {
                try result.inspectTAR(source, compressed: compressed, check: check)
            } else {
                let zip = signature ? true : try containsZIPEnd(source, check: check)
                guard zip else { return result }
                do {
                    let directory = try ZIPDirectoryBounds.validate(
                        source: source,
                        inspect: { header, fields in
                            try result.inspectZIP(header, fields: fields)
                        }, check: check)
                    if result.containsZIPLinks, !result.uninspectableZIPLinks {
                        try result.inspectZIPLinks(
                            source, endingAt: directory.endOffset + 22, password: password, check: check)
                    }
                } catch ZIPBrowserError.tooManyEntries, ZIPBrowserError.namesTooLarge {
                    throw ArchiveError.nameInspectionLimit
                } catch ZIPBrowserError.unsafeEntry {
                    throw ArchiveError.unsafePath("ZIP filename contains NUL")
                } catch is ZIPBrowserError {
                    throw FormatError.corrupt("invalid ZIP directory")
                }
            }
            if result.needsLegacyDecoder, result.isSplit { result.unsupportedNativeFeature = .splitVolumes }
            return result
        }
    }

    static func zipEncoding(
        _ source: ArchiveReadSource, location: URL, prefersJapanese: Bool, check: () throws -> Void
    ) throws -> ArchivePathname.LegacyEncoding {
        guard prefersJapanese else { return .cp437 }
        var result = Self(source: location, prefersJapanese: prefersJapanese, bounded: false)
        let directory = try ZIPDirectoryBounds.validate(
            source: source, bounded: false,
            inspect: { header, fields in try result.inspectZIP(header, fields: fields) }, check: check)
        if result.containsZIPLinks, !result.uninspectableZIPLinks {
            try result.inspectZIPLinks(source, endingAt: directory.endOffset + 22, password: nil, check: check)
        }
        return result.zipEncoding
    }

    private static func volumes(_ location: URL, check: () throws -> Void) throws -> [URL] {
        let suffix = location.pathExtension
        guard suffix.count >= 3, suffix.allSatisfy(\.isNumber) else { return [location] }
        let base = location.deletingPathExtension()
        var urls: [URL] = []
        for number in 1...ArchiveReadSource.maximumParts {
            try check()
            let volume = base.appendingPathExtension(String(format: "%0*d", suffix.count, number))
            guard FileManager.default.fileExists(atPath: volume.path) else { break }
            urls.append(volume)
        }
        guard !urls.isEmpty, urls.count < ArchiveReadSource.maximumParts else { throw ArchiveError.nameInspectionLimit }
        return urls
    }

    private static func containsZIPEnd(_ source: ArchiveReadSource, check: () throws -> Void) throws -> Bool {
        let count = Int(min(source.size, Int64(22 + Int(UInt16.max))))
        guard count >= 22 else { return false }
        let bytes = try source.read(at: source.size - Int64(count), count: count, check: check)
        return stride(from: count - 22, through: 0, by: -1).contains {
            UInt32(littleEndian: bytes, at: $0) == 0x06054b50
        }
    }

    private mutating func inspectZIP(_ header: [UInt8], fields: [UInt8]) throws {
        let nameCount = Int(UInt16(littleEndian: header, at: 28))
        let extraCount = Int(UInt16(littleEndian: header, at: 30))
        let mode = UInt32(littleEndian: header, at: 38) >> 16
        let raw = Array(fields.prefix(nameCount))
        let extras = Array(fields[nameCount..<(nameCount + extraCount)])
        var selected = raw
        var method = UInt16(littleEndian: header, at: 10)
        var offset = 0
        while offset + 4 <= extras.count {
            let length = Int(UInt16(littleEndian: extras, at: offset + 2))
            let end = offset + 4 + length
            guard end <= extras.count else { throw ZIPBrowserError.invalidZIP }
            let kind = UInt16(littleEndian: extras, at: offset)
            if kind == 0x7075, length >= 5, extras[offset + 4] == 1 {
                let crc = raw.withUnsafeBytes { libdeflate_crc32(0, $0.baseAddress, $0.count) }
                if UInt32(littleEndian: extras, at: offset + 5) == crc {
                    selected = Array(extras[(offset + 9)..<end])
                }
            }
            if kind == 0x9901, length == 7, method == 99 {
                method = UInt16(littleEndian: extras, at: offset + 9)
            }
            offset = end
        }
        let pathname = try inspectName(selected, zip: true)
        if mode & UInt32(S_IFMT) == UInt32(S_IFLNK) {
            guard UInt32(littleEndian: header, at: 24) <= Self.maximumLinkBytes else {
                throw ArchiveError.nameInspectionLimit
            }
            if UInt16(littleEndian: header, at: 8) & 1 != 0 {
                uninspectableZIPLinks = true
                unsupportedNativeFeature = .zipEncryptedLinks
            } else if ![0, 8, 14].contains(method) {
                uninspectableZIPLinks = true
                unsupportedNativeFeature = .zipLinkCompression(method)
            } else {
                containsZIPLinks = true
            }
        }
        if pathname.contains("\\") { unsupportedNativeFeature = .zipBackslashSeparators }
        if !Self.supportedZIPMethods.contains(method) { unsupportedNativeFeature = .zipCompression(method) }
        if UInt16(littleEndian: header, at: 8) & 0x40 != 0 { unsupportedNativeFeature = .zipStrongEncryption }
    }

    private mutating func inspectZIPLinks(
        _ source: ArchiveReadSource, endingAt end: Int64, password: String?, check: () throws -> Void
    ) throws {
        try ArchiveListing.inUTF8Locale {
            guard let archive = archive_read_new() else { throw FormatError.io("ZIP link inspection allocation") }
            defer { _ = withExtendedLifetime(source) { archive_read_free(archive) } }
            try ArchiveReadSupport.enableFilters(archive, compressed: false)
            guard archive_read_support_format_zip_seekable(archive) == ARCHIVE_OK,
                archive_read_set_option(archive, "zip", "mac-ext", nil) == ARCHIVE_OK
            else { throw FormatError.unsupported("ZIP link inspection") }
            if let password { archive_read_add_passphrase(archive, password) }
            try source.open(archive, endingAt: end)
            var entry: OpaquePointer?
            while true {
                try check()
                let status = archive_read_next_header(archive, &entry)
                if let failure = source.failure { throw failure }
                if status == ARCHIVE_EOF { break }
                guard status >= ARCHIVE_WARN, let entry else {
                    if archive_read_has_encrypted_entries(archive) > 0 {
                        throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
                    }
                    throw FormatError.corrupt(ArchiveListing.message(archive))
                }
                for pointer in [
                    archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry),
                    archive_entry_hardlink_utf8(entry) ?? archive_entry_hardlink(entry),
                ] {
                    guard let pointer else { continue }
                    let bytes = UnsafeBufferPointer(start: pointer, count: strlen(pointer)).map {
                        UInt8(bitPattern: $0)
                    }
                    try inspectName(bytes, zip: true)
                }
            }
        }
    }

    @discardableResult
    private mutating func inspectName(_ bytes: [UInt8], zip: Bool) throws -> String {
        guard !bytes.contains(0) else { throw ArchiveError.unsafePath("archive filename contains NUL") }
        let pathname: String
        if let utf8 = String(bytes: bytes, encoding: .utf8) {
            pathname = utf8
        } else {
            hasLegacyNames = true
            if prefersJapanese {
                do {
                    pathname = try ArchivePathname.decode(bytes, encoding: .cp932)
                } catch ArchiveError.unsupportedNameEncoding {
                    guard zip else { throw ArchiveError.unsupportedNameEncoding }
                    allLegacyNamesAreCP932 = false
                    pathname = try ArchivePathname.decode(bytes, encoding: .cp437)
                }
            } else {
                guard zip else { throw ArchiveError.unsupportedNameEncoding }
                allLegacyNamesAreCP932 = false
                pathname = try ArchivePathname.decode(bytes, encoding: .cp437)
            }
        }
        guard !bounded || pathname.split(separator: "/").count <= Self.maximumPathDepth else {
            throw ArchiveError.nameInspectionLimit
        }
        guard !bounded || pathname.utf8.count <= ZIPDirectoryBounds.maximumMetadataBytes - nameBytes else {
            throw ArchiveError.nameInspectionLimit
        }
        nameBytes += pathname.utf8.count
        return pathname
    }

    private mutating func inspectTAR(_ source: ArchiveReadSource, compressed: Bool, check: () throws -> Void) throws {
        try ArchiveListing.inUTF8Locale {
            guard let archive = archive_read_new() else { throw FormatError.io("archive inspection allocation") }
            defer { _ = withExtendedLifetime(source) { archive_read_free(archive) } }
            try ArchiveReadSupport.enableFilters(archive, compressed: false)
            if compressed { try ArchiveReadSupport.enableGzip(archive) }
            guard archive_read_support_format_tar(archive) == ARCHIVE_OK,
                archive_read_support_format_zip_streamable(archive) == ARCHIVE_OK
            else {
                throw FormatError.unsupported("TAR inspection")
            }
            source.streamBlockSize = compressed ? 4 * 1024 : 512
            try source.open(archive)
            guard archive_filter_count(archive) <= (compressed ? 2 : 1) else { throw ArchiveError.nameInspectionLimit }
            var entry: OpaquePointer?
            var count = 0
            var skipped: Int64 = 0
            let maximumSkippedBytes = ExtractionLimits.standard.limit(forArchiveBytes: source.size)
            while true {
                try check()
                let status = archive_read_next_header(archive, &entry)
                if let failure = source.failure { throw failure }
                if status == ARCHIVE_EOF { break }
                guard status >= ARCHIVE_WARN, let entry else {
                    throw FormatError.corrupt(ArchiveListing.message(archive))
                }
                if archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP {
                    throw ArchiveError.wrappedZIPContainer
                }
                count += 1
                guard count <= ZIPDirectoryBounds.maximumEntries else { throw ArchiveError.nameInspectionLimit }
                guard let pathname = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry) else {
                    throw ArchiveError.unsupportedNameEncoding
                }
                for pointer in [
                    pathname, archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry),
                    archive_entry_hardlink_utf8(entry) ?? archive_entry_hardlink(entry),
                ] {
                    guard let pointer else { continue }
                    let bytes = UnsafeBufferPointer(start: pointer, count: strlen(pointer)).map {
                        UInt8(bitPattern: $0)
                    }
                    try inspectName(bytes, zip: false)
                }
                if compressed {
                    guard archive_entry_size_is_set(entry) != 0, archive_entry_size(entry) >= 0,
                        archive_entry_size(entry) <= maximumSkippedBytes - skipped
                    else { throw ArchiveError.nameInspectionLimit }
                    skipped += archive_entry_size(entry)
                }
            }
        }
    }
}
