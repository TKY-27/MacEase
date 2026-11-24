import CArchive
import Darwin
import Foundation

public enum ArchiveExtractionFeature: Equatable, Sendable {
    case splitVolumes
    case zipCompression(UInt16)
    case zipStrongEncryption
    case zipBackslashSeparators
    case zipEncryptedLinks
    case zipLinkCompression(UInt16)
}

public enum ArchiveError: Error, Equatable, Sendable {
    case passwordRequired
    case wrongPassword
    case unsafePath(String)
    case expandsTooMuch(limitBytes: Int64)
    case duplicateRootName(String)
    case unsupportedNameEncoding
    case nameInspectionLimit(ArchiveInspectionLimit)
    case nameCollision(first: String, second: String)
    case wrappedZIPContainer
    case legacyNameFeatureUnsupported(ArchiveExtractionFeature)
}

/// Caps extracted bytes against zip bombs.
public struct ExtractionLimits: Sendable {
    public var maximumExpansionRatio: Int64
    public var allowanceBytes: Int64

    public init(maximumExpansionRatio: Int64, allowanceBytes: Int64) {
        self.maximumExpansionRatio = maximumExpansionRatio
        self.allowanceBytes = allowanceBytes
    }

    // DEFLATE peaks near 1032:1.
    public static let standard = ExtractionLimits(maximumExpansionRatio: 1_000, allowanceBytes: 1 << 30)

    public func limit(forArchiveBytes size: Int64) -> Int64 {
        let (expanded, overflow) = size.multipliedReportingOverflow(by: maximumExpansionRatio)
        return overflow ? Int64.max : max(allowanceBytes, expanded)
    }
}

public enum ExtractedLayout: Sendable {
    case entries
    /// A lone gz, bz2 or xz stream.
    case decompressedFile
}

public enum ArchiveExtractor {
    private static let macMetadataFolder = "__MACOSX"
    // Absolute prefixes exclude NOABSOLUTEPATHS; see `checked`.
    private static let diskFlags =
        ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_NODOTDOT
        | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_NO_OVERWRITE

    private final class Reader {
        let archive: OpaquePointer
        let disk: OpaquePointer
        let source: ArchiveReadSource
        let zip: ArchiveZIPReader?

        init(source location: URL, password: String?, prefersJapanese: Bool) throws {
            let source = try ArchiveReadSource([location])
            let zip: ArchiveZIPReader?
            let archive: OpaquePointer
            if try ArchiveZIPReader.recognizes(source) {
                do {
                    zip = try ArchiveZIPReader(
                        source: source, password: password, prefersJapanese: prefersJapanese, bounded: false)
                } catch { throw ArchiveZIPReader.archiveError(error) }
                guard let zip else { throw FormatError.io("ZIP reader unavailable") }
                archive = zip.archive
            } else {
                zip = nil
                guard let allocated = archive_read_new() else { throw FormatError.io("libarchive allocation") }
                archive = allocated
                do {
                    try ArchiveReadSupport.enableFilters(archive)
                    try ArchiveReadSupport.enableFormats(archive)
                    guard archive_read_support_format_raw(archive) == ARCHIVE_OK else {
                        throw FormatError.unsupported(ArchiveListing.message(archive))
                    }
                    if let password { archive_read_add_passphrase(archive, password) }
                    try source.open(archive)
                } catch { archive_read_free(archive); throw error }
            }
            guard let disk = archive_write_disk_new() else {
                if zip == nil { archive_read_free(archive) }
                throw FormatError.io("libarchive disk allocation")
            }
            self.source = source
            self.zip = zip
            self.archive = archive
            self.disk = disk
        }

        deinit {
            if zip == nil { _ = withExtendedLifetime(source) { archive_read_free(archive) } }
            archive_write_free(disk)
        }
    }

    /// `directory` must be symlink-free.
    public static func extract(
        _ source: URL,
        into directory: URL,
        rawName: String,
        password: String?,
        prefersJapanese: Bool = ArchivePathname.prefersJapanese(in: Locale.preferredLanguages),
        limits: ExtractionLimits = .standard,
        progress: (Double) -> Void
    ) throws -> ExtractedLayout {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        return try ArchiveListing.inUTF8Locale {
            let reader = try Reader(source: source, password: password, prefersJapanese: prefersJapanese)
            let archiveBytes = reader.source.size
            let limit = limits.limit(forArchiveBytes: archiveBytes)
            archive_write_disk_set_options(reader.disk, Int32(diskFlags))
            if let zip = reader.zip {
                let names = try zip.directory.members.map { member in
                    (
                        path: try ArchivePathname.decode(member.name, encoding: zip.encoding),
                        directory: member.isDirectory
                    )
                }
                try ArchivePathCollisionCheck.verify(names, beside: directory)
            }
            let collisions = ArchivePathCollisionCheck(root: directory)
            var ordinal = 0
            var logicalBytes: Int64 = 0
            var entry: OpaquePointer?
            let encoding: ArchivePathname.LegacyEncoding =
                reader.zip?.encoding ?? (prefersJapanese ? .cp932 : .utf8Only)
            while true {
                try Task.checkCancellation()
                if let zip = reader.zip {
                    entry = try zip.next()
                    if entry == nil { break }
                } else {
                    let status = archive_read_next_header(reader.archive, &entry)
                    if let failure = reader.source.failure { throw failure }
                    if status == ARCHIVE_EOF { break }
                    guard status >= ARCHIVE_WARN else {
                        throw failure(reader.archive, entry: entry, password: password)
                    }
                    if isZip(reader.archive) { throw ArchiveError.wrappedZIPContainer }
                }
                guard let entry else { throw FormatError.corrupt("archive entry unavailable") }
                ordinal += 1
                guard
                    let name = try destinationName(of: entry, in: reader.archive, rawName: rawName, encoding: encoding)
                else {
                    continue
                }
                try collisions.check(
                    name, directory: archive_entry_filetype(entry) == UInt32(S_IFDIR), ordinal: ordinal)
                archive_entry_set_pathname_utf8(entry, directory.path + "/" + name)
                if let link = try ArchivePathname.hardlink(entry, encoding: encoding) {
                    archive_entry_set_hardlink_utf8(entry, directory.path + "/" + (try checked(link)))
                }
                if let link = try ArchivePathname.symlink(entry, encoding: encoding) {
                    archive_entry_set_symlink_utf8(entry, link)
                }
                if archive_entry_is_encrypted(entry) != 0 { try requireDecryption(reader.archive, password: password) }
                let declaredSize = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : 0
                guard declaredSize >= 0 else { throw FormatError.corrupt("negative archive entry size") }
                var memberBytes: Int64 = 0
                try charge(declaredSize, from: &memberBytes, total: &logicalBytes, limit: limit)
                try copyData(
                    reader, entry: entry, password: password, didWriteHeader: { try collisions.didWrite(name) }
                ) { bytes, offset in
                    guard offset >= 0 else { throw FormatError.corrupt("negative archive data offset") }
                    let (end, overflow) = offset.addingReportingOverflow(Int64(bytes))
                    guard !overflow else { throw ArchiveError.expandsTooMuch(limitBytes: limit) }
                    try charge(end, from: &memberBytes, total: &logicalBytes, limit: limit)
                    let read = archive_filter_bytes(reader.archive, -1)
                    progress(Double(read) / Double(max(1, archiveBytes)))
                }
            }
            guard archive_write_close(reader.disk) == ARCHIVE_OK else {
                throw FormatError.corrupt(ArchiveListing.message(reader.disk))
            }
            return archive_format(reader.archive) == ARCHIVE_FORMAT_RAW ? .decompressedFile : .entries
        }
    }

    /// `nil` skips the entry.
    private static func destinationName(
        of entry: OpaquePointer,
        in archive: OpaquePointer,
        rawName: String,
        encoding: ArchivePathname.LegacyEncoding
    ) throws -> String? {
        if archive_format(archive) == ARCHIVE_FORMAT_RAW {
            // Raw without a filter is garbage.
            guard archive_filter_count(archive) > 1 else { throw FormatError.unsupportedArchive }
            return rawName
        }
        let pathname = try ArchivePathname.decode(entry, encoding: encoding)
        let name = try checked(pathname)
        guard !name.isEmpty, name.split(separator: "/").first != Substring(macMetadataFolder) else { return nil }
        return name
    }

    static func checked(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.utf8.contains(0), !components.contains("..") else {
            throw ArchiveError.unsafePath(path)
        }
        return components.filter { $0 != "." }.joined(separator: "/")
    }

    private static func requireDecryption(_ archive: OpaquePointer, password: String?) throws {
        if password == nil || !isZip(archive) { throw encryptionError(archive, password: password) }
    }

    /// libarchive decrypts ZIP entries only.
    private static func encryptionError(_ archive: OpaquePointer, password: String?) -> any Error {
        guard isZip(archive) else {
            let format = archive_format_name(archive).map { String(cString: $0) } ?? "archive"
            return FormatError.unsupported("encrypted \(format)")
        }
        return password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
    }

    private static func isZip(_ archive: OpaquePointer) -> Bool {
        archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP
    }

    private static func charge(_ size: Int64, from member: inout Int64, total: inout Int64, limit: Int64)
        throws
    {
        guard size > member else { return }
        let increase = size - member
        guard increase <= limit - total else { throw ArchiveError.expandsTooMuch(limitBytes: limit) }
        member = size
        total += increase
    }

    private static func copyData(
        _ reader: Reader,
        entry: OpaquePointer,
        password: String?,
        didWriteHeader: () throws -> Void,
        wrote: (Int, Int64) throws -> Void
    ) throws {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: la_int64_t = 0
        var headerWritten = false
        while true {
            try Task.checkCancellation()
            let status = archive_read_data_block(reader.archive, &buffer, &size, &offset)
            guard status >= ARCHIVE_WARN else { throw failure(reader.archive, entry: entry, password: password) }
            if !headerWritten {
                if archive_format(reader.archive) == ARCHIVE_FORMAT_RAW {
                    try ArchiveReadSupport.checkRawPrefix(UnsafeRawBufferPointer(start: buffer, count: size))
                }
                let options =
                    archive_entry_filetype(entry) == UInt32(S_IFDIR)
                    ? diskFlags & ~ARCHIVE_EXTRACT_NO_OVERWRITE : diskFlags
                archive_write_disk_set_options(reader.disk, Int32(options))
                guard archive_write_header(reader.disk, entry) >= ARCHIVE_WARN else {
                    throw FormatError.corrupt(ArchiveListing.message(reader.disk))
                }
                try didWriteHeader()
                headerWritten = true
            }
            if status == ARCHIVE_EOF { break }
            try wrote(size, offset)
            guard archive_write_data_block(reader.disk, buffer, size, offset) >= ARCHIVE_WARN else {
                throw FormatError.corrupt(ArchiveListing.message(reader.disk))
            }
        }
        guard archive_write_finish_entry(reader.disk) >= ARCHIVE_WARN else {
            throw FormatError.corrupt(ArchiveListing.message(reader.disk))
        }
    }

    private static func failure(_ archive: OpaquePointer, entry: OpaquePointer?, password: String?) -> any Error {
        let encrypted = entry.map { archive_entry_is_encrypted($0) != 0 } ?? false
        guard encrypted || archive_read_has_encrypted_entries(archive) > 0 else {
            return FormatError.corrupt(ArchiveListing.message(archive))
        }
        return encryptionError(archive, password: password)
    }
}
