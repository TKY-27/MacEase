import Darwin
import Foundation

enum FileOrigin {
    private static let originAttribute = "com.apple.metadata:kMDItemWhereFroms"

    static func record(_ address: URL, onStagedFile output: URL) throws {
        let source = try MediaDownloader.validateURL(address.absoluteString)
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: [source.absoluteString], format: .binary, options: 0)
        let status = encoded.withUnsafeBytes {
            setxattr(output.path, originAttribute, $0.baseAddress, $0.count, 0, 0)
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

}

struct GalleryProvenance: Codable {
    static let filename = "MacEase Source.json"
    let source: URL
    let retrieved: Date
    let tool: String
    let files: [String]
}
