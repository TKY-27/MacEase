import Darwin
import Foundation

enum ConversionInput {
    static let maximumBytes = 8 * 1024 * 1024
    private static let blockBytes = 64 * 1024

    static func read(_ url: URL, limit: Int64 = Int64(maximumBytes)) throws -> Data {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw EngineError.invalidInput(.unsupportedFileType) }
        guard status.st_size >= 0, status.st_size <= limit else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: limit))
        }
        var bytes = Data()
        while let block = try reader.read(upToCount: blockBytes), !block.isEmpty {
            try Task.checkCancellation()
            guard Int64(block.count) <= limit - Int64(bytes.count) else {
                throw EngineError.invalidInput(.tooLarge(limitBytes: limit))
            }
            bytes.append(block)
        }
        try reader.close()
        try Task.checkCancellation()
        return bytes
    }
}
