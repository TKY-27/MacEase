import CoreGraphics
import Formats
import Foundation
import UniformTypeIdentifiers

extension ImageSettings {
    func quality(for format: ImageFormat) -> Double {
        switch format {
        case .jpeg: Double(jpegQuality)
        case .heic: Double(heicQuality)
        case .webp: Double(webpQuality)
        case .avif: Double(avifQuality)
        case .jxl: Double(jxlQuality)
        default: ImageEncoder.maximumQuality
        }
    }
}

/// Shared decode, frame selection, encode and staging.
enum ImageOutput {
    static func defaultOptions(for document: ImageDocument, format: ImageFormat, settings: ImageSettings)
        -> EncodeOptions
    {
        var options = EncodeOptions(quality: settings.quality(for: format))
        options.loops = document.loops
        options.metadata = document.metadata
        options.dithering = settings.gifDithering
        options.pixelsPerInch = document.pixelsPerInch
        return options
    }

    /// Warns about frames `format` drops.
    static func frames(of document: ImageDocument, for format: ImageFormat, context: ItemContext) -> [ImageFrame] {
        if document.isAnimated, document.contentType.conforms(to: .heics), format == .heic {
            return document.frames
        }
        if document.isAnimated, !format.holdsAnimation {
            context.warn(.firstFrameOnly)
            return [document.frames[0]]
        }
        if document.isMultiPage, ![.tiff, .pdf].contains(format) {
            context.warn(.firstPageOnly)
            return [document.frames[0]]
        }
        return document.frames
    }

    static func outputName(for document: ImageDocument, format: ImageFormat) -> String {
        let name = document.url.lastPathComponent
        guard format != document.format else { return name }
        return (name as NSString).deletingPathExtension + "." + format.fileExtension
    }

    static func check(for format: ImageFormat) -> OutputCheck {
        switch format {
        case .svg: .svg
        case .pdf: .pdf
        default: .image
        }
    }

    static func stage(
        _ data: Data, for document: ImageDocument, as format: ImageFormat, derived: Bool = false,
        context: ItemContext
    ) throws -> ItemResult {
        let name = outputName(for: document, format: format)
        let staged = try context.stagingURL(for: document.url, name: name)
        try data.write(to: staged)
        let file = StagedFile(url: staged, name: name, check: check(for: format))
        if derived || document.format == nil { return .derived(nextTo: document.url, outputs: [file]) }
        return .replace(original: document.url, output: file)
    }

    /// Transforms every kept frame, then encodes.
    static func transformed(
        _ document: ImageDocument, as format: ImageFormat, keepsGainMap: Bool, context: ItemContext,
        adjust: (inout EncodeOptions) -> Void = { _ in },
        _ transform: (CGImage) async throws -> CGImage
    ) async throws -> ItemResult {
        var frames = frames(of: document, for: format, context: context)
        var retainedBudget = FrameMemoryBudget()
        for frame in document.frames { try retainedBudget.reserve(frame.image) }
        for index in frames.indices {
            try Task.checkCancellation()
            frames[index].image = try await transform(frames[index].image)
            try retainedBudget.reserve(frames[index].image)
            context.progress(Double(index + 1) / Double(frames.count + 1))
        }
        var options = defaultOptions(for: document, format: format, settings: context.settings.image)
        options.gainMap = keepsGainMap ? document.gainMap : nil
        adjust(&options)
        return try stage(
            ImageEncoder.encode(frames, as: format, options: options), for: document, as: format, context: context)
    }
}

/// Geometry edits and conversion.
enum ImageEdits {
    /// Per-channel distance from the corner color.
    static let borderTolerance = 16

    static func resize(_ url: URL, _ resize: ImageResize, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let (width, height) = targetSize(of: document.first, resize.size)
        let grows = width > document.first.width || height > document.first.height
        if grows, !resize.allowsUpscale { return .skipped(.noUpscale) }
        let format = document.writableFormat
        return try await ImageOutput.transformed(document, as: format, keepsGainMap: true, context: context) {
            try ImagePixels.scaled($0, width: width, height: height)
        }
    }

    static func targetSize(of image: CGImage, _ size: ImageSize) -> (width: Int, height: Int) {
        let width = Double(image.width)
        let height = Double(image.height)
        let scale: Double
        switch size {
        case .percent(let percent): scale = percent / 100
        case .width(let target): scale = Double(target) / width
        case .height(let target): scale = Double(target) / height
        case .fit(let boxWidth, let boxHeight): scale = min(Double(boxWidth) / width, Double(boxHeight) / height)
        case .longEdge(let edge): scale = Double(edge) / max(width, height)
        case .exact(let targetWidth, let targetHeight): return (max(1, targetWidth), max(1, targetHeight))
        }
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    static func convert(_ url: URL, _ conversion: ImageConversion, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        if conversion.format == document.format { return .skipped(.alreadyDone) }
        var frames = ImageOutput.frames(of: document, for: conversion.format, context: context)
        if conversion.format == .gif, frames.count == 1 { frames[0].duration = 0 }
        var options = ImageOutput.defaultOptions(
            for: document, format: conversion.format, settings: context.settings.image)
        options.quality = conversion.quality.map(Double.init) ?? options.quality
        options.svgColors = conversion.svgColors
        options.optimizesPNG = context.settings.image.optimizePNGOnConvert
        options.gainMap = document.gainMap
        let data = try ImageEncoder.encode(frames, as: conversion.format, options: options)
        return try ImageOutput.stage(
            data, for: document, as: conversion.format, derived: document.isRaw, context: context)
    }

    static func rotate(_ url: URL, degrees: Double, fill: RGBColor?, context: ItemContext) async throws -> ItemResult {
        guard degrees.isFinite else { throw EngineError.invalidInput(.malformed("\(degrees)°")) }
        let degrees = degrees.truncatingRemainder(dividingBy: 360)
        let quarterTurns = degrees / 90
        if quarterTurns == quarterTurns.rounded(),
            let lossless = try ImageMetadata.rotateLosslessly(url, quarterTurns: Int(quarterTurns), context: context)
        {
            return lossless
        }
        let document = try await ImageDocument.load(url)
        let format = document.writableFormat
        return try await ImageOutput.transformed(document, as: format, keepsGainMap: false, context: context) {
            try ImagePixels.rotated($0, degrees: degrees, fill: fill.map(ImagePixels.color))
        }
    }

    static func flip(_ url: URL, _ axis: FlipAxis, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let format = document.writableFormat
        return try await ImageOutput.transformed(document, as: format, keepsGainMap: false, context: context) {
            try ImagePixels.flipped($0, axis)
        }
    }

    static func trimBorders(_ url: URL, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let canvas = document.first
        var content = CGRect.null
        for frame in document.frames {
            try Task.checkCancellation()
            if let bounds = contentBounds(of: try PixelBuffer(cgImage: frame.image)) {
                content = content.union(bounds)
            }
        }
        guard !content.isNull,
            content.width < Double(canvas.width) || content.height < Double(canvas.height)
        else { return .skipped(.nothingToRemove) }
        let format = document.writableFormat
        return try await ImageOutput.transformed(document, as: format, keepsGainMap: false, context: context) { image in
            let page = content.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return page.isEmpty ? image : try ImagePixels.cropped(image, to: page)
        }
    }

    /// `nil` when every pixel matches the corner.
    static func contentBounds(of pixels: PixelBuffer) -> CGRect? {
        let corner = Array(pixels.rgba[0..<4])
        var minX = pixels.width
        var minY = pixels.height
        var maxX = -1
        var maxY = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let base = (y * pixels.width + x) * 4
                let differs = (0..<4).contains { abs(Int(pixels.rgba[base + $0]) - Int(corner[$0])) > borderTolerance }
                guard differs else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
