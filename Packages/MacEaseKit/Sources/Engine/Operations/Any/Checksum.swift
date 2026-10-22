import CryptoKit
import Formats
import Foundation
import MenuCatalog

enum Checksum {
    private static let chunkSize = 1 << 20

    static func text(for url: URL, algorithm: ChecksumAlgorithm, context: ItemContext) throws -> ItemResult {
        .text(
            "\(try digest(of: url, algorithm: algorithm, progress: context.progress))  \(url.lastPathComponent)",
            .clipboard)
    }

    static func digest(of url: URL, algorithm: ChecksumAlgorithm, progress: (Double) -> Void) throws -> String {
        switch algorithm {
        case .sha256: try hex(of: url, hasher: SHA256(), progress: progress)
        case .sha1: try hex(of: url, hasher: Insecure.SHA1(), progress: progress)
        case .sha512: try hex(of: url, hasher: SHA512(), progress: progress)
        case .md5: try hex(of: url, hasher: Insecure.MD5(), progress: progress)
        }
    }

    private static func hex<H: HashFunction>(of url: URL, hasher: H, progress: (Double) -> Void) throws -> String {
        var hasher = hasher
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let total = max(1, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 1)
        var processed = 0
        while let chunk = try reader.readChunk(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            processed += chunk.count
            progress(Double(processed) / Double(total))
        }
        return hasher.finalize().hexEncoded
    }
}
