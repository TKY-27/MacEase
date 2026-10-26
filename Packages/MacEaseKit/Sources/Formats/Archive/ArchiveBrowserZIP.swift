import CArchive
import Darwin
import Foundation

public struct ZIPBrowserEntry: Sendable {
    public let id: Int
    public let path: String
    public let isDirectory: Bool
    public let size: Int64?
    public let isEncrypted: Bool

    init(id: Int, path: String, isDirectory: Bool, size: Int64?, isEncrypted: Bool) {
        self.id = id
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.isEncrypted = isEncrypted
    }
}

public enum ZIPBrowserError: Error, Equatable, Sendable {
    case invalidZIP
    case tooManyEntries
    case namesTooLarge
    case pathTooDeep
    case unsafeEntry
    case unsupportedEntry
    case selectionTooLarge
    case passwordRequired
    case wrongPassword
    case corruptEntry
}

public enum ArchiveBrowserZIP {
    private static let blockSize = 64 * 1024
    private static let maximumPathDepth = 256
    public static let previewLimit: Int64 = 256 * 1024 * 1024

    public static func list(_ source: URL, check: () throws -> Void = {}) throws -> [ZIPBrowserEntry] {
        try ArchiveListing.inUTF8Locale {
            let reader = try Reader(source: source, check: check)
            var entries: [ZIPBrowserEntry] = []
            var nameBytes = 0
            var pointer: OpaquePointer?
            while true {
                try check()
                let status = archive_read_next_header(reader.archive, &pointer)
                if status == ARCHIVE_EOF { break }
                guard status == ARCHIVE_OK, let pointer else { throw ZIPBrowserError.invalidZIP }
                guard entries.count < ZIPDirectoryBounds.maximumEntries else { throw ZIPBrowserError.tooManyEntries }
                let path = try checkedPath(pointer)
                let bytes = path.utf8.count
                guard bytes <= ZIPDirectoryBounds.maximumMetadataBytes - nameBytes else {
                    throw ZIPBrowserError.namesTooLarge
                }
                nameBytes += bytes
                let type = archive_entry_filetype(pointer)
                guard type == UInt32(S_IFREG) || type == UInt32(S_IFDIR),
                    archive_entry_symlink(pointer) == nil,
                    archive_entry_hardlink(pointer) == nil
                else { throw ZIPBrowserError.unsupportedEntry }
                let size = archive_entry_size_is_set(pointer) != 0 ? archive_entry_size(pointer) : nil
                guard size.map({ $0 >= 0 }) ?? true else { throw ZIPBrowserError.invalidZIP }
                entries.append(
                    ZIPBrowserEntry(
                        id: entries.count, path: path, isDirectory: type == UInt32(S_IFDIR),
                        size: size, isEncrypted: archive_entry_is_encrypted(pointer) != 0))
            }
            guard entries.count == reader.expectedEntries,
                archive_format(reader.archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP
            else {
                throw ZIPBrowserError.invalidZIP
            }
            return entries
        }
    }

    public static func extract(
        _ source: URL, ordinal: Int, to destination: URL, password: String?, limit: Int64,
        preserveAttributes: Bool = false, check: () throws -> Void = {}
    ) throws {
        try extract(
            source, selections: [ordinal: destination], password: password, limit: limit,
            preserveAttributes: preserveAttributes, check: check)
    }

    public static func extract(
        _ source: URL, selections: [Int: URL], password: String?, limit: Int64,
        preserveAttributes: Bool = false, check: () throws -> Void = {}
    ) throws {
        guard limit >= 0 else { throw ZIPBrowserError.selectionTooLarge }
        try ArchiveListing.inUTF8Locale {
            let reader = try Reader(source: source, password: password, check: check)
            var pointer: OpaquePointer?
            var index = 0
            var found = 0
            var total: Int64 = 0
            while true {
                try check()
                let status = archive_read_next_header(reader.archive, &pointer)
                if status == ARCHIVE_EOF { break }
                guard status == ARCHIVE_OK, let pointer else { throw ZIPBrowserError.invalidZIP }
                if let destination = selections[index] {
                    guard archive_entry_filetype(pointer) == UInt32(S_IFREG),
                        archive_entry_symlink(pointer) == nil,
                        archive_entry_hardlink(pointer) == nil
                    else { throw ZIPBrowserError.unsupportedEntry }
                    _ = try checkedPath(pointer)
                    let declared = archive_entry_size_is_set(pointer) != 0 ? archive_entry_size(pointer) : 0
                    guard declared >= 0, declared <= limit - total else { throw ZIPBrowserError.selectionTooLarge }
                    guard password != nil || archive_entry_is_encrypted(pointer) == 0 else {
                        throw ZIPBrowserError.passwordRequired
                    }
                    let extent = try write(
                        reader.archive, entry: pointer, to: destination, limit: limit - total,
                        encrypted: archive_entry_is_encrypted(pointer) != 0,
                        preserveAttributes: preserveAttributes, check: check)
                    guard declared == extent else { throw ZIPBrowserError.corruptEntry }
                    total += extent
                    found += 1
                }
                index += 1
            }
            guard found == selections.count, index == reader.expectedEntries else {
                throw ZIPBrowserError.invalidZIP
            }
        }
    }

    private static func write(
        _ archive: OpaquePointer, entry: OpaquePointer, to destination: URL, limit: Int64,
        encrypted: Bool, preserveAttributes: Bool, check: () throws -> Void
    ) throws -> Int64 {
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: la_int64_t = 0
        var extent: Int64 = 0
        while true {
            try check()
            let status = archive_read_data_block(archive, &buffer, &size, &offset)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK else {
                throw encrypted ? ZIPBrowserError.wrongPassword : ZIPBrowserError.corruptEntry
            }
            guard offset >= 0, size >= 0 else { throw ZIPBrowserError.corruptEntry }
            if size == 0 { continue }
            guard let buffer else { throw ZIPBrowserError.corruptEntry }
            let (end, overflow) = offset.addingReportingOverflow(Int64(size))
            guard !overflow, end <= limit else { throw ZIPBrowserError.selectionTooLarge }
            extent = max(extent, end)
            var written = 0
            while written < size {
                try check()
                let count = pwrite(fd, buffer.advanced(by: written), size - written, offset + Int64(written))
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        guard ftruncate(fd, extent) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if preserveAttributes {
            let permissions = mode_t(archive_entry_perm(entry)) & 0o777
            guard fchmod(fd, permissions) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if archive_entry_mtime_is_set(entry) != 0 {
                var times = [
                    timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                    timespec(tv_sec: archive_entry_mtime(entry), tv_nsec: archive_entry_mtime_nsec(entry)),
                ]
                guard futimens(fd, &times) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return extent
    }

    private static func checkedPath(_ entry: OpaquePointer) throws -> String {
        guard let raw = archive_entry_pathname_utf8(entry) else { throw ZIPBrowserError.unsafeEntry }
        let pathname = String(cString: raw)
        guard !pathname.hasPrefix("/"), !pathname.contains("\\"), !pathname.contains(":") else {
            throw ZIPBrowserError.unsafeEntry
        }
        let parts = pathname.split(separator: "/", omittingEmptySubsequences: false)
        let meaningful = parts.last == "" ? parts.dropLast() : parts[...]
        guard !meaningful.isEmpty, meaningful.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ZIPBrowserError.unsafeEntry
        }
        guard meaningful.count <= maximumPathDepth else { throw ZIPBrowserError.pathTooDeep }
        return meaningful.joined(separator: "/")
    }

    private final class Reader {
        let archive: OpaquePointer
        let descriptor: Int32
        let expectedEntries: Int

        init(source: URL, password: String? = nil, check: () throws -> Void) throws {
            let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw ZIPBrowserError.invalidZIP }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                close(descriptor)
                throw ZIPBrowserError.invalidZIP
            }
            let expectedEntries: Int
            do {
                expectedEntries = try ZIPDirectoryBounds.validate(
                    descriptor: descriptor, size: metadata.st_size, check: check)
            } catch {
                close(descriptor)
                throw error
            }
            guard let archive = archive_read_new() else {
                close(descriptor)
                throw ZIPBrowserError.invalidZIP
            }
            guard archive_read_support_filter_none(archive) == ARCHIVE_OK,
                archive_read_support_format_zip_seekable(archive) == ARCHIVE_OK
            else {
                archive_read_free(archive)
                close(descriptor)
                throw ZIPBrowserError.invalidZIP
            }
            guard archive_read_set_option(archive, "zip", "mac-ext", nil) == ARCHIVE_OK else {
                archive_read_free(archive)
                close(descriptor)
                throw ZIPBrowserError.invalidZIP
            }
            if let password { archive_read_add_passphrase(archive, password) }
            guard archive_read_open_fd(archive, descriptor, blockSize) == ARCHIVE_OK else {
                archive_read_free(archive)
                close(descriptor)
                throw ZIPBrowserError.invalidZIP
            }
            self.archive = archive
            self.descriptor = descriptor
            self.expectedEntries = expectedEntries
        }

        deinit {
            archive_read_free(archive)
            close(descriptor)
        }
    }
}
