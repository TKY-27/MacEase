import Foundation

public enum ChecksumAlgorithm: String, Codable, CaseIterable, Sendable {
    case sha256
    case sha1
    case sha512
    case md5
}

/// Fully resolved parameters for one operation run.
public enum OperationOptions: Codable, Hashable, Sendable {
    case checksum(ChecksumAlgorithm)
    case video(VideoOperation)
    case folder(FolderOperation)
    case archive(ArchiveOperation)
}
