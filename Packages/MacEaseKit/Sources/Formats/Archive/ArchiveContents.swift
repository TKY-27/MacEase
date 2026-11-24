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
        case complete, entryLimit, nameLimit, skipLimit, timeLimit, damaged
    }

    public enum Failure: Error, Equatable, Sendable {
        case unsupported, damaged, tooLarge, namesTooLarge
    }

    public static let maximumEntries = ZIPDirectoryBounds.maximumEntries
    public static let maximumNameBytes = ZIPDirectoryBounds.maximumMetadataBytes
    public static let maximumPathDepth = 256
    public static let maximumDuration: Duration = .seconds(10)
    public static let maximumCompressedSkipBytes: Int64 = 64 * 1024 * 1024
    private static let maximumDecodedBytes: Int64 = maximumCompressedSkipBytes + Int64(maximumNameBytes)
    private static let readChunkBytes = 4 * 1024
    // One compression filter plus libarchive's base filter.
    private static let maximumFilterChainCount = 2
    private static let tarBlockBytes: Int64 = 512
    private static let headerProbeBytes = 264
    private static let ustarOffset = 257
    private static let zipLocalSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let zipEmptySignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let gzipSignature: [UInt8] = [0x1F, 0x8B]
    private static let bzip2Signature: [UInt8] = [0x42, 0x5A, 0x68]
    private static let xzSignature: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
    private static let ustarSignature: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72]

    public let entries: [Entry]
    public let ending: Ending

    public static func list(
        _ source: URL, maximumDuration: Duration = maximumDuration, check: () throws -> Void = {}
    ) throws -> Self {
        let deadline = ContinuousClock.now + maximumDuration
        return try withoutActuallyEscaping(check) { check in
            try ArchiveListing.inUTF8Locale {
                let progress = Progress(deadline: deadline, check: check)
                guard progress.proceeds() else { return try interrupted(progress, entries: []) }
                if try startsWithZIPSignature(source) {
                    do {
                        return try ArchiveBrowserZIP.withReader(
                            source: source, check: { try progress.checkProceeds() }
                        ) { archive, _ in
                            try walk(
                                archive, progress: progress, rawName: nil, compressed: false,
                                checkDecodedLimit: { false }, startsWithKnownArchive: { false })
                        }
                    } catch is TimeLimitExceeded {
                        return Self(entries: [], ending: .timeLimit)
                    } catch ZIPBrowserError.tooManyEntries {
                        throw Failure.tooLarge
                    } catch ZIPBrowserError.namesTooLarge {
                        throw Failure.namesTooLarge
                    } catch is ZIPBrowserError {
                        throw Failure.damaged
                    }
                }
                let reader = try Reader(source: source, progress: progress)
                return try withExtendedLifetime(reader) {
                    try walk(
                        reader.archive, progress: progress,
                        rawName: source.deletingPathExtension().lastPathComponent,
                        compressed: archive_filter_count(reader.archive) > 1,
                        checkDecodedLimit: { reader.decodedLimitHit },
                        startsWithKnownArchive: { reader.startsWithKnownArchive })
                }
            }
        }
    }

    private static func walk(
        _ archive: OpaquePointer, progress: Progress, rawName: String?, compressed: Bool,
        checkDecodedLimit: () -> Bool, startsWithKnownArchive: () -> Bool
    ) throws -> Self {
        var entries: [Entry] = []
        var headersRead = 0
        var nameBytes = 0
        var skippedBytes: Int64 = 0
        var pointer: OpaquePointer?
        while true {
            guard progress.proceeds() else { return try interrupted(progress, entries: entries) }
            if checkDecodedLimit() { return Self(entries: entries, ending: .skipLimit) }
            guard headersRead < maximumEntries else { return Self(entries: entries, ending: .entryLimit) }
            let status = archive_read_next_header(archive, &pointer)
            if status == ARCHIVE_EOF { return Self(entries: entries, ending: .complete) }
            guard status >= ARCHIVE_WARN, let pointer else {
                if progress.stopped { return try interrupted(progress, entries: entries) }
                if checkDecodedLimit() { return Self(entries: entries, ending: .skipLimit) }
                guard !entries.isEmpty else { throw Failure.damaged }
                return Self(entries: entries, ending: .damaged)
            }
            headersRead += 1
            let isRaw = archive_format(archive) == ARCHIVE_FORMAT_RAW
            let path: String
            if isRaw {
                // Unfiltered raw matches any file.
                guard let rawName, !rawName.isEmpty, compressed else {
                    throw startsWithKnownArchive() ? Failure.damaged : Failure.unsupported
                }
                path = rawName
            } else {
                path = displayPath(of: pointer)
                if path.isEmpty {
                    if compressed {
                        let cost = compressedSkipBytes(of: pointer)
                        guard cost <= maximumCompressedSkipBytes - skippedBytes else {
                            return Self(entries: entries, ending: .skipLimit)
                        }
                        skippedBytes += cost
                    }
                    continue
                }
            }
            guard path.utf8.count <= maximumNameBytes - nameBytes else {
                return Self(entries: entries, ending: .nameLimit)
            }
            nameBytes += path.utf8.count
            entries.append(entry(pointer, path: path))
            if compressed, !isRaw {
                let cost = compressedSkipBytes(of: pointer)
                guard cost <= maximumCompressedSkipBytes - skippedBytes else {
                    return Self(entries: entries, ending: .skipLimit)
                }
                skippedBytes += cost
            }
        }
    }

    private static func compressedSkipBytes(of entry: OpaquePointer) -> Int64 {
        let filetype = archive_entry_filetype(entry)
        guard filetype != UInt32(S_IFDIR), filetype != UInt32(S_IFLNK), archive_entry_hardlink(entry) == nil else {
            return 0
        }
        let rawBytes: Int64
        if archive_entry_sparse_count(entry) > 0 {
            archive_entry_sparse_reset(entry)
            var offset: la_int64_t = 0
            var length: la_int64_t = 0
            var total: Int64 = 0
            while archive_entry_sparse_next(entry, &offset, &length) == ARCHIVE_OK {
                guard length > 0 else { continue }
                let (sum, overflow) = total.addingReportingOverflow(length)
                if overflow { return .max }
                total = sum
            }
            rawBytes = total
        } else if archive_entry_size_is_set(entry) != 0 {
            rawBytes = max(0, archive_entry_size(entry))
        } else {
            return 0
        }
        guard rawBytes > 0 else { return 0 }
        let remainder = rawBytes % tarBlockBytes
        guard remainder != 0 else { return rawBytes }
        let (padded, overflow) = rawBytes.addingReportingOverflow(tarBlockBytes - remainder)
        return overflow ? .max : padded
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
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: zipLocalSignature.count)
        let count = pread(descriptor, &header, header.count, 0)
        return count == header.count && (header == zipLocalSignature || header == zipEmptySignature)
    }

    private static func hasKnownArchiveSignature(_ descriptor: Int32) -> Bool {
        var header = [UInt8](repeating: 0, count: headerProbeBytes)
        let count = pread(descriptor, &header, header.count, 0)
        guard count >= gzipSignature.count else { return false }
        let prefix = Array(header.prefix(count))
        if prefix.starts(with: gzipSignature) || prefix.starts(with: xzSignature) { return true }
        if prefix.count >= 4, prefix.starts(with: bzip2Signature),
            (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(prefix[3])
        {
            return true
        }
        let ustarEnd = ustarOffset + ustarSignature.count
        return prefix.count >= ustarEnd && Array(prefix[ustarOffset..<ustarEnd]) == ustarSignature
    }

    private struct TimeLimitExceeded: Error {}

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

        func checkProceeds() throws {
            guard !proceeds() else { return }
            if let interruption { throw interruption }
            throw TimeLimitExceeded()
        }
    }

    // Callbacks bound read chunks, deadlines, and cancellation.
    private final class Reader {
        let archive: OpaquePointer
        let progress: Progress
        let startsWithKnownArchive: Bool
        private(set) var tooManyFilters = false
        private(set) var decodedLimitHit = false
        private let descriptor: Int32
        private let size: Int64
        private let buffer = UnsafeMutableRawPointer.allocate(byteCount: readChunkBytes, alignment: 16)

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
            self.startsWithKnownArchive = ArchiveContents.hasKnownArchiveSignature(descriptor)
            // ARCHIVE_WARN means an external decompressor.
            let support = [
                archive_read_support_filter_gzip, archive_read_support_filter_bzip2, archive_read_support_filter_xz,
                archive_read_support_format_tar, archive_read_support_format_raw,
            ]
            guard support.allSatisfy({ $0(archive) == ARCHIVE_OK }) else { throw Failure.unsupported }
            archive_read_set_read_callback(archive) { active, context, block in
                guard let active, let context, let block else { return -1 }
                let reader = Unmanaged<Reader>.fromOpaque(context).takeUnretainedValue()
                guard reader.progress.proceeds() else { return -1 }
                let filters = archive_filter_count(active)
                if filters > maximumFilterChainCount {
                    reader.tooManyFilters = true
                    return -1
                }
                if filters > 1, archive_filter_bytes(active, 0) > maximumDecodedBytes {
                    reader.decodedLimitHit = true
                    return -1
                }
                while true {
                    let count = read(reader.descriptor, reader.buffer, readChunkBytes)
                    if count < 0, errno == EINTR { continue }
                    block.pointee = UnsafeRawPointer(reader.buffer)
                    return count
                }
            }
            archive_read_set_skip_callback(archive) { _, context, request in
                guard let context else { return la_int64_t(ARCHIVE_FATAL) }
                let reader = Unmanaged<Reader>.fromOpaque(context).takeUnretainedValue()
                guard reader.progress.proceeds() else { return la_int64_t(ARCHIVE_FATAL) }
                let current = lseek(reader.descriptor, 0, SEEK_CUR)
                // Seeking past the end would hide truncation.
                guard current >= 0, request >= 0, request <= reader.size - current,
                    lseek(reader.descriptor, request, SEEK_CUR) >= 0
                else { return 0 }
                return request
            }
            archive_read_set_seek_callback(archive) { _, context, offset, whence in
                guard let context else { return la_int64_t(ARCHIVE_FATAL) }
                let reader = Unmanaged<Reader>.fromOpaque(context).takeUnretainedValue()
                guard reader.progress.proceeds() else { return la_int64_t(ARCHIVE_FATAL) }
                let position = lseek(reader.descriptor, offset, whence)
                return position < 0 ? la_int64_t(ARCHIVE_FATAL) : position
            }
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(self).toOpaque())
            let opened = archive_read_open1(archive)
            // Stopped readers report via `walk`.
            if progress.stopped { return }
            if tooManyFilters { throw Failure.unsupported }
            if decodedLimitHit { return }
            guard opened == ARCHIVE_OK else {
                throw startsWithKnownArchive ? Failure.damaged : Failure.unsupported
            }
            guard archive_filter_count(archive) <= maximumFilterChainCount else {
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
