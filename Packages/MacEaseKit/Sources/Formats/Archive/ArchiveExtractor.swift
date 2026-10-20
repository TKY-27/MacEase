import CArchive
import Darwin
import Foundation

public enum ArchiveError: Error, Equatable, Sendable {
    case passwordRequired
    case wrongPassword
    case unsafePath(String)
    case expandsTooMuch(limitBytes: Int64)
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

    func limit(forArchiveBytes size: Int64) -> Int64 {
        max(allowanceBytes, size.multipliedReportingOverflow(by: maximumExpansionRatio).partialValue)
    }
}

public enum ExtractedLayout: Sendable {
    case entries
    /// A lone gz, bz2 or xz stream.
    case decompressedFile
}

public enum ArchiveExtractor {
    private static let blockSize = 64 * 1024
    private static let macMetadataFolder = "__MACOSX"
    // Absolute prefixes exclude NOABSOLUTEPATHS; see `checked`.
    private static let diskFlags =
        ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_NODOTDOT
        | ARCHIVE_EXTRACT_SECURE_SYMLINKS

    private final class Reader {
        let archive: OpaquePointer
        let disk: OpaquePointer

        init() throws {
            guard let archive = archive_read_new(), let disk = archive_write_disk_new() else {
                throw FormatError.io("libarchive allocation")
            }
            self.archive = archive
            self.disk = disk
        }

        deinit {
            archive_read_free(archive)
            archive_write_free(disk)
        }
    }

    /// `directory` must be symlink-free.
    public static func extract(
        _ source: URL,
        into directory: URL,
        rawName: String,
        password: String?,
        limits: ExtractionLimits = .standard,
        progress: (Double) -> Void
    ) throws -> ExtractedLayout {
        guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw FormatError.io("archive size")
        }
        let archiveBytes = Int64(size)
        let limit = limits.limit(forArchiveBytes: archiveBytes)
        return try ArchiveListing.inUTF8Locale {
            let reader = try Reader()
            archive_read_support_filter_all(reader.archive)
            archive_read_support_format_all(reader.archive)
            archive_read_support_format_raw(reader.archive)
            if let password { archive_read_add_passphrase(reader.archive, password) }
            archive_write_disk_set_options(reader.disk, Int32(diskFlags))
            guard archive_read_open_filename(reader.archive, source.path, blockSize) == ARCHIVE_OK else {
                throw failure(reader.archive, entry: nil, password: password)
            }
            var written: Int64 = 0
            var entry: OpaquePointer?
            while true {
                try Task.checkCancellation()
                let status = archive_read_next_header(reader.archive, &entry)
                if status == ARCHIVE_EOF { break }
                guard status >= ARCHIVE_WARN, let entry else {
                    throw failure(reader.archive, entry: nil, password: password)
                }
                guard let name = try destinationName(of: entry, in: reader.archive, rawName: rawName) else {
                    continue
                }
                archive_entry_set_pathname_utf8(entry, directory.path + "/" + name)
                if let link = archive_entry_hardlink_utf8(entry).map({ String(cString: $0) }) {
                    archive_entry_set_hardlink_utf8(entry, directory.path + "/" + (try checked(link)))
                }
                if archive_entry_is_encrypted(entry) != 0 { try requireDecryption(reader.archive, password: password) }
                guard archive_write_header(reader.disk, entry) >= ARCHIVE_WARN else {
                    throw FormatError.corrupt(ArchiveListing.message(reader.disk))
                }
                try copyData(reader, entry: entry, password: password) { bytes in
                    written += Int64(bytes)
                    guard written <= limit else { throw ArchiveError.expandsTooMuch(limitBytes: limit) }
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
        rawName: String
    ) throws -> String? {
        if archive_format(archive) == ARCHIVE_FORMAT_RAW {
            // Raw without a filter is garbage.
            guard archive_filter_count(archive) > 1 else { throw FormatError.corrupt("not an archive") }
            return rawName
        }
        guard let pathname = archive_entry_pathname_utf8(entry).map({ String(cString: $0) }) else {
            throw FormatError.corrupt("entry name is not UTF-8")
        }
        let name = try checked(pathname)
        guard !name.isEmpty, name.split(separator: "/").first != Substring(macMetadataFolder) else { return nil }
        return name
    }

    private static func checked(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !components.contains("..") else { throw ArchiveError.unsafePath(path) }
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

    private static func copyData(
        _ reader: Reader,
        entry: OpaquePointer,
        password: String?,
        wrote: (Int) throws -> Void
    ) throws {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: la_int64_t = 0
        while true {
            try Task.checkCancellation()
            let status = archive_read_data_block(reader.archive, &buffer, &size, &offset)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN else { throw failure(reader.archive, entry: entry, password: password) }
            try wrote(size)
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
