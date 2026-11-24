import CArchive
import Darwin
import Foundation

final class ArchiveReadSource {
    static let maximumParts = 10_000
    private static let blockSize = 64 * 1024
    private static let maximumWindows = 2
    private struct Part {
        let descriptor: Int32
        let offset: Int64
        let size: Int64
    }

    private var parts: [Part] = []
    private var windows: [(offset: Int64, bytes: [UInt8])] = []
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 1)
    var streamBlockSize = ArchiveReadSource.blockSize
    private var offset: Int64 = 0
    private var logicalSize: Int64 = 0
    private(set) var size: Int64 = 0
    private(set) var failure: (any Error)?
    private let check: () throws -> Void

    init(_ urls: [URL], check: @escaping () throws -> Void = {}) throws {
        self.check = check
        guard !urls.isEmpty, urls.count <= Self.maximumParts else { throw ArchiveError.nameInspectionLimit }
        do {
            for url in urls {
                try check()
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw FormatError.io("archive volume unavailable") }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                    metadata.st_size >= 0, metadata.st_size <= Int64.max - size
                else {
                    close(descriptor)
                    throw FormatError.corrupt("invalid archive volume")
                }
                parts.append(Part(descriptor: descriptor, offset: size, size: metadata.st_size))
                size += metadata.st_size
            }
            logicalSize = size
        } catch {
            for part in parts { close(part.descriptor) }
            parts.removeAll()
            throw error
        }
    }

    deinit {
        for part in parts { close(part.descriptor) }
        buffer.deallocate()
    }

    func read(at position: Int64, count: Int, check: () throws -> Void) throws -> [UInt8] {
        try check()
        guard position >= 0, count >= 0, position <= size, Int64(count) <= size - position else {
            throw FormatError.corrupt("invalid archive metadata range")
        }
        if count <= Self.blockSize {
            if let window = windows.first(where: {
                position >= $0.offset && position + Int64(count) <= $0.offset + Int64($0.bytes.count)
            }) {
                let start = Int(position - window.offset)
                return Array(window.bytes[start..<(start + count)])
            }
            let start = position / Int64(Self.blockSize) * Int64(Self.blockSize)
            let length = Int(min(Int64(Self.blockSize), size - start))
            if position + Int64(count) <= start + Int64(length) {
                let bytes = try readExactly(at: start, count: length, check: check)
                if windows.count == Self.maximumWindows { windows.removeFirst() }
                windows.append((start, bytes))
                let relative = Int(position - start)
                return Array(bytes[relative..<(relative + count)])
            }
        }
        return try readExactly(at: position, count: count, check: check)
    }

    private func readExactly(at position: Int64, count: Int, check: () throws -> Void) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            var completed = 0
            while completed < count {
                try check()
                let amount = try read(
                    into: base.advanced(by: completed), at: position + Int64(completed), count: count - completed)
                guard amount > 0 else { throw FormatError.corrupt("truncated archive metadata") }
                completed += amount
            }
        }
        return bytes
    }

    private func read(into destination: UnsafeMutableRawPointer, at position: Int64, count: Int) throws -> Int {
        try check()
        guard position >= 0, position <= size else { throw FormatError.corrupt("invalid archive offset") }
        guard position < size else { return 0 }
        var lower = 0
        var upper = parts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if parts[middle].offset + parts[middle].size <= position { lower = middle + 1 } else { upper = middle }
        }
        guard lower < parts.count else { throw FormatError.corrupt("missing archive volume") }
        let part = parts[lower]
        let request = min(count, Int(part.offset + part.size - position))
        while true {
            let amount = pread(part.descriptor, destination, request, position - part.offset)
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return amount
        }
    }

    func open(_ archive: OpaquePointer, endingAt end: Int64? = nil) throws {
        logicalSize = end ?? size
        archive_read_set_callback_data(archive, Unmanaged.passUnretained(self).toOpaque())
        archive_read_set_read_callback(archive) { _, context, block in
            guard let context, let block else { return -1 }
            let source = Unmanaged<ArchiveReadSource>.fromOpaque(context).takeUnretainedValue()
            do {
                let request = min(Int64(source.streamBlockSize), source.logicalSize - source.offset)
                let count = try source.read(into: source.buffer, at: source.offset, count: Int(request))
                source.offset += Int64(count)
                block.pointee = UnsafeRawPointer(source.buffer)
                return count
            } catch {
                source.failure = error
                return -1
            }
        }
        archive_read_set_skip_callback(archive) { _, context, request in
            guard let context, request >= 0 else { return 0 }
            let source = Unmanaged<ArchiveReadSource>.fromOpaque(context).takeUnretainedValue()
            do {
                try source.check()
                let count = min(request, source.logicalSize - source.offset)
                source.offset += count
                return count
            } catch {
                source.failure = error
                return 0
            }
        }
        archive_read_set_seek_callback(archive) { _, context, displacement, whence in
            guard let context else { return la_int64_t(ARCHIVE_FATAL) }
            let source = Unmanaged<ArchiveReadSource>.fromOpaque(context).takeUnretainedValue()
            do {
                try source.check()
                let origin: Int64
                switch whence {
                case SEEK_SET: origin = 0
                case SEEK_CUR: origin = source.offset
                case SEEK_END: origin = source.logicalSize
                default: throw FormatError.corrupt("invalid archive seek")
                }
                let (position, overflow) = origin.addingReportingOverflow(displacement)
                guard !overflow, position >= 0, position <= source.logicalSize else {
                    throw FormatError.corrupt("invalid archive seek")
                }
                source.offset = position
                return position
            } catch {
                source.failure = error
                return la_int64_t(ARCHIVE_FATAL)
            }
        }
        guard archive_read_open1(archive) == ARCHIVE_OK else {
            if let failure { throw failure }
            throw FormatError.corrupt(ArchiveListing.message(archive))
        }
    }
}
