import CoreGraphics
import Formats
import Foundation
import ImageIO

struct EncodeOptions {
    var quality: Double
    var loops = true
    var metadata: CGImageMetadata?
    var gainMaps: [ImageGainMap] = []
    var optimizesPNG = false
    /// `nil` keeps PNG lossless.
    var pngColors: Int?
    var gifColors = 256
    var dithering = Dithering.ordered
    var svgColors = SVGColors.default
    var svgMode = SVGMode.trace
    var pixelsPerInch = ImageDocument.defaultPixelsPerInch
}

/// Callers pass only frames the format keeps.
enum ImageEncoder {
    static let maximumQuality = 100.0
    static let maximumICOEdge = 256
    /// Fill behind transparency in opaque formats.
    static let opaqueBackground = RGBColor.white
    private static let maximumTracingBytes: Int64 = 100_000_000
    private static let pointsPerInch = 72.0

    static func encode(
        _ frames: [ImageFrame], as format: ImageFormat, options: EncodeOptions,
        retaining retained: [CGImage] = []
    ) throws -> Data {
        guard let first = frames.first else { throw EngineError.encodeFailed("no frames") }
        try validateWorkspace(frames, format: format, options: options, retaining: retained)
        if format == .heic, frames.count > 1 { throw EngineError.unsupportedCodec("HEICS") }
        switch format {
        case .gif:
            let gifFrames = try frames.map {
                GIFFrame(pixels: try PixelBuffer(cgImage: $0.image), duration: $0.duration)
            }
            let gifOptions = GIFOptions(colors: options.gifColors, dithering: options.dithering, loops: options.loops)
            return try GIFEncoder.encode(gifFrames, options: gifOptions)
        case .webp where frames.count > 1:
            let encoder = try WebPAnimationEncoder(
                width: first.image.width, height: first.image.height, quality: options.quality, loops: options.loops,
                xmp: xmp(options.metadata))
            for frame in frames { try encoder.add(frame.image, duration: frame.duration) }
            return try encoder.finish()
        case .webp:
            return try WebPEncoder.encode(
                PixelBuffer(cgImage: first.image), quality: options.quality, xmp: xmp(options.metadata))
        case .avif:
            return try AVIFEncoder.encode(
                PixelBuffer(cgImage: first.image), quality: options.quality, xmp: xmp(options.metadata))
        case .jxl:
            return try JXLEncoder.encode(
                PixelBuffer(cgImage: first.image), quality: options.quality, xmp: xmp(options.metadata))
        case .png where frames.count == 1:
            if let colors = options.pngColors { return try quantized(first.image, colors: colors, options: options) }
            let data = try imageIO(frames, as: format, options: options)
            return options.optimizesPNG ? try PNGOptimizer.optimize(data) : data
        case .ico:
            return try ico(first.image)
        case .icns:
            return try icns(first.image)
        case .svg:
            if options.svgMode == .embeddedPNG {
                let png = try png(first.image)
                let svg = """
                    <svg xmlns="http://www.w3.org/2000/svg" width="\(first.image.width)" height="\(first.image.height)" viewBox="0 0 \(first.image.width) \(first.image.height)"><image width="\(first.image.width)" height="\(first.image.height)" href="data:image/png;base64,\(png.base64EncodedString())"/></svg>
                    """
                return Data(svg.utf8)
            }
            let pixels = try PixelBuffer(cgImage: first.image)
            let layers = SVGTracer.trace(pixels, colors: options.svgColors)
            return Data(SVGTracer.svg(layers, width: pixels.width, height: pixels.height).utf8)
        case .pdf:
            return try pdf(frames.map { ($0.image, options.pixelsPerInch) })
        case .png, .jpeg, .heic, .tiff, .bmp:
            return try imageIO(frames, as: format, options: options)
        }
    }

    static func encodeStreaming(
        frameCount: Int, as format: ImageFormat, options: EncodeOptions, to url: URL,
        frameAt: (Int) async throws -> ImageFrame
    ) async throws {
        guard frameCount > 0 else { throw EngineError.encodeFailed("no frames") }
        if format == .heic, frameCount > 1 { throw EngineError.unsupportedCodec("HEICS") }
        let first = try await frameAt(0)
        if frameCount == 1 {
            try encode([first], as: format, options: options).write(to: url)
            return
        }
        var options = options
        if format == .png {
            options.optimizesPNG = false
            options.pngColors = nil
        }
        try validateWorkspace([first], format: format, options: options, streaming: true)
        switch format {
        case .gif:
            let gifOptions = GIFOptions(
                colors: options.gifColors, dithering: options.dithering,
                loops: options.loops, paletteScope: .perFrame)
            let encoder = try GIFEncoder.Stream(
                width: first.image.width, height: first.image.height, options: gifOptions, to: url)
            try encoder.add(GIFFrame(pixels: PixelBuffer(cgImage: first.image), duration: first.duration))
            for index in 1..<frameCount {
                try Task.checkCancellation()
                try await autoreleasepoolFrame(index, frameAt: frameAt) { frame in
                    try validateWorkspace(
                        [frame], format: format, options: options, retaining: [first.image], streaming: true)
                    try encoder.add(GIFFrame(pixels: PixelBuffer(cgImage: frame.image), duration: frame.duration))
                }
            }
            try encoder.finish()
        case .webp:
            do {
                let encoder = try WebPAnimationEncoder.Stream(
                    width: first.image.width, height: first.image.height, quality: options.quality,
                    loops: options.loops, maximumEncodedBytes: Int(ImageMemoryLimits.encodedBytes),
                    xmp: xmp(options.metadata))
                try encoder.add(first.image, duration: first.duration)
                for index in 1..<frameCount {
                    try Task.checkCancellation()
                    try await autoreleasepoolFrame(index, frameAt: frameAt) { frame in
                        try validateWorkspace(
                            [frame], format: format, options: options, retaining: [first.image], streaming: true)
                        try encoder.add(frame.image, duration: frame.duration)
                    }
                }
                try encoder.finish(to: url)
            } catch WebPAnimationEncoder.Stream.Error.encodedSizeExceeded {
                throw FrameMemoryBudget.exceeded
            }
        case .png:
            try await imageIOStreaming(
                first: first, frameCount: frameCount, as: format, options: options, to: url, frameAt: frameAt)
        default:
            throw EngineError.unsupportedCodec(format.rawValue)
        }
    }

    private static func autoreleasepoolFrame(
        _ index: Int, frameAt: (Int) async throws -> ImageFrame,
        consume: (ImageFrame) throws -> Void
    ) async throws {
        let frame = try await frameAt(index)
        try autoreleasepool { try consume(frame) }
    }

    private static func imageIOStreaming(
        first: ImageFrame, frameCount: Int, as format: ImageFormat, options: EncodeOptions, to url: URL,
        frameAt: (Int) async throws -> ImageFrame
    ) async throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, format.contentType.identifier as CFString, frameCount, nil)
        else { throw EngineError.unsupportedCodec(format.rawValue) }
        let metadata = format.holdsMetadata ? upright(options.metadata) : nil
        let animation = format.holdsAnimation ? AnimationKeys(type: format.contentType) : nil
        if let animation {
            CGImageDestinationSetProperties(
                destination, [animation.dictionary: [animation.loopCount: options.loops ? 0 : 1]] as CFDictionary)
        }
        func add(_ frame: ImageFrame) throws {
            try validateWorkspace(
                [frame], format: format, options: options, retaining: [first.image], streaming: true)
            var settings: [CFString: Any] = [:]
            if let animation {
                let duration = try imageIODuration(frame.duration, format: format)
                settings[animation.dictionary] = [
                    animation.delay: duration, animation.unclampedDelay: duration,
                ]
            }
            CGImageDestinationAddImageAndMetadata(destination, frame.image, metadata, settings as CFDictionary)
        }
        try add(first)
        for index in 1..<frameCount {
            try Task.checkCancellation()
            try await autoreleasepoolFrame(index, frameAt: frameAt, consume: add)
        }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed(format.rawValue) }
    }

    private static func imageIODuration(_ duration: Double, format: ImageFormat) throws -> Double {
        guard duration.isFinite, duration >= 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
        guard format == .png, duration > 0 else { return duration }
        // ImageIO truncates decoded Float delays.
        let rounded = Float(duration).nextUp
        guard rounded.isFinite else { throw EngineError.invalidInput(.invalidNumericParameter) }
        return Double(rounded)
    }

    static func validateWorkspace(
        _ frames: [ImageFrame], format: ImageFormat, options: EncodeOptions, retaining retained: [CGImage] = [],
        streaming: Bool = false
    ) throws {
        if format == .svg, options.svgMode == .trace {
            var tracingBudget = FrameMemoryBudget(limitBytes: maximumTracingBytes)
            for frame in frames {
                try tracingBudget.reserve(width: frame.image.width, height: frame.image.height)
            }
        }
        let pixelCopies: Int64
        switch format {
        case .png where options.optimizesPNG && options.pngColors == nil:
            pixelCopies = 6
        case .avif: pixelCopies = 4
        case .svg where options.svgMode == .embeddedPNG: pixelCopies = 7
        case .webp, .jxl, .svg: pixelCopies = 3
        case .gif: pixelCopies = 3
        case .png where options.pngColors != nil: pixelCopies = 3
        default: pixelCopies = format.holdsAlpha ? 1 : 2
        }
        var budget = FrameMemoryBudget()
        var seen = Set<ObjectIdentifier>()
        for image in retained + frames.map(\.image) where seen.insert(ObjectIdentifier(image)).inserted {
            try budget.reserve(image)
        }
        if [.jpeg, .heic].contains(format) {
            for gainMap in options.gainMaps {
                guard let contents = gainMap.payload as? [CFString: Any],
                    let pixels = contents[kCGImageAuxiliaryDataInfoData] as? Data
                else { throw EngineError.imageGainMapUnsupported }
                try budget.reserve(width: pixels.count, height: 1, bytesPerPixel: 1)
            }
        }
        let streamCopies: Int64 = streaming && format == .gif ? 2 : streaming && format == .webp ? 1 : 0
        for frame in frames {
            try budget.reserve(
                width: frame.image.width, height: frame.image.height,
                bytesPerPixel: frame.image.bitsPerComponent > 8 ? 8 : 4,
                frameCount: pixelCopies + streamCopies)
        }
    }

    static func xmp(_ metadata: CGImageMetadata?) -> Data? {
        upright(metadata).flatMap { CGImageMetadataCreateXMPData($0, nil) as Data? }
    }

    private static func quantized(_ image: CGImage, colors: Int, options: EncodeOptions) throws -> Data {
        let pixels = try PixelBuffer(cgImage: image)
        let profile = pixels.colorSpace.name == PixelBuffer.sRGB.name ? nil : pixels.colorSpace.copyICCData() as Data?
        let chunks = try PNGFile.metadataChunks(iccProfile: profile, xmp: xmp(options.metadata))
        return try PNGQuantizer.encode(pixels, colors: colors, dithering: options.dithering, ancillary: chunks)
    }

    /// ImageIO's own flattening color is undefined.
    static func flattened(_ image: CGImage) throws -> CGImage {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return image }
        return try ImagePixels.draw(
            width: image.width, height: image.height, like: image, fill: ImagePixels.color(opaqueBackground)
        ) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// Decoded pixels are already upright.
    static func upright(_ metadata: CGImageMetadata?) -> CGImageMetadata? {
        guard let metadata, let copy = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        CGImageMetadataSetValueMatchingImageProperty(
            copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        return copy
    }

    private static func imageIO(_ frames: [ImageFrame], as format: ImageFormat, options: EncodeOptions) throws
        -> Data
    {
        let animated = frames.count > 1 && format.holdsAnimation
        let data = NSMutableData()
        let type = format.contentType.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, frames.count, nil)
        else { throw EngineError.unsupportedCodec(format.rawValue) }
        var settings: [CFString: Any] = [:]
        if format.usesQuality {
            settings[kCGImageDestinationLossyCompressionQuality] = options.quality / maximumQuality
        }
        if animated, let keys = AnimationKeys(type: format.contentType) {
            let metadata = format.holdsMetadata ? upright(options.metadata) : nil
            CGImageDestinationSetProperties(
                destination, [keys.dictionary: [keys.loopCount: options.loops ? 0 : 1]] as CFDictionary)
            for frame in frames {
                var frameSettings = settings
                let duration = try imageIODuration(frame.duration, format: format)
                frameSettings[keys.dictionary] = [keys.delay: duration, keys.unclampedDelay: duration]
                CGImageDestinationAddImageAndMetadata(destination, frame.image, metadata, frameSettings as CFDictionary)
            }
        } else {
            let metadata = format.holdsMetadata ? upright(options.metadata) : nil
            for frame in frames {
                let image = format.holdsAlpha ? frame.image : try flattened(frame.image)
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, settings as CFDictionary)
            }
            if [.jpeg, .heic].contains(format) {
                for gainMap in options.gainMaps {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, gainMap.type, gainMap.payload)
                }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed(format.rawValue) }
        if [.jpeg, .heic].contains(format), !options.gainMaps.isEmpty {
            guard let source = CGImageSourceCreateWithData(data, nil) else {
                throw EngineError.imageGainMapUnsupported
            }
            try ImageGainMap.verify(options.gainMaps, in: source)
        }
        return data as Data
    }

    static func png(_ image: CGImage) throws -> Data {
        try imageIO([ImageFrame(image: image, duration: 0)], as: .png, options: EncodeOptions(quality: maximumQuality))
    }

    /// Transparent padding makes non-square inputs square.
    static func square(_ image: CGImage) throws -> CGImage {
        guard image.width != image.height else { return image }
        let edge = max(image.width, image.height)
        return try ImagePixels.padded(image, width: edge, height: edge, fill: nil)
    }

    private static func ico(_ image: CGImage) throws -> Data {
        let square = try square(image)
        let edge = min(square.width, maximumICOEdge)
        let sizes = ICOFile.standardSizes.filter { $0 <= edge }
        let entries = try (sizes.isEmpty ? [ICOFile.standardSizes[0]] : sizes).map { size in
            (size: size, png: try png(ImagePixels.scaled(square, width: size, height: size)))
        }
        return try ICOFile.write(entries)
    }

    private static func icns(_ image: CGImage) throws -> Data {
        let square = try square(image)
        var pngBySize: [Int: Data] = [:]
        for size in Set(ICNSFile.pngElements.map(\.size)) {
            pngBySize[size] = try png(ImagePixels.scaled(square, width: size, height: size))
        }
        return try ICNSFile.write(pngBySize: pngBySize)
    }

    static func pdf(_ pages: [(image: CGImage, pixelsPerInch: Double)]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw EngineError.encodeFailed("PDF context") }
        for (page, pixelsPerInch) in pages {
            let scale = pointsPerInch / max(pixelsPerInch, 1)
            var box = CGRect(x: 0, y: 0, width: Double(page.width) * scale, height: Double(page.height) * scale)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(page, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
