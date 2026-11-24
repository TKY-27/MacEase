import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        guard !delays.isEmpty else { return nil }
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
    let metadata: PreviewImageInfo
    let animation: PreviewImageTiming?
    let offersFullResolution: Bool

    var decodedScale: Double { Double(first.width) / pixelSize.width }
}

actor PreviewImageSource {
    // Bounds decode memory; larger images preview downscaled.
    static let maximumPreviewEdge = 4096
    static let fullResolutionByteLimit = 256 << 20
    static let frameCacheByteLimit = 64 << 20
    static let maximumSourceEdgePixels = 65_535
    static let maximumSourcePixelCount = 500_000_000
    static let maximumAnimationFrameCount = 2_000
    static let defaultFrameDelaySeconds = 0.1
    static let minimumFrameDelaySeconds = 0.02
    static let maximumFrameDelaySeconds = 60.0
    private static let bitsPerByte = 8
    private static let rotatedOrientations = 5...8
    private static let animatedTypeIdentifiers: Set<String> = [
        UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier, "public.heics",
    ]

    private let frameCacheLimit: Int
    private let maximumFrameCount: Int
    private var fileURL: URL?
    private var source: CGImageSource?
    private var decodeEdge = 0
    private var fullEdge = 0
    private var cachesFrames = false
    private var frames: [Int: CGImage] = [:]
    private(set) var cachedBytes = 0

    init(
        frameCacheLimit: Int = PreviewImageSource.frameCacheByteLimit,
        maximumFrameCount: Int = PreviewImageSource.maximumAnimationFrameCount
    ) {
        self.frameCacheLimit = frameCacheLimit
        self.maximumFrameCount = maximumFrameCount
    }

    func open(_ url: URL) throws -> PreviewImageOpened {
        try Task.checkCancellation()
        let (openedSource, properties, width, height) = try openValidatedSource(url)
        try Task.checkCancellation()
        fileURL = url
        source = openedSource
        fullEdge = max(width, height)
        decodeEdge = min(fullEdge, Self.maximumPreviewEdge)
        let rotated = (properties[kCGImagePropertyOrientation] as? Int).map(Self.rotatedOrientations.contains) == true
        let pixelSize = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let first = try decode(openedSource, index: 0, edge: decodeEdge)
        try Task.checkCancellation()
        let container = CGImageSourceCopyProperties(openedSource, nil) as? [CFString: Any] ?? [:]
        let frameCount = CGImageSourceGetCount(openedSource)
        try Task.checkCancellation()
        let animation: PreviewImageTiming? =
            if frameCount > 1,
                Self.declaresAnimation(source: openedSource, container: container, frameProperties: properties),
                frameCount <= maximumFrameCount
            {
                try timing(container, frameCount: frameCount)
            } else {
                nil
            }
        if animation != nil {
            if let firstBytes = Self.byteCount(first.bytesPerRow, first.height),
                let estimatedBytes = Self.byteCount(firstBytes, frameCount)
            {
                cachesFrames = estimatedBytes <= frameCacheLimit
            } else {
                cachesFrames = false
            }
            store(first, at: 0)
        } else {
            // Still images release source until zoomed.
            source = nil
        }
        let fullBytes = Self.fullResolutionByteCount(width: width, height: height, bitsPerPixel: first.bitsPerPixel)
        return PreviewImageOpened(
            first: first, pixelSize: pixelSize, hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            metadata: PreviewImageInfo(properties: properties, pixelSize: pixelSize, headroom: first.contentHeadroom),
            animation: animation,
            offersFullResolution: animation == nil && fullEdge > decodeEdge
                && fullBytes.map { $0 <= Self.fullResolutionByteLimit } == true)
    }

    func frame(_ index: Int) throws -> CGImage {
        if let cached = frames[index] { return cached }
        guard let source else { throw CocoaError(.fileReadCorruptFile) }
        let decoded = try decode(source, index: index, edge: decodeEdge)
        store(decoded, at: index)
        return decoded
    }

    func fullResolution() throws -> CGImage {
        guard let fileURL else { throw CocoaError(.fileReadCorruptFile) }
        let (reopenedSource, _, _, _) = try openValidatedSource(fileURL)
        return try decode(reopenedSource, index: 0, edge: fullEdge)
    }

    func store(_ image: CGImage, at index: Int) {
        guard cachesFrames, frames[index] == nil else { return }
        guard let frameBytes = Self.byteCount(image.bytesPerRow, image.height) else { return }
        let (nextBytes, overflow) = cachedBytes.addingReportingOverflow(frameBytes)
        guard !overflow, nextBytes <= frameCacheLimit else { return }
        frames[index] = image
        cachedBytes = nextBytes
    }

    private func openValidatedSource(_ url: URL) throws -> (CGImageSource, [CFString: Any], Int, Int) {
        guard
            let imageSource = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            width <= Self.maximumSourceEdgePixels, height <= Self.maximumSourceEdgePixels,
            let pixels = Self.pixelCount(width: width, height: height),
            pixels <= Self.maximumSourcePixelCount
        else { throw CocoaError(.fileReadCorruptFile) }
        return (imageSource, properties, width, height)
    }

    private func decode(_ imageSource: CGImageSource, index: Int, edge: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard
            let pixels = CGImageSourceCreateThumbnailAtIndex(
                imageSource, index,
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
        guard let source, frameCount > 1, frameCount <= maximumFrameCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var delays: [Double] = []
        delays.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            delays.append(Self.delay(properties))
        }
        try Task.checkCancellation()
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
            (
                kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount,
                kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime
            ),
        ]
    }

    private static func declaresAnimation(
        source: CGImageSource, container: [CFString: Any], frameProperties: [CFString: Any]
    ) -> Bool {
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
            animatedTypeIdentifiers.contains(typeIdentifier)
        else { return false }
        return formats.contains { container[$0.dictionary] != nil || frameProperties[$0.dictionary] != nil }
    }

    static func pixelCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : pixels
    }

    static func byteCount(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= 0, rhs >= 0 else { return nil }
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : product
    }

    static func fullResolutionByteCount(width: Int, height: Int, bitsPerPixel: Int) -> Int? {
        guard bitsPerPixel > 0, let pixels = pixelCount(width: width, height: height) else { return nil }
        let (bits, bitOverflow) = pixels.multipliedReportingOverflow(by: bitsPerPixel)
        guard !bitOverflow else { return nil }
        let (padded, padOverflow) = bits.addingReportingOverflow(bitsPerByte - 1)
        guard !padOverflow else { return nil }
        return padded / bitsPerByte
    }

    // Sub-20 ms delays play at 100 ms.
    static func clampedDelaySeconds(_ rawSeconds: Double?) -> Double {
        guard let rawSeconds, rawSeconds.isFinite, rawSeconds >= minimumFrameDelaySeconds else {
            return defaultFrameDelaySeconds
        }
        return min(rawSeconds, maximumFrameDelaySeconds)
    }

    static func delay(_ properties: [CFString: Any]) -> Double {
        for format in formats {
            if let animation = properties[format.dictionary] as? [CFString: Any],
                let duration = (animation[format.unclamped] ?? animation[format.clamped]) as? Double
            {
                return clampedDelaySeconds(duration)
            }
        }
        return defaultFrameDelaySeconds
    }

    // ImageIO counts plays; 0 means forever.
    static func plays(_ container: [CFString: Any]) -> Int? {
        for format in formats {
            guard let animation = container[format.dictionary] as? [CFString: Any] else { continue }
            guard let count = animation[format.loopCount] as? Int else { return 1 }
            if count == 0 { return nil }
            return count > 0 ? count : 1
        }
        return 1
    }
}
