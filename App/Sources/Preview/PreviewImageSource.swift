import CoreGraphics
import Foundation
import ImageIO

struct PreviewImageTiming: Sendable, Equatable {
    struct Position: Equatable {
        let index: Int
        let completedPlays: Int
    }

    let delays: [Double]
    // nil plays forever.
    let plays: Int?

    // nil once the last play has ended.
    func step(after position: Position) -> Position? {
        let next = (position.index + 1) % delays.count
        let completed = position.completedPlays + (next == 0 ? 1 : 0)
        if let plays, completed >= plays { return nil }
        return Position(index: next, completedPlays: completed)
    }
}

struct PreviewImageOpened: Sendable {
    let first: CGImage
    let pixelSize: CGSize
    let hasAlpha: Bool
    let info: PreviewImageInfo
    let animation: PreviewImageTiming?
    let offersFullResolution: Bool

    var decodedScale: Double { Double(first.width) / pixelSize.width }
}

actor PreviewImageSource {
    // Bounds decode memory; larger images preview downscaled.
    static let maximumPreviewEdge = 4096
    static let fullResolutionByteLimit = 256 << 20
    static let frameCacheByteLimit = 64 << 20
    private static let defaultDelay = 0.1
    private static let minimumDelay = 0.02
    private static let rotatedOrientations = 5...8

    private let frameCacheLimit: Int
    private var source: CGImageSource?
    private var decodeEdge = 0
    private var fullEdge = 0
    private var cachesFrames = false
    private var frames: [Int: CGImage] = [:]
    private(set) var cachedBytes = 0

    init(frameCacheLimit: Int = PreviewImageSource.frameCacheByteLimit) {
        self.frameCacheLimit = frameCacheLimit
    }

    func open(_ url: URL) throws -> PreviewImageOpened {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        self.source = source
        fullEdge = max(width, height)
        decodeEdge = min(fullEdge, Self.maximumPreviewEdge)
        let rotated = (properties[kCGImagePropertyOrientation] as? Int).map(Self.rotatedOrientations.contains) == true
        let pixelSize = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let first = try decode(0, edge: decodeEdge)
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let frameCount = CGImageSourceGetCount(source)
        let animation = frameCount > 1 ? try timing(container, frameCount: frameCount) : nil
        if animation != nil {
            cachesFrames = first.bytesPerRow * first.height * frameCount <= frameCacheLimit
            store(first, at: 0)
        }
        let fullBytes = Double(width * height) * Double(first.bitsPerPixel) / 8
        return PreviewImageOpened(
            first: first, pixelSize: pixelSize, hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            info: PreviewImageInfo(properties: properties, pixelSize: pixelSize, headroom: first.contentHeadroom),
            animation: animation,
            offersFullResolution: animation == nil && fullEdge > decodeEdge
                && fullBytes <= Double(Self.fullResolutionByteLimit))
    }

    func frame(_ index: Int) throws -> CGImage {
        if let cached = frames[index] { return cached }
        let decoded = try decode(index, edge: decodeEdge)
        store(decoded, at: index)
        return decoded
    }

    func fullResolution() throws -> CGImage {
        try decode(0, edge: fullEdge)
    }

    private func store(_ image: CGImage, at index: Int) {
        guard cachesFrames else { return }
        frames[index] = image
        cachedBytes += image.bytesPerRow * image.height
    }

    private func decode(_ index: Int, edge: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let source,
            let pixels = CGImageSourceCreateThumbnailAtIndex(
                source, index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                    kCGImageSourceThumbnailMaxPixelSize: edge,
                ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return pixels
    }

    private func timing(_ container: [CFString: Any], frameCount: Int) throws -> PreviewImageTiming {
        guard let source else { throw CocoaError(.fileReadCorruptFile) }
        let delays = (0..<frameCount).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            return Self.delay(properties)
        }
        return PreviewImageTiming(delays: delays, plays: Self.plays(container))
    }

    private static var formats: [(dictionary: CFString, loopCount: CFString, unclamped: CFString, clamped: CFString)] {
        [
            (
                kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount, kCGImagePropertyGIFUnclampedDelayTime,
                kCGImagePropertyGIFDelayTime
            ),
            (
                kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount, kCGImagePropertyAPNGUnclampedDelayTime,
                kCGImagePropertyAPNGDelayTime
            ),
            (
                kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount, kCGImagePropertyWebPUnclampedDelayTime,
                kCGImagePropertyWebPDelayTime
            ),
        ]
    }

    private static func delay(_ properties: [CFString: Any]) -> Double {
        for format in formats {
            if let animation = properties[format.dictionary] as? [CFString: Any],
                let duration = (animation[format.unclamped] ?? animation[format.clamped]) as? Double, duration.isFinite
            {
                return max(minimumDelay, duration)
            }
        }
        return defaultDelay
    }

    // ImageIO counts plays; 0 means forever.
    static func plays(_ container: [CFString: Any]) -> Int? {
        for format in formats {
            guard let animation = container[format.dictionary] as? [CFString: Any] else { continue }
            guard let count = animation[format.loopCount] as? Int else { return 1 }
            return count == 0 ? nil : count
        }
        return 1
    }
}
