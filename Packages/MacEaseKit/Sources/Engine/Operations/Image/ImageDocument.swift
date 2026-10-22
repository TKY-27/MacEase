import CoreImage
import Formats
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageFrame {
    var image: CGImage
    /// Seconds; zero for stills and pages.
    var duration: Double
    var metadata: CGImageMetadata? = nil
}

/// Frames are already oriented for display.
struct ImageDocument {
    let url: URL
    let contentType: UTType
    /// `nil` for RAW and vector sources.
    let format: ImageFormat?
    var frames: [ImageFrame]
    let isAnimated: Bool
    let loopCount: Int?
    let metadata: CGImageMetadata?
    let gainMaps: [ImageGainMap]
    let pixelsPerInch: Double
    let containsHDR: Bool
    let containsHDRPixels: Bool
    let toneMapsHDR: Bool
    private let imageSource: CGImageSource?
    private let sourceIndices: [Int]
    private let animationSource: CGImageSource?

    static let defaultPixelsPerInch = 72.0

    var first: CGImage { frames[0].image }
    var frameCount: Int { animationSource.map(CGImageSourceGetCount) ?? frames.count }
    var isRaw: Bool { contentType.conforms(to: .rawImage) }
    var isMultiPage: Bool { !isAnimated && frames.count > 1 }

    func metadataFields() throws -> [MetadataField] {
        var fields = Set<MetadataField>()
        if let imageSource {
            for index in 0..<CGImageSourceGetCount(imageSource) {
                try Task.checkCancellation()
                let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] ?? [:]
                fields.formUnion(
                    ImageMetadata.presentFields(
                        CGImageSourceCopyMetadataAtIndex(imageSource, index, nil), properties: properties))
            }
        } else {
            fields.formUnion(ImageMetadata.presentFields(metadata))
            for frame in frames { fields.formUnion(ImageMetadata.presentFields(frame.metadata)) }
        }
        return MetadataField.allCases.filter(fields.contains)
    }

    /// Derived outputs for RAW and vector sources.
    var writableFormat: ImageFormat {
        format ?? ([.none, .noneSkipFirst, .noneSkipLast].contains(first.alphaInfo) ? .jpeg : .png)
    }

    init(
        url: URL, contentType: UTType, frames: [ImageFrame], isAnimated: Bool = false, loopCount: Int? = 0,
        metadata: CGImageMetadata? = nil, gainMaps: [ImageGainMap] = [],
        pixelsPerInch: Double = ImageDocument.defaultPixelsPerInch,
        animationSource: CGImageSource? = nil, imageSource: CGImageSource? = nil,
        sourceIndices: [Int] = [], containsHDR: Bool = false, containsHDRPixels: Bool = false,
        toneMapsHDR: Bool = false
    ) {
        self.url = url
        self.contentType = contentType
        self.format = contentType.conforms(to: .svg) ? nil : ImageFormat(contentType: contentType)
        self.frames = frames
        self.isAnimated = isAnimated
        self.loopCount = loopCount
        self.metadata = metadata
        self.gainMaps = gainMaps
        self.pixelsPerInch = pixelsPerInch
        self.animationSource = animationSource
        self.imageSource = imageSource
        self.sourceIndices = sourceIndices
        let hdrPixels = containsHDRPixels || frames.contains { ImageSDR.hasHDRPixels($0.image) }
        self.containsHDR = containsHDR || hdrPixels || !gainMaps.isEmpty
        self.containsHDRPixels = hdrPixels
        self.toneMapsHDR = toneMapsHDR
    }

    func frame(at index: Int) throws -> ImageFrame {
        guard (0..<frameCount).contains(index) else { throw EngineError.decodeFailed(url.lastPathComponent) }
        guard let animationSource else { return frames[index] }
        if index == 0 { return frames[0] }
        return try Self.decodeFrame(
            animationSource, index: index, url: url, animation: AnimationKeys(type: contentType),
            toneMapsHDR: toneMapsHDR)
    }

    func toneMappedToSDR() throws -> ImageDocument {
        guard let imageSource else { throw EngineError.hdrConversionUnsupported }
        var retained = FrameMemoryBudget()
        for frame in frames { try retained.reserve(frame.image) }
        let converted = try sourceIndices.map { index in
            let frame = try Self.decodeFrame(
                imageSource, index: index, url: url, animation: AnimationKeys(type: contentType),
                toneMapsHDR: true, retaining: retained)
            try retained.reserve(frame.image)
            return frame
        }
        return ImageDocument(
            url: url, contentType: contentType, frames: converted, isAnimated: isAnimated,
            loopCount: loopCount,
            metadata: try ImageSDR.metadataForSDR(metadata, image: converted[0].image),
            pixelsPerInch: pixelsPerInch, animationSource: animationSource, imageSource: imageSource,
            sourceIndices: sourceIndices, toneMapsHDR: true)
    }

    func frameDuration(at index: Int) throws -> Double {
        guard (0..<frameCount).contains(index) else { throw EngineError.decodeFailed(url.lastPathComponent) }
        guard let animationSource else { return frames[index].duration }
        let properties = CGImageSourceCopyPropertiesAtIndex(animationSource, index, nil) as? [CFString: Any] ?? [:]
        return AnimationKeys(type: contentType)?.delay(in: properties) ?? 0
    }

    static func load(_ url: URL) async throws -> ImageDocument {
        var budget = FrameMemoryBudget()
        return try await load(url, budget: &budget)
    }

    static func load(_ url: URL, budget: inout FrameMemoryBudget) async throws -> ImageDocument {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions), CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source).map({ UTType(importedAs: $0 as String, conformingTo: .image) })
        {
            if type.conforms(to: .ico) {
                try ICOFile.validateStructure(try EncodedImageInput.read(url))
            }
            do {
                return try decode(source, type: type, url: url, budget: &budget)
            } catch EngineError.decodeFailed where type.conforms(to: .ico) || type.conforms(to: .icns) {
                return try decodeIcon(try EncodedImageInput.read(url), url: url, budget: &budget)
            }
        }
        let fileBytes = try EncodedImageInput.read(url)
        if SVGRenderer.isSVG(fileBytes) {
            let dimensions = try SVGRenderer.dimensions(fileBytes)
            var preflight = budget
            try preflight.reserve(width: dimensions.width, height: dimensions.height)
            let image = try await SVGRenderer.render(fileBytes)
            var actual = budget
            try actual.reserve(image)
            budget = actual
            return ImageDocument(url: url, contentType: .svg, frames: [ImageFrame(image: image, duration: 0)])
        }
        return try decodeIcon(fileBytes, url: url, budget: &budget)
    }

    private static func decode(
        _ source: CGImageSource, type: UTType, url: URL, budget: inout FrameMemoryBudget
    ) throws -> ImageDocument {
        let count = CGImageSourceGetCount(source)
        let animation = AnimationKeys(type: type)
        let isAnimated = count > 1 && animation != nil
        if count > 1, animation == nil,
            !type.conforms(to: .tiff), !type.conforms(to: .rawImage),
            !type.conforms(to: .ico), !type.conforms(to: .icns),
            type.identifier != "com.adobe.photoshop-image"
        {
            throw EngineError.imageSequenceUnsupported
        }
        let indices: [Int]
        if isAnimated {
            indices = [0]
        } else if type.conforms(to: .tiff) && !type.conforms(to: .rawImage) {
            indices = Array(0..<count)
        } else if type.conforms(to: .ico) || type.conforms(to: .icns) {
            indices = [try largestIndex(in: source)]
        } else {
            indices = [CGImageSourceGetPrimaryImageIndex(source)]
        }
        var retained = FrameMemoryBudget.retainedImages
        var preflight = budget
        var containsHDR = false
        var containsHDRPixels = false
        for position in 0..<(isAnimated ? count : indices.count) {
            try Task.checkCancellation()
            let index = isAnimated ? position : indices[position]
            let content = try ImageSDR.content(source, index: index)
            containsHDR = containsHDR || content.gainMap || content.pixels
            containsHDRPixels = containsHDRPixels || content.pixels
            var rawBudget = FrameMemoryBudget()
            try rawBudget.reserve(source: source, index: index)
            if isAnimated {
                var frameBudget = FrameMemoryBudget()
                try frameBudget.reserve(source: source, index: index, oriented: true)
            } else {
                try preflight.reserve(source: source, index: index, oriented: true)
                if indices.count > 1 { try retained.reserve(source: source, index: index, oriented: true) }
            }
        }
        var actualBudget = budget
        var retainedActual = FrameMemoryBudget.retainedImages
        let frames = try indices.map { index in
            try Task.checkCancellation()
            let frame = try decodeFrame(source, index: index, url: url, animation: animation)
            try actualBudget.reserve(frame.image)
            if indices.count > 1 { try retainedActual.reserve(frame.image) }
            return frame
        }
        let primary = indices[0]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, nil) as? [CFString: Any] ?? [:]
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let orientation =
            (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let gainMaps = try ImageGainMap.read(source, at: primary).map { gainMap in
            try gainMap.oriented(orientation)
        }
        let document = ImageDocument(
            url: url, contentType: type, frames: frames, isAnimated: isAnimated,
            loopCount: animation?.loopCount(in: container),
            metadata: CGImageSourceCopyMetadataAtIndex(source, primary, nil),
            gainMaps: gainMaps,
            pixelsPerInch: (properties[kCGImagePropertyDPIWidth] as? Double) ?? defaultPixelsPerInch,
            animationSource: isAnimated ? source : nil, imageSource: source, sourceIndices: indices,
            containsHDR: containsHDR, containsHDRPixels: containsHDRPixels
        )
        budget = actualBudget
        return document
    }

    private static func decodeFrame(
        _ source: CGImageSource, index: Int, url: URL, animation: AnimationKeys?,
        toneMapsHDR: Bool = false, retaining retained: FrameMemoryBudget = FrameMemoryBudget()
    ) throws -> ImageFrame {
        try autoreleasepool {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let orientation =
                (properties[kCGImagePropertyOrientation] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
            if toneMapsHDR {
                let image = try ImageSDR.decodedSDR(
                    source, index: index, orientation: orientation, retaining: retained)
                return ImageFrame(
                    image: image, duration: animation?.delay(in: properties) ?? 0,
                    metadata: try ImageSDR.metadataForSDR(
                        CGImageSourceCopyMetadataAtIndex(source, index, nil), image: image))
            }
            var preflight = FrameMemoryBudget()
            try preflight.reserve(source: source, index: index)
            if orientation != .up { try preflight.reserve(source: source, index: index, oriented: true) }
            guard let raw = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
            var actual = FrameMemoryBudget()
            try actual.reserve(raw)
            if orientation != .up {
                var projected = actual
                try projected.reserve(
                    width: orientation.swapsAxes ? raw.height : raw.width,
                    height: orientation.swapsAxes ? raw.width : raw.height,
                    bytesPerPixel: raw.bitsPerComponent > 8 ? 8 : 4)
            }
            let oriented = try ImagePixels.oriented(raw, orientation)
            if oriented !== raw { try actual.reserve(oriented) }
            return ImageFrame(
                image: oriented, duration: animation?.delay(in: properties) ?? 0,
                metadata: CGImageSourceCopyMetadataAtIndex(source, index, nil))
        }
    }

    private static func largestIndex(in source: CGImageSource) throws -> Int {
        var largest = 0
        var width = 0
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            let candidate = pixelWidth(source, index)
            if candidate > width {
                largest = index
                width = candidate
            }
        }
        return largest
    }

    private static func pixelWidth(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    private static let icoSignature = Data([0, 0, 1, 0])
    private static let icnsSignature = Data("icns".utf8)

    private static func decodeIcon(_ fileBytes: Data, url: URL, budget: inout FrameMemoryBudget) throws -> ImageDocument
    {
        let type: UTType
        let image: PixelBuffer
        do {
            if fileBytes.starts(with: icoSignature) {
                let dimensions = try ICOFile.largestDimensions(fileBytes)
                var preflight = budget
                try preflight.reserve(width: dimensions.width, height: dimensions.height)
                (type, image) = (.ico, try ICOFile.readLargest(fileBytes))
            } else if fileBytes.starts(with: icnsSignature) {
                let dimensions = try ICNSFile.largestDimensions(fileBytes)
                var preflight = budget
                try preflight.reserve(width: dimensions.width, height: dimensions.height)
                (type, image) = (.icns, try ICNSFile.readLargest(fileBytes))
            } else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
        } catch let error as FormatError {
            throw EngineError(error)
        }
        let rendered = try image.makeCGImage()
        var actual = budget
        try actual.reserve(rendered)
        budget = actual
        let frame = ImageFrame(image: rendered, duration: 0)
        return ImageDocument(url: url, contentType: type, frames: [frame])
    }
}

/// Property keys for the formats ImageIO animates.
struct AnimationKeys {
    let dictionary: CFString
    let unclampedDelay: CFString
    let delay: CFString
    let loopCount: CFString

    init?(type: UTType) {
        if type.conforms(to: .gif) {
            self.init(
                kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                kCGImagePropertyGIFLoopCount)
        } else if type.conforms(to: .png) {
            self.init(
                kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime,
                kCGImagePropertyAPNGLoopCount)
        } else if type.conforms(to: .webP) {
            self.init(
                kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime,
                kCGImagePropertyWebPLoopCount)
        } else if type.conforms(to: .heics) {
            self.init(
                kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime,
                kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSLoopCount)
        } else {
            return nil
        }
    }

    private init(_ dictionary: CFString, _ unclampedDelay: CFString, _ delay: CFString, _ loopCount: CFString) {
        self.dictionary = dictionary
        self.unclampedDelay = unclampedDelay
        self.delay = delay
        self.loopCount = loopCount
    }

    func delay(in properties: [CFString: Any]) -> Double? {
        let values = properties[dictionary] as? [CFString: Any]
        return values?[unclampedDelay] as? Double ?? values?[delay] as? Double
    }

    func loopCount(in properties: [CFString: Any]) -> Int? {
        (properties[dictionary] as? [CFString: Any])?[loopCount] as? Int
    }
}
