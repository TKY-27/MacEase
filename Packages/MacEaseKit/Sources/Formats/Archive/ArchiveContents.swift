import CArchive
import Darwin
import Foundation

/// Lists headers; never writes entry data.
public struct ArchiveContents: Sendable {
    public struct Entry: Sendable {
        public let path: String
        public let isDirectory: Bool
        public let size: Int64?
        public let modified: Date?
        public let isEncrypted: Bool
    }

    public enum Ending: Equatable, Sendable {
        case complete, entryLimit, nameLimit, timeLimit, damaged
    }

    public enum Failure: Error, Equatable, Sendable {
        case unsupported, damaged, passwordProtected, tooLarge
    }

    public static let maximumEntries = ZIPDirectoryBounds.maximumEntries
    public static let maximumNameBytes = ZIPDirectoryBounds.maximumMetadataBytes
    public static let maximumPathDepth = 256
    public static let maximumDuration: Duration = .seconds(10)
    private static let blockSize = 64 * 1024
    private static let zipSignature: [UInt8] = [0x50, 0x4B]

    public let entries: [Entry]
    public let ending: Ending

    public static func list(
        _ source: URL, maximumDuration: Duration = maximumDuration, check: () throws -> Void = {}
    ) throws -> Self {
        let deadline = ContinuousClock.now + maximumDuration
        return try withoutActuallyEscaping(check) { check in
            try ArchiveListing.inUTF8Locale {
                if try startsWithZIPSignature(source) {
                    let reader: ArchiveBrowserZIP.Reader
                    do {
                        reader = try ArchiveBrowserZIP.Reader(source: source, check: check)
                    } catch ZIPBrowserError.tooManyEntries, ZIPBrowserError.namesTooLarge {
                        throw Failure.tooLarge
                    } catch is ZIPBrowserError {
                        throw Failure.damaged
                    }
                    let progress = Progress(deadline: deadline, check: check)
                    return try walk(reader.archive, progress: progress, rawName: nil)
                }
                let reader = try Reader(source: source, progress: Progress(deadline: deadline, check: check))
                return try walk(
                    reader.archive, progress: reader.progress,
                    rawName: source.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private static func walk(_ archive: OpaquePointer, progress: Progress, rawName: String?) throws -> Self {
        var entries: [Entry] = []
        var nameBytes = 0
        var pointer: OpaquePointer?
        while true {
            guard progress.proceeds() else { return try interrupted(progress, entries: entries) }
            guard entries.count < maximumEntries else { return Self(entries: entries, ending: .entryLimit) }
            let status = archive_read_next_header(archive, &pointer)
            if status == ARCHIVE_EOF { return Self(entries: entries, ending: .complete) }
            guard status >= ARCHIVE_WARN, let pointer else {
                if progress.stopped { return try interrupted(progress, entries: entries) }
                if archive_read_has_encrypted_entries(archive) > 0, entries.isEmpty {
                    throw Failure.passwordProtected
                }
                guard !entries.isEmpty else { throw Failure.damaged }
                return Self(entries: entries, ending: .damaged)
            }
            let path: String
            if archive_format(archive) == ARCHIVE_FORMAT_RAW {
                // Unfiltered raw matches any file.
                guard let rawName, archive_filter_count(archive) > 1 else { throw Failure.unsupported }
                path = rawName
            } else {
                path = displayPath(of: pointer)
            }
            guard path.utf8.count <= maximumNameBytes - nameBytes else {
                return Self(entries: entries, ending: .nameLimit)
            }
            nameBytes += path.utf8.count
            entries.append(entry(pointer, path: path))
        }
    }

    private static func interrupted(_ progress: Progress, entries: [Entry]) throws -> Self {
        if let interruption = progress.interruption { throw interruption }
        return Self(entries: entries, ending: .timeLimit)
    }

    private static func entry(_ pointer: OpaquePointer, path: String) -> Entry {
        let size = archive_entry_size_is_set(pointer) != 0 ? archive_entry_size(pointer) : nil
        let modified =
            archive_entry_mtime_is_set(pointer) != 0
            ? Date(
                timeIntervalSince1970: TimeInterval(archive_entry_mtime(pointer))
                    + TimeInterval(archive_entry_mtime_nsec(pointer)) / 1_000_000_000)
            : nil
        return Entry(
            path: path, isDirectory: archive_entry_filetype(pointer) == UInt32(S_IFDIR),
            size: size.flatMap { $0 >= 0 ? $0 : nil }, modified: modified,
            isEncrypted: archive_entry_is_encrypted(pointer) != 0)
    }

    // Drops only empty and "." components.
    private static func displayPath(of entry: OpaquePointer) -> String {
        guard let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry) else { return "" }
        return String(cString: raw).split(separator: "/").filter { $0 != "." }
            .prefix(maximumPathDepth).joined(separator: "/")
    }

    private static func startsWithZIPSignature(_ source: URL) throws -> Bool {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.damaged }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: zipSignature.count)
        let count = pread(descriptor, &header, header.count, 0)
        return count == header.count && header == zipSignature
    }

    private final class Progress {
        let deadline: ContinuousClock.Instant
        let check: () throws -> Void
        private(set) var interruption: (any Error)?
        private(set) var timedOut = false

        init(deadline: ContinuousClock.Instant, check: @escaping () throws -> Void) {
            self.deadline = deadline
            self.check = check
        }

        var stopped: Bool { timedOut || interruption != nil }

        func proceeds() -> Bool {
            guard !stopped else { return false }
            do {
                try check()
            } catch {
                interruption = error
                return false
            }
            if ContinuousClock.now >= deadline { timedOut = true }
            return !timedOut
        }
    }

    // Callbacks let cancellation interrupt one long entry.
    private final class Reader {
        let archive: OpaquePointer
        let progress: Progress
        private let descriptor: Int32
        private let size: Int64
        private let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)

        init(source: URL, progress: Progress) throws {
            self.progress = progress
            descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var metadata = stat()
            let described = descriptor >= 0 && fstat(descriptor, &metadata) == 0
            size = metadata.st_size
            guard described, metadata.st_mode & S_IFMT == S_IFREG, let archive = archive_read_new() else {
                if descriptor >= 0 { close(descriptor) }
                buffer.deallocate()
                throw Failure.damaged
            }
            self.archive = archive
            // ARCHIVE_WARN means an external decompressor.
            let support = [
                archive_read_support_filter_gzip, archive_read_support_filter_bzip2, archive_read_support_filter_xz,
                archive_read_support_format_7zip, archive_read_support_format_rar, archive_read_support_format_rar5,
                archive_read_support_format_tar, archive_read_support_format_raw,
            ]
            guard support.allSatisfy({ $0(archive) == ARCHIVE_OK }) else { throw Failure.unsupported }
            archive_read_set_read_callback(archive) { _, context, block in
                guard let context, let block else { return -1 }
                let reader = Unmanaged<Reader>.fromOpaque(context).takeUnretainedValue()
                guard reader.progress.proceeds() else { return -1 }
                while true {
                    let count = read(reader.descriptor, reader.buffer, blockSize)
                    if count < 0, errno == EINTR { continue }
                    block.pointee = UnsafeRawPointer(reader.buffer)
                    return count
                }
            }
            archive_read_set_skip_callback(archive) { _, context, request in
                guard let context else { return 0 }
                let reader = Unmanaged<Reader>.fromOpaque(context).takeUnretainedValue()
                let current = lseek(reader.descriptor, 0, SEEK_CUR)
                // Seeking past the end would hide truncation.
                guard current >= 0, request <= reader.size - current,
                    lseek(reader.descriptor, request, SEEK_CUR) >= 0
                else { return 0 }
                return request
            }
            archive_read_set_seek_callback(archive) { _, context, offset, whence in
                guard let context else { return la_int64_t(ARCHIVE_FATAL) }
                let reader = Unmanaged<Reader>.fromOpaque(context).takeUnretainedValue()
                let position = lseek(reader.descriptor, offset, whence)
                return position < 0 ? la_int64_t(ARCHIVE_FATAL) : position
            }
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(self).toOpaque())
            // Stopped readers report via `proceeds()`.
            guard archive_read_open1(archive) == ARCHIVE_OK || progress.stopped else {
                if archive_read_has_encrypted_entries(archive) > 0 { throw Failure.passwordProtected }
                throw Failure.unsupported
            }
        }

        deinit {
            archive_read_free(archive)
            close(descriptor)
            buffer.deallocate()
        }
    }
}
