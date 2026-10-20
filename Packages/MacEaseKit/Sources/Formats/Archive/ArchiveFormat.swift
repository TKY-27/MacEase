/// Raw values are the file extensions.
public enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case zip
    case sevenZip = "7z"
    case tar
    case tarGzip = "tar.gz"
}
