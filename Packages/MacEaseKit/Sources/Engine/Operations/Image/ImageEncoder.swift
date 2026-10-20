import CoreGraphics
import Formats
import Foundation
import ImageIO

struct EncodeOptions {
    var quality: Double
    var loops = true
    var metadata: CGImageMetadata?
    var gainMap: CFDictionary?
    var optimizesPNG = false
    /// `nil` keeps PNG lossless.
    var pngColors: Int?
    var gifColors = 256
    var dithering = Dithering.ordered
    var svgColors = SVGColors.default
    var pixelsPerInch = ImageDocument.defaultPixelsPerInch
}

/// Callers pass only frames the format keeps.
enum ImageEncoder {
    static let maximumQuality = 100.0
    static let maximumICOEdge = 256
    /// Fill behind transparency in opaque formats.
    static let opaqueBackground = RGBColor.white
    private static let pointsPerInch = 72.0

    static func encode(_ frames: [ImageFrame], as format: ImageFormat, options: EncodeOptions) throws -> Data {
        guard let first = frames.first else { throw EngineError.encodeFailed("no frames") }
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
            let pixels = try PixelBuffer(cgImage: first.image)
            let layers = SVGTracer.trace(pixels, colors: options.svgColors)
            return Data(SVGTracer.svg(layers, width: pixels.width, height: pixels.height).utf8)
        case .pdf:
            return try pdf(frames.map { ($0.image, options.pixelsPerInch) })
        case .png, .jpeg, .heic, .tiff, .bmp:
            return try imageIO(frames, as: format, options: options)
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
            CGImageDestinationSetProperties(
                destination, [keys.dictionary: [keys.loopCount: options.loops ? 0 : 1]] as CFDictionary)
            for frame in frames {
                var frameSettings = settings
                frameSettings[keys.dictionary] = [keys.delay: frame.duration, keys.unclampedDelay: frame.duration]
                CGImageDestinationAddImage(destination, frame.image, frameSettings as CFDictionary)
            }
        } else {
            let metadata = format.holdsMetadata ? upright(options.metadata) : nil
            for frame in frames {
                let image = format.holdsAlpha ? frame.image : try flattened(frame.image)
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, settings as CFDictionary)
            }
            if let gainMap = options.gainMap, [.jpeg, .heic].contains(format) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, gainMap)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed(format.rawValue) }
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
