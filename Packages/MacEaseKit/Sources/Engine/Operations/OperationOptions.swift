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
    case rename([RenamePlan])
    case video(VideoOperation)
    case folder(FolderOperation)
    case archive(ArchiveOperation)
    case pdf(PDFOperation)
    case text(TextOperation)
    case document(DocumentOutput)
    case plistToJSON
    case jar(JAROperation)
    case audio(AudioOperation)
    case image(ImageOperation)
}
