import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata filtering, stripping and orientation-only rotation.
enum ImageMetadata {
    private static let iptcPrefixes: Set<String> = ["dc", "photoshop", "Iptc4xmpCore", "Iptc4xmpExt"]
    private static let exifPrefixes: Set<String> = ["exif", "exifEX", "aux", "tiff"]
    /// Layout tags every field selection keeps.
    private static let layoutTags: Set<String> = [
        "tiff:Orientation", "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit",
    ]
    private static var makerDictionaries: [CFString] {
        [
            kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
            kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerMinoltaDictionary,
            kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerOlympusDictionary,
            kCGImagePropertyMakerPentaxDictionary,
        ]
    }

    /// `nil` for tags no field selection removes.
    static func field(ofTagAt path: String) -> MetadataField? {
        guard !layoutTags.contains(path) else { return nil }
        let prefix = String(path.prefix { $0 != ":" })
        if prefix == "iio" { return nil }
        if path.hasPrefix("exif:GPS") { return .gps }
        if path == "exif:UserComment" { return .comments }
        if exifPrefixes.contains(prefix) { return .exif }
        if iptcPrefixes.contains(prefix) { return .iptc }
        return .xmp
    }

    static func filtered(_ metadata: CGImageMetadata?, removing fields: Set<MetadataField>) -> CGImageMetadata? {
        guard let metadata else { return nil }
        let removed = topLevelTags(of: metadata).filter { path, _ in field(ofTagAt: path).map(fields.contains) ?? false
        }
        // Copies keep maker notes, which lack tags.
        if !fields.contains(.makerNotes), let copy = CGImageMetadataCreateMutableCopy(metadata) {
            for (path, _) in removed { CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString) }
            return copy
        }
        let result = CGImageMetadataCreateMutable()
        for (path, tag) in topLevelTags(of: metadata) where !removed.contains(where: { $0.0 == path }) {
            CGImageMetadataSetTagWithPath(result, nil, path as CFString, tag)
        }
        return result
    }

    private static func topLevelTags(of metadata: CGImageMetadata) -> [(String, CGImageMetadataTag)] {
        var tags: [(String, CGImageMetadataTag)] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            tags.append((path as String, tag))
            return true
        }
        return tags
    }

    static func strip(_ url: URL, fields: Set<MetadataField>, context: ItemContext) async throws -> ItemResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
        else {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            guard SVGRenderer.isSVG(try reader.read(upToCount: SVGRenderer.sniffLength) ?? Data()) else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
            return .skipped(.nothingToRemove)
        }
        let count = CGImageSourceGetCount(source)
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let metadata = CGImageSourceCopyMetadataAtIndex(source, primary, nil)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, nil) as? [CFString: Any] ?? [:]
        let hasMakerNotes = makerDictionaries.contains { properties[$0] != nil }
        let removable = metadata.map { topLevelTags(of: $0) }?.contains { path, _ in
            field(ofTagAt: path).map(fields.contains) ?? false
        }
        guard removable == true || (fields.contains(.makerNotes) && hasMakerNotes) else {
            return .skipped(.nothingToRemove)
        }
        let gainMaps = try ImageGainMap.read(source, at: primary)
        let losesCalibration =
            fields.contains(.makerNotes)
            && gainMaps.contains(where: { $0.type == kCGImageAuxiliaryDataTypeHDRGainMap })
        if losesCalibration, context.settings.outputMode == .replace { throw EngineError.imageHDRUnsupported }
        let kept = filtered(metadata, removing: fields)
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        var output = StagedFile(url: staged, name: url.lastPathComponent, check: .image)
        if type.conforms(to: .jpeg), !losesCalibration {
            try copy(source, to: staged, type: type, metadata: kept)
        } else if count == 1, type.conforms(to: .png) || type.conforms(to: .tiff) && !type.conforms(to: .rawImage) {
            try rewrite(source, to: staged, type: type, metadata: kept)
        } else {
            let loaded = try await ImageDocument.load(url)
            guard let format = loaded.format else { return .skipped(.nothingToRemove) }
            let document = try ImageOutput.prepared(
                loaded, as: format, context: context, preservesGainMaps: !losesCalibration)
            if document.toneMapsHDR {
                output = StagedFile(url: staged, name: url.lastPathComponent, check: .sdrImage)
            }
            var options = ImageOutput.defaultOptions(for: document, format: format, settings: context.settings.image)
            options.metadata =
                document.toneMapsHDR
                ? ImageMetadata.filtered(document.metadata, removing: fields) : kept
            let keptCount = try ImageOutput.keptFrameCount(of: document, for: format)
            if document.isAnimated, keptCount > 1 {
                try await ImageEncoder.encodeStreaming(
                    frameCount: keptCount, as: format, options: options, to: staged
                ) { index in try document.frame(at: index) }
            } else {
                let frames = Array(document.frames.prefix(keptCount))
                try ImageEncoder.encode(frames, as: format, options: options).write(to: staged)
            }
        }
        if type.conforms(to: .jpeg), !losesCalibration {
            guard let written = CGImageSourceCreateWithURL(staged as CFURL, nil) else {
                throw EngineError.imageGainMapUnsupported
            }
            try ImageGainMap.verify(gainMaps, in: written)
        }
        return .replace(original: url, output: output)
    }

    /// Copies compressed JPEG data untouched.
    private static func copy(_ source: CGImageSource, to url: URL, type: UTType, metadata: CGImageMetadata?) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw EngineError.encodeFailed(type.identifier) }
        var options: [CFString: Any] = [kCGImageDestinationMergeMetadata: false]
        options[kCGImageDestinationMetadata] = metadata ?? CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw EngineError.encodeFailed(error.map { "\($0.takeRetainedValue())" } ?? "metadata copy")
        }
    }

    /// Lossless formats re-encode the stored pixels exactly.
    private static func rewrite(_ source: CGImageSource, to url: URL, type: UTType, metadata: CGImageMetadata?) throws {
        var budget = FrameMemoryBudget.renderedPage
        try budget.reserve(source: source, index: 0)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw EngineError.encodeFailed(type.identifier) }
        var actualBudget = FrameMemoryBudget.renderedPage
        try actualBudget.reserve(image)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed(type.identifier) }
    }

    /// `nil` unless JPEG; edits only the tag.
    static func rotateLosslessly(_ url: URL, quarterTurns: Int, context: ItemContext) throws -> ItemResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let identifier = CGImageSourceGetType(source), UTType(identifier as String)?.conforms(to: .jpeg) == true,
            CGImageSourceGetCount(source) == 1
        else { return nil }
        guard try ImageGainMap.read(source, at: 0).isEmpty else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let current = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let rotated = Orientation.rotating(current, clockwiseQuarterTurns: quarterTurns)
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, identifier, 1, nil) else {
            throw EngineError.encodeFailed("JPEG")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationOrientation: rotated, kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw EngineError.encodeFailed(error.map { "\($0.takeRetainedValue())" } ?? "orientation copy")
        }
        return .replace(original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .image))
    }
}

/// EXIF orientations as stored-to-displayed matrices.
enum Orientation {
    /// Indexed by EXIF value minus one.
    private static let matrices: [[Int]] = [
        [1, 0, 0, 1], [-1, 0, 0, 1], [-1, 0, 0, -1], [1, 0, 0, -1],
        [0, 1, 1, 0], [0, -1, 1, 0], [0, -1, -1, 0], [0, 1, -1, 0],
    ]
    private static let quarterTurn = [0, -1, 1, 0]

    static func rotating(_ orientation: UInt32, clockwiseQuarterTurns turns: Int) -> UInt32 {
        let start = (1...8).contains(orientation) ? Int(orientation) - 1 : 0
        var matrix = matrices[start]
        for _ in 0..<(((turns % 4) + 4) % 4) { matrix = multiply(quarterTurn, matrix) }
        return UInt32((matrices.firstIndex(of: matrix) ?? 0) + 1)
    }

    private static func multiply(_ left: [Int], _ right: [Int]) -> [Int] {
        [
            left[0] * right[0] + left[1] * right[2], left[0] * right[1] + left[1] * right[3],
            left[2] * right[0] + left[3] * right[2], left[2] * right[1] + left[3] * right[3],
        ]
    }
}
