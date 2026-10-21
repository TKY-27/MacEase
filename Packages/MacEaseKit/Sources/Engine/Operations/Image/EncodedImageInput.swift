import Formats
import Foundation

enum EncodedImageInput {
    static let maximumBytes = ImageMemoryLimits.encodedBytes

    static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, Int64(size) > maximumBytes {
            throw EngineError.invalidInput(.tooLarge(limitBytes: maximumBytes))
        }
        let reader = try FileHandle(forReadingFrom: url)
        var payload = Data()
        do {
            while payload.count <= maximumBytes {
                try Task.checkCancellation()
                let requested = Int(maximumBytes) + 1 - payload.count
                guard let chunk = try reader.read(upToCount: requested), !chunk.isEmpty else { break }
                payload.append(chunk)
            }
        } catch {
            try reader.close()
            throw error
        }
        try reader.close()
        guard payload.count <= maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: maximumBytes))
        }
        return payload
    }
}
