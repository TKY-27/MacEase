import Foundation

/// Random-access reads through a sliding window.
final class RandomAccessFile {
    private static let windowSize = 1 << 20

    private let handle: FileHandle
    let size: Int64
    private var window: [UInt8] = []
    private var windowStart: Int64 = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try handle.seekToEnd())
    }

    deinit {
        try? handle.close()
    }

    func bytes(at offset: Int64, count: Int) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset + Int64(count) <= size else {
            throw FormatError.corrupt("read past the end of the file")
        }
        if offset >= windowStart, offset + Int64(count) <= windowStart + Int64(window.count) {
            let start = Int(offset - windowStart)
            return Array(window[start..<(start + count)])
        }
        try handle.seek(toOffset: UInt64(offset))
        if count > Self.windowSize {
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }
        window = [UInt8](try handle.read(upToCount: Self.windowSize) ?? Data())
        windowStart = offset
        guard window.count >= count else { throw FormatError.corrupt("short read") }
        return Array(window[0..<count])
    }

    func byte(at offset: Int64) throws -> UInt8 {
        try bytes(at: offset, count: 1)[0]
    }
}

/// Appends, and patches earlier bytes.
final class PatchableFile {
    private let handle: FileHandle
    private(set) var position: Int64 = 0

    /// Refuses existing files so originals stay untouched.
    init(url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw FormatError.io("cannot create \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ bytes: some DataProtocol) throws {
        try handle.write(contentsOf: bytes)
        position += Int64(bytes.count)
    }

    func patch(_ bytes: some DataProtocol, at offset: Int64) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: bytes)
        try handle.seek(toOffset: UInt64(position))
    }

    func close() throws {
        try handle.close()
    }
}
