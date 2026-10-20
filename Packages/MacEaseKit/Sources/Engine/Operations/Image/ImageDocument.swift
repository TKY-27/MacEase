import CoreImage
import Formats
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageFrame {
    var image: CGImage
    /// Seconds; zero for stills and pages.
    var duration: Double
}

/// Frames are already oriented for display.
struct ImageDocument {
    let url: URL
    let contentType: UTType
    /// `nil` for RAW and vector sources.
    let format: ImageFormat?
    var frames: [ImageFrame]
    let isAnimated: Bool
    let loops: Bool
    let metadata: CGImageMetadata?
    let gainMap: CFDictionary?
    let pixelsPerInch: Double

    static let defaultPixelsPerInch = 72.0

    var first: CGImage { frames[0].image }
    var isRaw: Bool { contentType.conforms(to: .rawImage) }
    var isMultiPage: Bool { !isAnimated && frames.count > 1 }

    /// Derived outputs for RAW and vector sources.
    var writableFormat: ImageFormat {
        format ?? ([.none, .noneSkipFirst, .noneSkipLast].contains(first.alphaInfo) ? .jpeg : .png)
    }

    init(
        url: URL, contentType: UTType, frames: [ImageFrame], isAnimated: Bool = false, loops: Bool = true,
        metadata: CGImageMetadata? = nil, gainMap: CFDictionary? = nil,
        pixelsPerInch: Double = ImageDocument.defaultPixelsPerInch
    ) {
        self.url = url
        self.contentType = contentType
        self.format = contentType.conforms(to: .svg) ? nil : ImageFormat(contentType: contentType)
        self.frames = frames
        self.isAnimated = isAnimated
        self.loops = loops
        self.metadata = metadata
        self.gainMap = gainMap
        self.pixelsPerInch = pixelsPerInch
    }

    static func load(_ url: URL) async throws -> ImageDocument {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions), CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
        {
            do {
                return try decode(source, type: type, url: url)
            } catch EngineError.decodeFailed where type.conforms(to: .ico) || type.conforms(to: .icns) {
                return try decodeIcon(try Data(contentsOf: url), url: url)
            }
        }
        let data = try Data(contentsOf: url)
        if SVGRenderer.isSVG(data) {
            let image = try await SVGRenderer.render(data)
            return ImageDocument(url: url, contentType: .svg, frames: [ImageFrame(image: image, duration: 0)])
        }
        return try decodeIcon(data, url: url)
    }

    private static func decode(_ source: CGImageSource, type: UTType, url: URL) throws -> ImageDocument {
        let count = CGImageSourceGetCount(source)
        var frameBudget = FrameMemoryBudget()
        try frameBudget.reserve(width: 1, height: 1, frameCount: Int64(count))
        let animation = AnimationKeys(type: type)
        let isAnimated = count > 1 && animation != nil
        let indices: [Int]
        if isAnimated || type.conforms(to: .tiff) && !type.conforms(to: .rawImage) {
            indices = Array(0..<count)
        } else if type.conforms(to: .ico) || type.conforms(to: .icns) {
            indices = [largestIndex(in: source)]
        } else {
            indices = [CGImageSourceGetPrimaryImageIndex(source)]
        }
        var pixelBudget = FrameMemoryBudget()
        for index in indices {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { throw EngineError.decodeFailed(url.lastPathComponent) }
            let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
            let componentBytes = depth > 16 ? 4 : depth > 8 ? 2 : 1
            try pixelBudget.reserve(width: width, height: height, bytesPerPixel: 4 * componentBytes)
        }
        let frames = try indices.map { index in
            guard let raw = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let orientation =
                (properties[kCGImagePropertyOrientation] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
            return ImageFrame(
                image: try ImagePixels.oriented(raw, orientation),
                duration: isAnimated ? animation?.delay(in: properties) ?? 0 : 0)
        }
        let primary = indices[0]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, nil) as? [CFString: Any] ?? [:]
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        return ImageDocument(
            url: url, contentType: type, frames: frames, isAnimated: isAnimated,
            loops: animation?.loopCount(in: container).map { $0 == 0 } ?? true,
            metadata: CGImageSourceCopyMetadataAtIndex(source, primary, nil),
            gainMap: CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, primary, kCGImageAuxiliaryDataTypeISOGainMap),
            pixelsPerInch: (properties[kCGImagePropertyDPIWidth] as? Double) ?? defaultPixelsPerInch
        )
    }

    private static func largestIndex(in source: CGImageSource) -> Int {
        (0..<CGImageSourceGetCount(source)).max { left, right in
            pixelWidth(source, left) < pixelWidth(source, right)
        } ?? 0
    }

    private static func pixelWidth(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    private static let icoSignature = Data([0, 0, 1, 0])
    private static let icnsSignature = Data("icns".utf8)

    private static func decodeIcon(_ data: Data, url: URL) throws -> ImageDocument {
        let type: UTType
        let images: [PixelBuffer]
        do {
            if data.starts(with: icoSignature) {
                (type, images) = (.ico, try ICOFile.read(data))
            } else if data.starts(with: icnsSignature) {
                (type, images) = (.icns, try ICNSFile.read(data))
            } else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
        } catch is FormatError {
            throw EngineError.decodeFailed(url.lastPathComponent)
        }
        guard let largest = images.max(by: { $0.width < $1.width }) else {
            throw EngineError.decodeFailed(url.lastPathComponent)
        }
        let frame = ImageFrame(image: try largest.makeCGImage(), duration: 0)
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
