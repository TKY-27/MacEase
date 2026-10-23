import CoreGraphics
import Formats
import Foundation

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
        options.loopCount = document.loopCount
        options.metadata = document.metadata
        options.gainMaps = [.jpeg, .heic].contains(format) ? document.gainMaps : []
        options.dithering = settings.gifDithering
        options.svgMode = settings.svgMode
        options.pixelsPerInch = document.pixelsPerInch
        options.opaqueBackground = settings.customBackground
        return options
    }

    static func prepared(
        _ document: ImageDocument, as format: ImageFormat, context: ItemContext,
        derived: Bool = false, preservesGainMaps: Bool = true, preservesHDRPixels: Bool = false,
        strippingMetadata: Bool = false
    ) throws -> ImageDocument {
        _ = try keptFrameCount(of: document, for: format)
        let keepsOriginal =
            derived || document.format == nil || format == .pdf
            || context.settings.outputMode == .newFile
        if !format.holdsMetadata, !strippingMetadata {
            let fields = try document.metadataFields()
            if !fields.isEmpty {
                guard keepsOriginal else { throw EngineError.imageMetadataUnsupported(fields) }
                let warning = ItemWarning.imageMetadataDropped(fields)
                if !context.warnings.contains(warning) { context.warn(warning) }
            }
        }
        var flattensTransparency = false
        if !format.holdsAlpha || format == .gif || format == .svg && context.settings.image.svgMode == .trace {
            for index in 0..<document.frameCount {
                try Task.checkCancellation()
                let losesAlpha = try autoreleasepool {
                    let frame = try document.frame(at: index)
                    return try validateTransparency(
                        frame.image, as: format, keepsOriginal: keepsOriginal, context: context)
                }
                flattensTransparency = flattensTransparency || losesAlpha
            }
        }
        let keepsMaps =
            preservesGainMaps && !flattensTransparency && [.jpeg, .heic].contains(format)
            && !document.isAnimated && !document.isMultiPage
        let losesHDR =
            document.containsHDRPixels
            ? !preservesHDRPixels || !document.gainMaps.isEmpty && !keepsMaps
            : document.containsHDR && !keepsMaps
        guard losesHDR else { return document }
        guard keepsOriginal else { throw EngineError.imageHDRUnsupported }
        let converted = try document.toneMappedToSDR()
        if !context.warnings.contains(.imageToneMappedToSDR) { context.warn(.imageToneMappedToSDR) }
        return converted
    }

    static func toneMappedAfterGainMapFailure(_ document: ImageDocument, context: ItemContext) throws
        -> ImageDocument
    {
        guard !document.gainMaps.isEmpty else { throw EngineError.imageGainMapUnsupported }
        guard context.settings.outputMode == .newFile else { throw EngineError.imageHDRUnsupported }
        let converted = try document.toneMappedToSDR()
        if !context.warnings.contains(.imageToneMappedToSDR) { context.warn(.imageToneMappedToSDR) }
        return converted
    }

    @discardableResult static func validateTransparency(
        _ image: CGImage, as format: ImageFormat, keepsOriginal: Bool, context: ItemContext
    ) throws -> Bool {
        let binaryAlpha = format == .gif || format == .svg && context.settings.image.svgMode == .trace
        guard !format.holdsAlpha || binaryAlpha,
            try ImageEncoder.hasTransparency(image, partialOnly: binaryAlpha)
        else { return false }
        guard keepsOriginal else { throw EngineError.imageTransparencyUnsupported }
        let warning = ItemWarning.imageTransparencyFlattened
        if !context.warnings.contains(warning) { context.warn(warning) }
        return true
    }

    static func keptFrameCount(of document: ImageDocument, for format: ImageFormat) throws -> Int {
        if document.isAnimated, !format.holdsAnimation {
            throw EngineError.imageSequenceUnsupported
        }
        if document.isMultiPage, ![.tiff, .pdf].contains(format) {
            throw EngineError.imageSequenceUnsupported
        }
        if document.isAnimated, let loopCount = document.loopCount {
            let maximum = format == .png ? Int(UInt32.max) : Int(UInt16.max) + (format == .gif ? 1 : 0)
            guard (0...maximum).contains(loopCount) else { throw EngineError.imageLoopCountUnsupported }
        }
        return document.frameCount
    }

    static func frames(of document: ImageDocument, for format: ImageFormat, context: ItemContext) throws
        -> [ImageFrame]
    {
        let count = try keptFrameCount(of: document, for: format)
        guard count <= document.frames.count else { throw EngineError.unsupportedCodec("streaming required") }
        return Array(document.frames.prefix(count))
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
        return self.staged(staged, for: document, as: format, derived: derived)
    }

    static func staged(_ url: URL, for document: ImageDocument, as format: ImageFormat, derived: Bool = false)
        -> ItemResult
    {
        let outputCheck: OutputCheck =
            document.toneMapsHDR && ![.pdf, .svg].contains(format)
            ? .sdrImage : check(for: format)
        let file = StagedFile(url: url, name: outputName(for: document, format: format), check: outputCheck)
        if derived || document.format == nil || format == .pdf {
            return .derived(nextTo: document.url, outputs: [file])
        }
        return .replace(original: document.url, output: file)
    }

    /// Transforms every kept frame, then encodes.
    static func transformed(
        _ document: ImageDocument, as format: ImageFormat, context: ItemContext,
        geometry: (CGImage, CGImage) -> GainMapGeometry,
        _ transform: (CGImage) async throws -> CGImage
    ) async throws -> ItemResult {
        let document = try prepared(document, as: format, context: context)
        do {
            return try await transformedPrepared(document, as: format, context: context, geometry: geometry, transform)
        } catch EngineError.imageGainMapUnsupported {
            let converted = try toneMappedAfterGainMapFailure(document, context: context)
            return try await transformedPrepared(
                converted, as: format, context: context, geometry: geometry, transform)
        }
    }

    private static func transformedPrepared(
        _ document: ImageDocument, as format: ImageFormat, context: ItemContext,
        geometry: (CGImage, CGImage) -> GainMapGeometry,
        _ transform: (CGImage) async throws -> CGImage
    ) async throws -> ItemResult {
        if document.isAnimated {
            let count = try keptFrameCount(of: document, for: format)
            let options = defaultOptions(for: document, format: format, settings: context.settings.image)
            guard options.gainMaps.isEmpty else { throw EngineError.imageGainMapUnsupported }
            let staged = try context.stagingURL(for: document.url, name: outputName(for: document, format: format))
            try await ImageEncoder.encodeStreaming(frameCount: count, as: format, options: options, to: staged) {
                index in
                let frame = try document.frame(at: index)
                let image = try await transform(frame.image)
                try validateTransparency(
                    image, as: format,
                    keepsOriginal: context.settings.outputMode == .newFile, context: context)
                context.progress(Double(index + 1) / Double(count + 1))
                return ImageFrame(image: image, duration: frame.duration)
            }
            return self.staged(staged, for: document, as: format)
        }
        var frames = try frames(of: document, for: format, context: context)
        var retainedBudget = FrameMemoryBudget()
        for frame in document.frames { try retainedBudget.reserve(frame.image) }
        for index in frames.indices {
            try Task.checkCancellation()
            frames[index].image = try await transform(frames[index].image)
            if !format.holdsAlpha || format == .gif || format == .svg && context.settings.image.svgMode == .trace {
                try validateTransparency(
                    frames[index].image, as: format,
                    keepsOriginal: document.format == nil || context.settings.outputMode == .newFile,
                    context: context)
            }
            try retainedBudget.reserve(frames[index].image)
            context.progress(Double(index + 1) / Double(frames.count + 1))
        }
        var options = defaultOptions(for: document, format: format, settings: context.settings.image)
        options.gainMaps = try options.gainMaps.map {
            try $0.applying(geometry(document.first, frames[0].image))
        }
        return try stage(
            ImageEncoder.encode(frames, as: format, options: options, retaining: document.frames.map(\.image)),
            for: document, as: format, context: context)
    }
}

/// Geometry edits and conversion.
enum ImageEdits {
    /// Per-channel distance from the corner color.
    static let borderTolerance = 16

    static func resize(_ url: URL, _ resize: ImageResize, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let (width, height) = try targetSize(of: document.first, resize.size)
        let grows = width > document.first.width || height > document.first.height
        if grows, !resize.allowsUpscale { return .skipped(.noUpscale) }
        let format = document.writableFormat
        return try await ImageOutput.transformed(
            document, as: format, context: context, geometry: GainMapGeometry.resize
        ) {
            image in
            try autoreleasepool { try ImagePixels.scaled(image, width: width, height: height) }
        }
    }

    static func targetSize(of image: CGImage, _ size: ImageSize) throws -> (width: Int, height: Int) {
        let width = Double(image.width)
        let height = Double(image.height)
        let scale: Double
        switch size {
        case .percent(let percent): scale = percent / 100
        case .width(let target): scale = Double(target) / width
        case .height(let target): scale = Double(target) / height
        case .fit(let boxWidth, let boxHeight): scale = min(Double(boxWidth) / width, Double(boxHeight) / height)
        case .longEdge(let edge): scale = Double(edge) / max(width, height)
        case .exact(let targetWidth, let targetHeight):
            guard targetWidth > 0, targetHeight > 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
            return (targetWidth, targetHeight)
        }
        guard scale.isFinite, scale > 0,
            let targetWidth = Int(exactly: (width * scale).rounded()),
            let targetHeight = Int(exactly: (height * scale).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        return (max(1, targetWidth), max(1, targetHeight))
    }

    static func convert(_ url: URL, _ conversion: ImageConversion, context: ItemContext) async throws -> ItemResult {
        var document = try await ImageDocument.load(url)
        if document.contentType.identifier == "com.adobe.photoshop-image" {
            guard [.png, .jpeg, .tiff].contains(conversion.format) else {
                throw EngineError.unsupportedCodec("PSD composite target")
            }
            context.warn(.imageFlattened)
        }
        if conversion.format == document.format { return .skipped(.alreadyDone) }
        document = try ImageOutput.prepared(
            document, as: conversion.format, context: context,
            preservesHDRPixels: [.png, .tiff].contains(conversion.format))
        do {
            return try await convertPrepared(document, conversion, context: context)
        } catch EngineError.imageGainMapUnsupported {
            let converted = try ImageOutput.toneMappedAfterGainMapFailure(document, context: context)
            return try await convertPrepared(converted, conversion, context: context)
        }
    }

    private static func convertPrepared(_ document: ImageDocument, _ conversion: ImageConversion, context: ItemContext)
        async throws -> ItemResult
    {
        let count = try ImageOutput.keptFrameCount(of: document, for: conversion.format)
        var options = ImageOutput.defaultOptions(
            for: document, format: conversion.format, settings: context.settings.image)
        options.quality = conversion.quality.map(Double.init) ?? options.quality
        options.svgColors = conversion.svgColors
        options.svgMode = context.settings.image.svgMode
        options.optimizesPNG = context.settings.image.optimizePNGOnConvert
        if document.isAnimated, count > 1 {
            let staged = try context.stagingURL(
                for: document.url, name: ImageOutput.outputName(for: document, format: conversion.format))
            try await ImageEncoder.encodeStreaming(
                frameCount: count, as: conversion.format, options: options, to: staged
            ) { index in
                let frame = try document.frame(at: index)
                context.progress(Double(index + 1) / Double(count + 1))
                return frame
            }
            return ImageOutput.staged(staged, for: document, as: conversion.format, derived: document.isRaw)
        }
        var frames = Array(document.frames.prefix(count))
        if conversion.format == .gif, frames.count == 1 { frames[0].duration = 0 }
        let retained = document.frames.map(\.image)
        if conversion.format == .png, options.optimizesPNG {
            do {
                try ImageEncoder.validateWorkspace(frames, format: .png, options: options, retaining: retained)
            } catch EngineError.invalidInput(.frameMemoryExceeded) {
                options.optimizesPNG = false
                try ImageEncoder.validateWorkspace(frames, format: .png, options: options, retaining: retained)
                context.warn(.pngOptimizationSkipped)
            }
        }
        let data = try ImageEncoder.encode(frames, as: conversion.format, options: options, retaining: retained)
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
        let loaded = try await ImageDocument.load(url)
        let format = loaded.writableFormat
        let document = try ImageOutput.prepared(
            loaded, as: format, context: context, preservesGainMaps: quarterTurns == quarterTurns.rounded())
        return try await ImageOutput.transformed(
            document, as: format, context: context,
            geometry: { source, output in
                GainMapGeometry.rotation(source, to: output, degrees: degrees)
            }
        ) {
            image in
            try autoreleasepool {
                try ImagePixels.rotated(
                    image, degrees: degrees,
                    fill: (fill ?? (format.holdsAlpha ? nil : context.settings.image.customBackground))
                        .map(ImagePixels.color))
            }
        }
    }

    static func flip(_ url: URL, _ axis: FlipAxis, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let format = document.writableFormat
        return try await ImageOutput.transformed(
            document, as: format, context: context,
            geometry: { source, _ in
                GainMapGeometry.orientation(
                    CGSize(width: source.width, height: source.height),
                    axis == .horizontal ? .upMirrored : .downMirrored)
            }
        ) {
            image in
            try autoreleasepool { try ImagePixels.flipped(image, axis) }
        }
    }

    static func trimBorders(_ url: URL, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let canvas = document.first
        var retained = FrameMemoryBudget()
        for frame in document.frames { try retained.reserve(frame.image) }
        var content = CGRect.null
        for index in 0..<document.frameCount {
            try Task.checkCancellation()
            let bounds = try autoreleasepool { () throws -> CGRect? in
                let frame = try document.frame(at: index)
                var frameWorkspace = retained
                if document.isAnimated && index > 0 { try frameWorkspace.reserve(frame.image) }
                try frameWorkspace.reserve(width: frame.image.width, height: frame.image.height, frameCount: 2)
                return contentBounds(of: try PixelBuffer(cgImage: frame.image))
            }
            if let bounds { content = content.union(bounds) }
        }
        guard !content.isNull,
            content.width < Double(canvas.width) || content.height < Double(canvas.height)
        else { return .skipped(.nothingToRemove) }
        let format = document.writableFormat
        return try await ImageOutput.transformed(
            document, as: format, context: context,
            geometry: { source, _ in
                GainMapGeometry.crop(source, to: content)
            }
        ) { image in
            try autoreleasepool {
                let page = content.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return page.isEmpty ? image : try ImagePixels.cropped(image, to: page)
            }
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
