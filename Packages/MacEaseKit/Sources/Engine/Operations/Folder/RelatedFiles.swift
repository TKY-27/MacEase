import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum RelatedFileKind: Sendable {
    case exact
    case visuallySimilar(distance: Float)
}

public struct RelatedFileMatch: Sendable, Identifiable {
    public let url: URL
    public let kind: RelatedFileKind
    public let thumbnail: Data?
    public var id: URL { url }
}

public struct RelatedFilesReport: Sendable {
    public let matches: [RelatedFileMatch]
    public let skippedCount: Int
    public let scannedCount: Int
}

public enum RelatedFilesScanner {
    private static let thumbnailSide = 384
    private static let thumbnailLimit = 64
    private static let featureDistanceLimit: Float = 0.5

    public static func scan(
        source: URL, in root: URL? = nil, progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> RelatedFilesReport {
        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let sourceRoot = root ?? source.deletingLastPathComponent()
        let sourceStamp = try FileStamp(of: source, includingIdentity: true)
        let (urls, unreadableEntries) = try files(in: sourceRoot)
        let candidates = urls.filter { $0.standardizedFileURL != source.standardizedFileURL }
        let total = candidates.count
        let sourceDigest = try Checksum.digest(of: source, algorithm: .sha256) { _ in }
        let sourceBytes = sourceValues.fileSize
        let sourceFeature = try featurePrint(source)
        var matches: [RelatedFileMatch] = []
        var skipped = unreadableEntries
        var scanned = 0
        for url in candidates {
            try Task.checkCancellation()
            do {
                let candidateStamp = try FileStamp(of: url, includingIdentity: true)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    scanned += 1
                    progress(scanned, total)
                    continue
                }
                var candidateMatch: RelatedFileMatch?
                if values.fileSize == sourceBytes,
                    try Checksum.digest(of: url, algorithm: .sha256, progress: { _ in }) == sourceDigest,
                    FileManager.default.contentsEqual(atPath: source.path, andPath: url.path)
                {
                    candidateMatch = RelatedFileMatch(
                        url: url, kind: .exact,
                        thumbnail: matches.count < thumbnailLimit ? thumbnail(url) : nil)
                } else if let sourceFeature, let candidate = try featurePrint(url) {
                    var distance: Float = 0
                    try sourceFeature.computeDistance(&distance, to: candidate)
                    if distance <= featureDistanceLimit {
                        candidateMatch = RelatedFileMatch(
                            url: url, kind: .visuallySimilar(distance: distance),
                            thumbnail: matches.count < thumbnailLimit ? thumbnail(url) : nil)
                    }
                }
                guard try FileStamp(of: url, includingIdentity: true) == candidateStamp else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if let candidateMatch { matches.append(candidateMatch) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
            }
            scanned += 1
            progress(scanned, total)
            try Task.checkCancellation()
        }
        guard try FileStamp(of: source, includingIdentity: true) == sourceStamp,
            try Checksum.digest(of: source, algorithm: .sha256, progress: { _ in }) == sourceDigest
        else { throw CocoaError(.fileReadCorruptFile) }
        return RelatedFilesReport(
            matches: matches.sorted { $0.url.path < $1.url.path }, skippedCount: skipped, scannedCount: scanned)
    }

    private static func files(in root: URL) throws -> ([URL], Int) {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var unreadable = 0
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) { _, _ in
            unreadable += 1
            return true
        }
        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                ])
            } catch {
                unreadable += 1
                continue
            }
            if values.isSymbolicLink == true || values.isPackage == true { enumerator?.skipDescendants() }
            if values.isRegularFile == true { result.append(url) }
        }
        return (result, unreadable)
    }

    private static func featurePrint(_ url: URL) throws -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                throw CocoaError(.fileReadCorruptFile)
            }
            return nil
        }
        guard CGImageSourceGetType(source) != nil else {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                throw CocoaError(.fileReadCorruptFile)
            }
            return nil
        }
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first
    }

    private static func thumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        let thumbnailData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(thumbnailData, "public.jpeg" as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return thumbnailData as Data
    }
}
