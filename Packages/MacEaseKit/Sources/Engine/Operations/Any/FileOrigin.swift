import Darwin
import Foundation

public struct FileOrigin: Sendable {
    public let links: [URL]
    public let sha256: String

    private static let maximumRecordBytes = 65_536
    private static let maximumLinks = 32
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

    public static func inspect(_ source: URL) throws -> FileOrigin {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw EngineError.invalidInput(.unsupportedFileType)
        }
        let stamp = try FileStamp(of: source, includingIdentity: true)
        var links: [URL] = []
        if let encoded = try FinderAttributes.extendedAttribute(originAttribute, of: source) {
            guard encoded.count <= maximumRecordBytes,
                let addresses = try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String],
                addresses.count <= maximumLinks
            else { throw EngineError.decodeFailed("Stored source information is malformed") }
            links = try addresses.map { try MediaDownloader.validateURL($0) }
        }
        let sidecar = source.deletingLastPathComponent().appending(path: GalleryProvenance.filename)
        if source.lastPathComponent != GalleryProvenance.filename, FileManager.default.fileExists(atPath: sidecar.path)
        {
            let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                let bytes = values.fileSize, bytes <= maximumRecordBytes
            else { throw EngineError.decodeFailed("Stored source information is malformed") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(GalleryProvenance.self, from: Data(contentsOf: sidecar))
            if record.tool == "gallery-dl", record.files.contains(source.lastPathComponent) {
                links.append(try MediaDownloader.validateURL(record.source.absoluteString))
            }
        }
        let digest = try Checksum.digest(of: source, algorithm: .sha256) { _ in }
        guard try FileStamp(of: source, includingIdentity: true) == stamp else {
            throw EngineError.decodeFailed("The file changed while inspecting its source")
        }
        var seen = Set<URL>()
        return FileOrigin(links: links.filter { seen.insert($0).inserted }, sha256: digest)
    }
}

struct GalleryProvenance: Codable {
    static let filename = "MacEase Source.json"
    let source: URL
    let retrieved: Date
    let tool: String
    let files: [String]
}
