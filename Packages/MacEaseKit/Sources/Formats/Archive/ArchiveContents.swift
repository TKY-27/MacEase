import CArchive
import Darwin
import Foundation

/// Lists headers; never writes entry data.
public struct ArchiveContents: Sendable {
    public struct Entry: Sendable {
        public let path: String
        public let rawPath: String
        public let isDirectory: Bool
        public let size: Int64?
        public let modified: Date?
        public let isEncrypted: Bool
    }

    public enum Ending: Equatable, Sendable {
        case complete, entryLimit, nameLimit, decodedLimit, timeLimit, damaged
    }

    public enum Failure: Error, Equatable, Sendable {
        case unsupported, damaged, tooLarge, namesTooLarge
    }

    public static let maximumEntries = ZIPDirectoryBounds.maximumEntries
    public static let maximumNameBytes = ZIPDirectoryBounds.maximumMetadataBytes
    public static let maximumPathDepth = 256
    public static let maximumDuration: Duration = .seconds(10)
    public static let maximumDecodedBytes: Int64 = 64 * 1024 * 1024
    // Matches libarchive gzip/bzip2/xz output block size.
    static let decodedBlockBytes = 64 * 1024
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
    private static let compressedContainerExtensions: Set<String> = ["tgz", "tbz", "tbz2", "txz"]

    public let entries: [Entry]
    public let ending: Ending
    let decodedBytes: Int64

    public static func list(
        _ source: URL, maximumDuration: Duration = maximumDuration, check: () throws -> Void = {}
    ) throws -> Self {
        let deadline = ContinuousClock.now + maximumDuration
        return try withoutActuallyEscaping(check) { check in
            try ArchiveListing.inUTF8Locale {
                let progress = Progress(deadline: deadline, check: check)
                guard progress.proceeds() else { return try interrupted(progress, entries: [], decodedBytes: 0) }
                let signature = try probeSignature(source)
                if signature.isZIP {
                    return try listZIP(source, progress: progress, unsupportedOnInvalidZIP: false)
                }
                if signature.isCompressed {
                    return try listCompressed(source, progress: progress)
                }
                do {
                    return try listUncompressed(source, progress: progress, startsWithUstar: signature.isUstar)
                } catch Failure.unsupported {
                    guard progress.proceeds() else { return try interrupted(progress, entries: [], decodedBytes: 0) }
                    return try listZIP(source, progress: progress, unsupportedOnInvalidZIP: true)
                }
            }
        }
    }

    private static func listZIP(
        _ source: URL, progress: Progress, unsupportedOnInvalidZIP: Bool
    ) throws -> Self {
        do {
            return try ArchiveBrowserZIP.withReader(
                source: source, check: { try progress.checkProceeds() }
            ) { archive, expectedEntries in
                try walk(
                    archive, progress: progress, expectedEntries: expectedEntries,
                    compressed: false, rawName: nil, singleFileFallback: nil,
                    decoderState: { (0, false, false) }, startsWithUstar: false)
            }
        } catch is TimeLimitExceeded {
            return Self(entries: [], ending: .timeLimit, decodedBytes: 0)
        } catch ZIPBrowserError.tooManyEntries {
            throw Failure.tooLarge
        } catch ZIPBrowserError.namesTooLarge {
            throw Failure.namesTooLarge
        } catch ZIPBrowserError.invalidZIP where unsupportedOnInvalidZIP {
            throw Failure.unsupported
        } catch is ZIPBrowserError {
            throw Failure.damaged
        }
    }

    private static func listCompressed(_ source: URL, progress: Progress) throws -> Self {
        let decoder = try CompressedDecoder(source: source, progress: progress)
        if progress.stopped {
            return try interrupted(progress, entries: [], decodedBytes: decoder.decodedBytes)
        }
        let stem = source.deletingPathExtension().lastPathComponent
        let singleFileName = Self.singleCompressedFileName(for: source, stem: stem)
        let reader = try DecodedTarReader(decoder: decoder)
        return try withExtendedLifetime(reader) {
            if progress.stopped {
                return try interrupted(progress, entries: [], decodedBytes: decoder.decodedBytes)
            }
            if decoder.decodedLimitHit {
                return Self(entries: [], ending: .decodedLimit, decodedBytes: decoder.decodedBytes)
            }
            if reader.emptyStream {
                if let singleFileName {
                    let single = Entry(
                        path: singleFileName, rawPath: singleFileName, isDirectory: false,
                        size: nil, modified: decoder.headerModified, isEncrypted: false)
                    return Self(entries: [single], ending: .complete, decodedBytes: decoder.decodedBytes)
                }
                return Self(entries: [], ending: .complete, decodedBytes: decoder.decodedBytes)
            }
            return try walk(
                reader.archive, progress: progress, expectedEntries: nil,
                compressed: true, rawName: stem.isEmpty ? nil : stem,
                singleFileFallback: singleFileName.map { ($0, decoder.headerModified) },
                decoderState: { (decoder.decodedBytes, decoder.decodedLimitHit, decoder.damaged) },
                startsWithUstar: false)
        }
    }

    private static func listUncompressed(
        _ source: URL, progress: Progress, startsWithUstar: Bool
    ) throws -> Self {
        let reader = try UncompressedReader(source: source, progress: progress, startsWithUstar: startsWithUstar)
        return try withExtendedLifetime(reader) {
            try walk(
                reader.archive, progress: progress, expectedEntries: nil,
                compressed: false, rawName: nil, singleFileFallback: nil,
                decoderState: { (0, false, false) }, startsWithUstar: startsWithUstar)
        }
    }

    private static func singleCompressedFileName(for source: URL, stem: String) -> String? {
        guard !stem.isEmpty else { return nil }
        let suffix = source.pathExtension.lowercased()
        if compressedContainerExtensions.contains(suffix) || stem.lowercased().hasSuffix(".tar") {
            return nil
        }
        return stem
    }

    private static func walk(
        _ archive: OpaquePointer, progress: Progress, expectedEntries: Int?,
        compressed: Bool, rawName: String?, singleFileFallback: (name: String, modified: Date?)?,
        decoderState: () -> (decoded: Int64, limitHit: Bool, damaged: Bool),
        startsWithUstar: Bool
    ) throws -> Self {
        var entries: [Entry] = []
        var headersRead = 0
        var nameBytes = 0
        var pointer: OpaquePointer?
        while true {
            let state = decoderState()
            guard progress.proceeds() else {
                return try interrupted(progress, entries: entries, decodedBytes: state.decoded)
            }
            if state.limitHit {
                return Self(entries: entries, ending: .decodedLimit, decodedBytes: state.decoded)
            }
            guard headersRead < maximumEntries else {
                return Self(entries: entries, ending: .entryLimit, decodedBytes: state.decoded)
            }
            let status = archive_read_next_header(archive, &pointer)
            let afterState = decoderState()
            if status == ARCHIVE_EOF {
                if let expectedEntries {
                    guard headersRead == expectedEntries,
                        archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP
                    else { throw Failure.damaged }
                }
                if headersRead == 0, let fallback = singleFileFallback {
                    let single = Entry(
                        path: fallback.name, rawPath: fallback.name, isDirectory: false,
                        size: nil, modified: fallback.modified, isEncrypted: false)
                    return Self(entries: [single], ending: .complete, decodedBytes: afterState.decoded)
                }
                return Self(entries: entries, ending: .complete, decodedBytes: afterState.decoded)
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let pointer else {
                if progress.stopped {
                    return try interrupted(progress, entries: entries, decodedBytes: afterState.decoded)
                }
                if afterState.limitHit {
                    return Self(entries: entries, ending: .decodedLimit, decodedBytes: afterState.decoded)
                }
                guard !entries.isEmpty else { throw Failure.damaged }
                return Self(entries: entries, ending: .damaged, decodedBytes: afterState.decoded)
            }
            headersRead += 1
            let isRaw = archive_format(archive) == ARCHIVE_FORMAT_RAW
            if isRaw {
                // Unfiltered raw matches any file.
                guard let rawName, !rawName.isEmpty, compressed else {
                    throw startsWithUstar ? Failure.damaged : Failure.unsupported
                }
                guard rawName.utf8.count <= maximumNameBytes - nameBytes else {
                    return Self(entries: entries, ending: .nameLimit, decodedBytes: afterState.decoded)
                }
                let rawEntry = entry(
                    pointer, path: rawName, rawPath: rawName,
                    fallbackModified: singleFileFallback?.modified)
                return Self(entries: [rawEntry], ending: .complete, decodedBytes: afterState.decoded)
            }
            let rawPath = rawPathname(of: pointer)
            let path = cleanedPath(from: rawPath)
            if !path.isEmpty {
                let retainedBytes = max(path.utf8.count, rawPath.utf8.count)
                guard retainedBytes <= maximumNameBytes - nameBytes else {
                    return Self(entries: entries, ending: .nameLimit, decodedBytes: afterState.decoded)
                }
                nameBytes += retainedBytes
                entries.append(entry(pointer, path: path, rawPath: rawPath, fallbackModified: nil))
            }
            if compressed {
                let skipCost = tarPayloadSkipBytes(of: pointer)
                let projected = afterState.decoded.addingReportingOverflow(skipCost)
                let budgetCeiling = maximumDecodedBytes + Int64(decodedBlockBytes)
                if projected.overflow || projected.partialValue > budgetCeiling {
                    return Self(entries: entries, ending: .decodedLimit, decodedBytes: afterState.decoded)
                }
            }
        }
    }

    // Every entry kind counts toward skipping cost.
    private static func tarPayloadSkipBytes(of entry: OpaquePointer) -> Int64 {
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

    private static func interrupted(_ progress: Progress, entries: [Entry], decodedBytes: Int64) throws -> Self {
        if let interruption = progress.interruption { throw interruption }
        return Self(entries: entries, ending: .timeLimit, decodedBytes: decodedBytes)
    }

    private static func entry(
        _ pointer: OpaquePointer, path: String, rawPath: String, fallbackModified: Date?
    ) -> Entry {
        let size = archive_entry_size_is_set(pointer) != 0 ? archive_entry_size(pointer) : nil
        let modified = entryModifiedDate(pointer) ?? fallbackModified
        return Entry(
            path: path, rawPath: rawPath, isDirectory: archive_entry_filetype(pointer) == UInt32(S_IFDIR),
            size: size.flatMap { $0 >= 0 ? $0 : nil }, modified: modified,
            isEncrypted: archive_entry_is_encrypted(pointer) != 0)
    }

    private static func entryModifiedDate(_ pointer: OpaquePointer) -> Date? {
        guard archive_entry_mtime_is_set(pointer) != 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(archive_entry_mtime(pointer))
                + TimeInterval(archive_entry_mtime_nsec(pointer)) / 1_000_000_000)
    }

    private static func rawPathname(of entry: OpaquePointer) -> String {
        guard let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry) else { return "" }
        return String(cString: raw)
    }

    // Drops only empty and "." components.
    private static func cleanedPath(from raw: String) -> String {
        raw.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    private struct HeaderSignature {
        let isZIP: Bool
        let isCompressed: Bool
        let isUstar: Bool
    }

    private static func probeSignature(_ source: URL) throws -> HeaderSignature {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: headerProbeBytes)
        let count = pread(descriptor, &header, header.count, 0)
        guard count > 0 else { return HeaderSignature(isZIP: false, isCompressed: false, isUstar: false) }
        let prefix = Array(header.prefix(count))
        let isZIP = prefix.starts(with: zipLocalSignature) || prefix.starts(with: zipEmptySignature)
        let isBzip2 =
            prefix.count >= 4 && prefix.starts(with: bzip2Signature)
            && (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(prefix[3])
        let isCompressed = prefix.starts(with: gzipSignature) || isBzip2 || prefix.starts(with: xzSignature)
        let ustarEnd = ustarOffset + ustarSignature.count
        let isUstar = prefix.count >= ustarEnd && Array(prefix[ustarOffset..<ustarEnd]) == ustarSignature
        return HeaderSignature(isZIP: isZIP, isCompressed: isCompressed, isUstar: isUstar)
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

    // Stage 1: decodes one compression layer only.
    private final class CompressedDecoder {
        let archive: OpaquePointer
        let progress: Progress
        private(set) var headerModified: Date?
        private(set) var decodedBytes: Int64 = 0
        private(set) var decodedLimitHit = false
        private(set) var damaged = false
        private(set) var eofReached = false
        private var tooManyFilters = false
        private let descriptor: Int32
        private let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: readChunkBytes, alignment: 16)

        init(source: URL, progress: Progress) throws {
            self.progress = progress
            descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var metadata = stat()
            let described = descriptor >= 0 && fstat(descriptor, &metadata) == 0
            guard described, metadata.st_mode & S_IFMT == S_IFREG, let archive = archive_read_new() else {
                if descriptor >= 0 { close(descriptor) }
                rawBuffer.deallocate()
                throw Failure.damaged
            }
            self.archive = archive
            // ARCHIVE_WARN means an external decompressor.
            let support = [
                archive_read_support_filter_gzip, archive_read_support_filter_bzip2, archive_read_support_filter_xz,
                archive_read_support_format_raw,
            ]
            guard support.allSatisfy({ $0(archive) == ARCHIVE_OK }) else { throw Failure.unsupported }
            archive_read_set_read_callback(archive) { active, context, block in
                guard let active, let context, let block else { return -1 }
                let decoder = Unmanaged<CompressedDecoder>.fromOpaque(context).takeUnretainedValue()
                guard decoder.progress.proceeds() else { return -1 }
                if archive_filter_count(active) > maximumFilterChainCount {
                    decoder.tooManyFilters = true
                    return -1
                }
                while true {
                    let count = read(decoder.descriptor, decoder.rawBuffer, readChunkBytes)
                    if count < 0, errno == EINTR { continue }
                    block.pointee = UnsafeRawPointer(decoder.rawBuffer)
                    return count
                }
            }
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(self).toOpaque())
            let opened = archive_read_open1(archive)
            if progress.stopped { return }
            if tooManyFilters { throw Failure.unsupported }
            guard opened == ARCHIVE_OK else { throw Failure.damaged }
            let filters = archive_filter_count(archive)
            guard filters <= maximumFilterChainCount else { throw Failure.unsupported }
            guard filters == maximumFilterChainCount else { throw Failure.damaged }
            var header: OpaquePointer?
            let status = archive_read_next_header(archive, &header)
            if progress.stopped { return }
            if status == ARCHIVE_EOF {
                eofReached = true
                return
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else { throw Failure.damaged }
            if let header { headerModified = ArchiveContents.entryModifiedDate(header) }
        }

        // Enforces decoded budget and deadline per block.
        func readDecodedBlock(into target: UnsafeMutableRawPointer, capacity: Int) -> Int {
            guard !eofReached else { return 0 }
            guard progress.proceeds() else { return -1 }
            let remaining = maximumDecodedBytes - decodedBytes
            guard remaining > 0 else {
                decodedLimitHit = true
                return -1
            }
            let request = min(capacity, Int(min(remaining, Int64(Int.max))))
            let count = archive_read_data(archive, target, request)
            if count > 0 {
                decodedBytes += Int64(count)
                return count
            }
            if count == 0 {
                eofReached = true
                return 0
            }
            if !progress.stopped { damaged = true }
            return -1
        }

        deinit {
            archive_read_free(archive)
            close(descriptor)
            rawBuffer.deallocate()
        }
    }

    // Stage 2: parses TAR/RAW from decoded blocks.
    private final class DecodedTarReader {
        let archive: OpaquePointer
        let decoder: CompressedDecoder
        private(set) var emptyStream = false
        private let decodedBuffer = UnsafeMutableRawPointer.allocate(byteCount: decodedBlockBytes, alignment: 16)

        init(decoder: CompressedDecoder) throws {
            self.decoder = decoder
            guard let archive = archive_read_new() else {
                decodedBuffer.deallocate()
                throw Failure.damaged
            }
            self.archive = archive
            let support = [
                archive_read_support_filter_none, archive_read_support_format_tar, archive_read_support_format_raw,
            ]
            guard support.allSatisfy({ $0(archive) == ARCHIVE_OK }) else { throw Failure.unsupported }
            archive_read_set_read_callback(archive) { _, context, block in
                guard let context, let block else { return -1 }
                let reader = Unmanaged<DecodedTarReader>.fromOpaque(context).takeUnretainedValue()
                let count = reader.decoder.readDecodedBlock(into: reader.decodedBuffer, capacity: decodedBlockBytes)
                guard count >= 0 else { return -1 }
                block.pointee = UnsafeRawPointer(reader.decodedBuffer)
                return count
            }
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(self).toOpaque())
            let opened = archive_read_open1(archive)
            if decoder.progress.stopped || decoder.decodedLimitHit { return }
            if decoder.damaged { throw Failure.damaged }
            if opened != ARCHIVE_OK {
                if decoder.eofReached, decoder.decodedBytes == 0 {
                    emptyStream = true
                    return
                }
                throw Failure.damaged
            }
        }

        deinit {
            archive_read_free(archive)
            decodedBuffer.deallocate()
        }
    }

    // Uncompressed TAR skips via lseek directly.
    private final class UncompressedReader {
        let archive: OpaquePointer
        let progress: Progress
        private let descriptor: Int32
        private let size: Int64
        private let buffer = UnsafeMutableRawPointer.allocate(byteCount: readChunkBytes, alignment: 16)

        init(source: URL, progress: Progress, startsWithUstar: Bool) throws {
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
            let support = [
                archive_read_support_filter_none, archive_read_support_format_tar, archive_read_support_format_raw,
            ]
            guard support.allSatisfy({ $0(archive) == ARCHIVE_OK }) else { throw Failure.unsupported }
            archive_read_set_read_callback(archive) { _, context, block in
                guard let context, let block else { return -1 }
                let reader = Unmanaged<UncompressedReader>.fromOpaque(context).takeUnretainedValue()
                guard reader.progress.proceeds() else { return -1 }
                while true {
                    let count = read(reader.descriptor, reader.buffer, readChunkBytes)
                    if count < 0, errno == EINTR { continue }
                    block.pointee = UnsafeRawPointer(reader.buffer)
                    return count
                }
            }
            archive_read_set_skip_callback(archive) { _, context, request in
                guard let context else { return la_int64_t(ARCHIVE_FATAL) }
                let reader = Unmanaged<UncompressedReader>.fromOpaque(context).takeUnretainedValue()
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
                let reader = Unmanaged<UncompressedReader>.fromOpaque(context).takeUnretainedValue()
                guard reader.progress.proceeds() else { return la_int64_t(ARCHIVE_FATAL) }
                let position = lseek(reader.descriptor, offset, whence)
                return position < 0 ? la_int64_t(ARCHIVE_FATAL) : position
            }
            archive_read_set_callback_data(archive, Unmanaged.passUnretained(self).toOpaque())
            let opened = archive_read_open1(archive)
            if progress.stopped { return }
            guard opened == ARCHIVE_OK else {
                throw startsWithUstar ? Failure.damaged : Failure.unsupported
            }
        }

        deinit {
            archive_read_free(archive)
            close(descriptor)
            buffer.deallocate()
        }
    }
}
