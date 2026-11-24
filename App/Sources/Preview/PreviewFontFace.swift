import CoreText
import Darwin
import Foundation

enum PreviewFontError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge
    case tooManyFaces
}

// CTFontDescriptor is immutable.
struct PreviewFontFace: @unchecked Sendable {
    static let specimenSizes: [CGFloat] = [12, 16, 20, 28, 40, 64]
    static let maximumFileBytes: Int64 = 64 * 1024 * 1024
    static let maximumFaceCount = 64
    private static let ttcHeaderBytes = 12
    private static let ttcTag: [UInt8] = Array("ttcf".utf8)
    private static let ttcVersion1: UInt32 = 0x0001_0000
    private static let ttcVersion2: UInt32 = 0x0002_0000

    let displayName: String
    let faceCount: Int
    private let descriptor: CTFontDescriptor

    static func load(
        _ url: URL, maximumFileBytes: Int64 = maximumFileBytes, maximumFaceCount: Int = maximumFaceCount
    ) throws -> Self {
        try Task.checkCancellation()
        try validateBounds(url, maximumFileBytes: maximumFileBytes, maximumFaceCount: maximumFaceCount)
        try Task.checkCancellation()
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let first = descriptors.first
        else {
            throw PreviewFontError.unreadable
        }
        guard descriptors.count <= maximumFaceCount else {
            throw PreviewFontError.tooManyFaces
        }
        try Task.checkCancellation()
        let sample = CTFontCreateWithFontDescriptor(first, specimenSizes[0], nil)
        let name = resolvedName(for: sample, fallbackURL: url)
        return Self(displayName: name, faceCount: descriptors.count, descriptor: first)
    }

    func font(size: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    // Reject oversized or huge collections upfront.
    private static func validateBounds(_ url: URL, maximumFileBytes: Int64, maximumFaceCount: Int) throws {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PreviewFontError.unreadable }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 0 else {
            throw PreviewFontError.unreadable
        }
        guard Int64(status.st_size) <= maximumFileBytes else {
            throw PreviewFontError.tooLarge
        }
        var header = [UInt8](repeating: 0, count: ttcHeaderBytes)
        let readCount = header.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, ttcHeaderBytes) }
        guard readCount == ttcHeaderBytes, header.starts(with: ttcTag) else { return }
        let version = uint32BE(header, at: 4)
        guard version == ttcVersion1 || version == ttcVersion2 else { return }
        let faceCount = uint32BE(header, at: 8)
        guard faceCount > 0 else { throw PreviewFontError.unreadable }
        guard faceCount <= UInt32(maximumFaceCount) else { throw PreviewFontError.tooManyFaces }
    }

    private static func uint32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func resolvedName(for font: CTFont, fallbackURL: URL) -> String {
        let display = CTFontCopyDisplayName(font) as String
        if !display.isEmpty { return display }
        let full = CTFontCopyFullName(font) as String
        if !full.isEmpty { return full }
        let postScript = CTFontCopyPostScriptName(font) as String
        if !postScript.isEmpty { return postScript }
        return fallbackURL.deletingPathExtension().lastPathComponent
    }
}
