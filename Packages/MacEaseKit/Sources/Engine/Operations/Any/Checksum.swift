import CryptoKit
import Foundation
import MenuCatalog

enum Checksum {
    private static let chunkSize = 1 << 20

    static func text(for url: URL, algorithm: ChecksumAlgorithm, context: ItemContext) throws -> ItemResult {
        .text("\(try digest(of: url, algorithm: algorithm, context: context))  \(url.lastPathComponent)", .clipboard)
    }

    static func digest(of url: URL, algorithm: ChecksumAlgorithm, context: ItemContext) throws -> String {
        switch algorithm {
        case .sha256: try hex(of: url, hasher: SHA256(), context: context)
        case .sha1: try hex(of: url, hasher: Insecure.SHA1(), context: context)
        case .sha512: try hex(of: url, hasher: SHA512(), context: context)
        case .md5: try hex(of: url, hasher: Insecure.MD5(), context: context)
        }
    }

    private static func hex<H: HashFunction>(of url: URL, hasher: H, context: ItemContext) throws -> String {
        var hasher = hasher
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let total = max(1, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 1)
        var processed = 0
        while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            processed += chunk.count
            context.progress(Double(processed) / Double(total))
        }
        return hasher.finalize().hexEncoded
    }
}
