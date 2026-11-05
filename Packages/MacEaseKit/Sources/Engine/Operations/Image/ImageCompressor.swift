import CoreGraphics
import Formats
import Foundation
import ImageIO

/// Quality presets, platform limits, target sizes.
enum ImageCompressor {
    static let levelQuality: [QualityLevel: Int] = [.high: 85, .medium: 70, .low: 50]
    /// AV1 looks equal at lower settings.
    static let levelQualityAVIF: [QualityLevel: Int] = [.high: 70, .medium: 55, .low: 40]
    static let levelColors: [QualityLevel: Int] = [.high: 256, .medium: 128, .low: 64]
    static let pngTargetColors = [256, 128, 64]
    static let gifTargetColors = [128, 64, 32]
    static let gifFrameStrides = [2, 3]
    static let lowestQuality = 1.0
    static let highestQuality = 100.0
    static let maximumSearchEncodes = 8
    /// Keeps interpolation inside the bracket.
    static let minimumStep = 0.1
    static let midpoint = 0.5
    static let downscaleStep = 0.9
    static let maximumDownscaleSteps = 20
    private static let pngTargetHeadroom = 0.95
    private static let maximumPNGScaleCorrections = 3
    static let letterboxFill = RGBColor.black
    static let shapeTolerance = 0.01

    struct Plan {
        var format: ImageFormat
        var frames: [ImageFrame]
        var options: EncodeOptions
        var retained: [CGImage] = []
        var originalWidth = 0
        var originalHeight = 0
        var originalFrameCount = 1
        var isMultiPage = false
    }

    static func compress(_ url: URL, _ compression: ImageCompression, context: ItemContext) async throws
        -> ItemResult
    {
        context.phase(.decoding)
        var document = try await ImageDocument.load(url)
        let limits = try limits(for: compression.goal, document: document)
        let format = outputFormat(for: document, limits: limits)
        document = try ImageOutput.prepared(
            document, as: format, context: context,
            preservesGainMaps: limits?.aspect?.fit != .letterbox,
            preservesHDRPixels: format == .tiff && limits == nil)
        do {
            return try await compressPrepared(
                document, as: format, limits: limits, compression: compression, context: context)
        } catch EngineError.imageGainMapUnsupported {
            let converted = try ImageOutput.toneMappedAfterGainMapFailure(document, context: context)
            return try await compressPrepared(
                converted, as: format, limits: limits, compression: compression, context: context)
        }
    }

    private static func compressPrepared(
        _ document: ImageDocument, as format: ImageFormat, limits: MediaLimits?,
        compression: ImageCompression, context: ItemContext
    ) async throws -> ItemResult {
        if document.isAnimated, format.holdsAnimation {
            return try await compressAnimated(
                document, as: format, limits: limits, compression: compression, context: context)
        }
        if document.isAnimated, document.contentType.conforms(to: .heics), format == .heic {
            throw EngineError.unsupportedCodec("HEICS")
        }
        var gainMaps = [.jpeg, .heic].contains(format) ? document.gainMaps : []
        var frames = try ImageOutput.frames(of: document, for: format, context: context)
        if !format.holdsAlpha {
            for index in frames.indices {
                frames[index].image = try ImageEncoder.flattened(
                    frames[index].image, background: context.settings.image.customBackground)
            }
        }
        frames = try fitted(frames, to: limits, gainMaps: &gainMaps)
        if !format.holdsAlpha {
            for frame in frames {
                try ImageOutput.validateTransparency(
                    frame.image, as: format,
                    keepsOriginal: document.format == nil || context.settings.outputMode == .newFile,
                    context: context)
            }
        }
        var plan = Plan(
            format: format, frames: frames,
            options: ImageOutput.defaultOptions(for: document, format: format, settings: context.settings.image))
        plan.originalWidth = document.frames.first?.image.width ?? 0
        plan.originalHeight = document.frames.first?.image.height ?? 0
        plan.originalFrameCount = document.frameCount
        plan.isMultiPage = document.isMultiPage
        plan.options.gainMaps = gainMaps
        plan.retained = document.frames.map(\.image)
        if compression.stripsGPS {
            plan.options.metadata = ImageMetadata.filtered(document.metadata, removing: [.gps])
            for index in plan.frames.indices {
                plan.frames[index].metadata = ImageMetadata.filtered(plan.frames[index].metadata, removing: [.gps])
            }
        }
        let sizes = { (frames: [ImageFrame]) in frames.map { [$0.image.width, $0.image.height] } }
        let unchanged =
            !document.toneMapsHDR && format == document.format
            && sizes(plan.frames) == sizes(document.frames)
        let originalBytes = Int64(try document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        guard let target = targetBytes(for: compression.goal, limits: limits) else {
            apply(qualityFor: compression.goal, limits: limits, to: &plan)
            context.phase(.encoding)
            var gifQuantized = false
            if plan.format == .gif { plan.options.reportGIFReduction = { gifQuantized = gifQuantized || $0 } }
            let data = try ImageEncoder.encode(
                plan.frames, as: plan.format, options: plan.options, retaining: plan.retained)
            if unchanged, Int64(data.count) >= originalBytes {
                return try await keptSize(
                    document.url, stripsGPS: compression.stripsGPS, reason: .outputNotSmaller, context)
            }
            try report(plan, encoded: data, gifQuantized: gifQuantized, context: context)
            context.phase(.verifying)
            return try ImageOutput.stage(data, for: document, as: format, context: context)
        }
        if unchanged, originalBytes <= target {
            try report(plan, context: context)
            return try await keptSize(document.url, stripsGPS: compression.stripsGPS, reason: .alreadyDone, context)
        }
        context.phase(.searching)
        let balancedPNG =
            format == .png && !document.isAnimated && !document.isMultiPage && document.frameCount == 1
            && plan.frames.count == 1
            && plan.frames.allSatisfy {
                $0.image.bitsPerComponent == 8 && $0.image.colorSpace?.model == .rgb
                    && $0.duration == 0 && !ImageSDR.hasHDRPixels($0.image)
            }
        let data: Data
        if balancedPNG {
            data = try await fitBalancedPNG(plan, under: target, compression: compression, context: context)
        } else {
            data = try await fit(plan, under: target, compression: compression, context: context)
        }
        context.phase(.verifying)
        return try ImageOutput.stage(data, for: document, as: format, context: context)
    }

    private static func fitBalancedPNG(
        _ plan: Plan, under target: Int64, compression: ImageCompression, context: ItemContext
    ) async throws -> Data {
        var options = plan.options
        options.optimizesPNG = true
        options.maximumPNGBytes = target
        options.pngMaximumCompression = false
        var pixels: PixelBuffer?
        do {
            context.phase(.optimizing)
            pixels = try ImageEncoder.preparePNGTargetPixels(plan.frames, options: options, retaining: plan.retained)
            let encoded = try autoreleasepool {
                try ImageEncoder.encode(
                    plan.frames, as: .png, options: options, retaining: plan.retained, preparedPNGPixels: pixels)
            }
            if Int64(encoded.count) <= target {
                try report(plan, context: context)
                return encoded
            }
        } catch PNGOutputError.sizeLimitExceeded {
            context.phase(.searching)
        } catch EngineError.invalidInput(.frameMemoryExceeded) {
            if !context.warnings.contains(.pngOptimizationSkipped) { context.warn(.pngOptimizationSkipped) }
        }
        context.phase(.encoding)
        if !compression.allowsDownscale {
            if let strongest = try await ImageEncoder.quantizedCandidates(
                plan.frames, colors: pngTargetColors, under: target, options: options, retaining: plan.retained,
                preparedPixels: pixels, checkingQuality: true)
            {
                try report(plan, colors: strongest.colors, pngQuantized: strongest.reducedColors, context: context)
                return strongest.encoded
            }
            throw EngineError.pngTargetNotReached
        }
        var usesPalette = true
        var candidate = try balancedPNG(
            plan, colors: pngTargetColors[0], under: target, pixels: pixels, usesPalette: &usesPalette,
            context: context)
        if let encoded = candidate.encoded { return encoded }
        pixels = nil
        var scale = 1.0
        var previousDimensions = plan.frames.map { [$0.image.width, $0.image.height] }
        for _ in 1...maximumPNGScaleCorrections {
            try Task.checkCancellation()
            context.phase(.searching)
            let available = pngTargetHeadroom * Double(target) - Double(candidate.fixedBytes)
            let compressed = Double(candidate.bytes - candidate.fixedBytes)
            guard available > 0, compressed > 0 else { throw EngineError.pngTargetNotReached }
            scale *= min(1.0.nextDown, sqrt(available / compressed))
            let resized = try scaled(plan, by: scale)
            let dimensions = resized.frames.map { [$0.image.width, $0.image.height] }
            guard dimensions != previousDimensions else { break }
            previousDimensions = dimensions
            context.phase(.encoding)
            candidate = try balancedPNG(
                resized, colors: pngTargetColors[0], under: target, usesPalette: &usesPalette, context: context)
            if let encoded = candidate.encoded { return encoded }
        }
        throw EngineError.pngTargetNotReached
    }

    private static func balancedPNG(
        _ plan: Plan, colors: Int, under target: Int64, pixels: PixelBuffer? = nil, usesPalette: inout Bool,
        context: ItemContext
    ) throws -> (encoded: Data?, bytes: Int64, fixedBytes: Int64) {
        try Task.checkCancellation()
        let candidate = try ImageEncoder.balancedPNG(
            plan.frames, colors: colors, options: plan.options, retaining: plan.retained,
            preparedPixels: pixels, usesPalette: usesPalette)
        usesPalette = candidate.usesPalette
        let bytes = Int64(candidate.encoded.count)
        guard bytes <= target else { return (nil, bytes, Int64(candidate.fixedBytes)) }
        try report(
            plan, colors: usesPalette ? colors : nil, pngQuantized: candidate.reducedColors, context: context)
        return (candidate.encoded, bytes, Int64(candidate.fixedBytes))
    }

    private static func report(
        _ plan: Plan, encoded: Data? = nil, colors: Int? = nil, gifQuantized: Bool = false,
        pngQuantized: Bool? = nil, context: ItemContext
    ) throws {
        guard let image = plan.frames.first?.image else { return }
        let dimensions: (width: Int, height: Int)
        if let encoded, plan.format == .ico {
            dimensions = try ICOFile.largestDimensions(encoded)
        } else if let encoded, plan.format == .icns {
            dimensions = try ICNSFile.largestDimensions(encoded)
        } else {
            dimensions = (image.width, image.height)
        }
        let reduced = dimensions.width < plan.originalWidth || dimensions.height < plan.originalHeight
        let paletteColors = colors ?? (plan.format == .gif ? plan.options.gifColors : plan.options.pngColors)
        let quantized: Bool
        if plan.format == .png, image.bitsPerComponent > 8, paletteColors != nil {
            quantized = true
        } else if plan.format == .png, let paletteColors {
            quantized =
                try pngQuantized
                ?? autoreleasepool {
                    try PNGQuantizer.reducesColors(
                        PixelBuffer(cgImage: image), to: paletteColors, cancelled: { Task.isCancelled })
                }
        } else if plan.format == .gif {
            quantized = gifQuantized
        } else {
            quantized = false
        }
        context.reportImageResult(
            originalWidth: plan.originalWidth, originalHeight: plan.originalHeight,
            outputWidth: dimensions.width, outputHeight: dimensions.height,
            reducedDimensions: reduced, quantized: quantized, paletteColors: quantized ? paletteColors : nil,
            frameCount: plan.originalFrameCount, isMultiPage: plan.isMultiPage)
        if reduced { context.warn(.imageDimensionsReduced) }
        if quantized, let paletteColors { context.warn(.imagePaletteReduced(colors: paletteColors)) }
    }

    /// Re-encoding cannot help; only GPS goes.
    private static func keptSize(_ url: URL, stripsGPS: Bool, reason: SkipReason, _ context: ItemContext)
        async throws -> ItemResult
    {
        guard stripsGPS else { return .skipped(reason) }
        let stripped = try await ImageMetadata.strip(url, fields: [.gps], context: context)
        if case .skipped = stripped { return .skipped(reason) }
        return stripped
    }

    private static func limits(for goal: CompressionGoal, document: ImageDocument) throws -> MediaLimits? {
        guard case .platform(let preset) = goal else { return nil }
        let limits = document.format == .gif ? preset.gif ?? preset.image : preset.image
        guard let limits else { throw EngineError.invalidInput(.malformed(preset.id)) }
        return limits
    }

    private static func targetBytes(for goal: CompressionGoal, limits: MediaLimits?) -> Int64? {
        switch goal {
        case .bytes(let bytes): bytes
        case .platform: limits?.targetBytes
        case .level, .quality: nil
        }
    }

    /// The source format wins when listed.
    private static func outputFormat(for document: ImageDocument, limits: MediaLimits?) -> ImageFormat {
        let source = document.writableFormat
        let accepted = (limits?.formats ?? []).compactMap(ImageFormat.init(rawValue:))
        guard let first = accepted.first, !accepted.contains(source) else { return source }
        return first
    }

    private static func apply(qualityFor goal: CompressionGoal, limits: MediaLimits?, to plan: inout Plan) {
        apply(qualityFor: goal, limits: limits, format: plan.format, options: &plan.options)
    }

    private static func apply(
        qualityFor goal: CompressionGoal, limits: MediaLimits?, format: ImageFormat, options: inout EncodeOptions
    ) {
        let level: QualityLevel
        switch goal {
        case .level(let chosen): level = chosen
        case .quality(let quality): level = self.level(for: quality)
        case .platform, .bytes: level = limits?.quality.map(self.level(for:)) ?? .high
        }
        let table = format == .avif ? levelQualityAVIF : levelQuality
        switch goal {
        case .quality(let quality): options.quality = Double(quality)
        case .platform where limits?.quality != nil:
            options.quality = limits?.quality.map(Double.init) ?? options.quality
        default: options.quality = table[level].map(Double.init) ?? options.quality
        }
        if format == .png { options.pngColors = levelColors[level] }
        if format == .gif { options.gifColors = levelColors[level] ?? options.gifColors }
    }

    private static func level(for quality: Int) -> QualityLevel {
        quality >= levelQuality[.high, default: 0]
            ? .high : quality >= levelQuality[.medium, default: 0] ? .medium : .low
    }

    private static func fit(_ plan: Plan, under target: Int64, compression: ImageCompression, context: ItemContext)
        async throws -> Data
    {
        var smallest = Int64.max
        let steps = compression.allowsDownscale ? maximumDownscaleSteps : 0
        if plan.format == .gif {
            return try fitGIF(plan, under: target, compression: compression, smallest: &smallest, context: context)
        }
        for step in 0...steps {
            try Task.checkCancellation()
            context.phase(.searching)
            let scaled = try scaled(plan, by: pow(downscaleStep, Double(step)))
            if let candidate = try await fitting(scaled, under: target, smallest: &smallest, context: context) {
                return candidate
            }
        }
        if plan.format == .png { throw EngineError.pngTargetNotReached }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }

    /// `nil` when nothing fits at this scale.
    private static func fitting(
        _ plan: Plan, under target: Int64, smallest: inout Int64, context: ItemContext
    ) async throws -> Data? {
        var pngPixels: PixelBuffer?
        func encode(_ options: EncodeOptions) throws -> Data {
            try Task.checkCancellation()
            context.phase(options.optimizesPNG && options.pngColors == nil ? .optimizing : .encoding)
            let data = try autoreleasepool {
                try ImageEncoder.encode(
                    plan.frames, as: plan.format, options: options, retaining: plan.retained,
                    preparedPNGPixels: pngPixels)
            }
            smallest = min(smallest, Int64(data.count))
            return data
        }
        let underTarget = { (data: Data) in Int64(data.count) <= target ? data : nil }
        if plan.format.usesQuality {
            let candidate = try searchQuality(plan.options, under: target, encode: encode)
            if candidate != nil { try report(plan, context: context) }
            return candidate
        }
        var options = plan.options
        guard plan.format == .png else {
            let candidate = underTarget(try encode(options))
            if let candidate { try report(plan, encoded: candidate, context: context) }
            return candidate
        }
        options.optimizesPNG = true
        options.maximumPNGBytes = target
        do {
            pngPixels = try ImageEncoder.preparePNGTargetPixels(
                plan.frames, options: options, retaining: plan.retained)
            if let lossless = underTarget(try encode(options)) {
                try report(plan, context: context)
                return lossless
            }
        } catch PNGOutputError.sizeLimitExceeded {
            context.phase(.searching)
        } catch EngineError.invalidInput(.frameMemoryExceeded) {
            if !context.warnings.contains(.pngOptimizationSkipped) { context.warn(.pngOptimizationSkipped) }
        }
        context.phase(.encoding)
        if let candidate = try await ImageEncoder.quantizedCandidates(
            plan.frames, colors: pngTargetColors, under: target, options: options, retaining: plan.retained,
            preparedPixels: pngPixels)
        {
            try report(plan, colors: candidate.colors, pngQuantized: candidate.reducedColors, context: context)
            return candidate.encoded
        }
        context.phase(.searching)
        return nil
    }

    /// Highest quality under `target`, eight encodes.
    private static func searchQuality(
        _ initial: EncodeOptions, under target: Int64, encode: (EncodeOptions) throws -> Data
    ) throws -> Data? {
        var options = initial
        options.quality = lowestQuality
        var best = try encode(options)
        guard Int64(best.count) <= target else { return nil }
        var low = (quality: lowestQuality, logSize: log(Double(best.count)))
        var high: (quality: Double, logSize: Double)?
        let goal = log(Double(target))
        for _ in 1..<maximumSearchEncodes {
            // Size grows roughly exponentially with quality.
            let fraction = high.map { (goal - low.logSize) / ($0.logSize - low.logSize) } ?? midpoint
            let upper = high?.quality ?? highestQuality
            options.quality = low.quality + (upper - low.quality) * min(max(fraction, minimumStep), 1 - minimumStep)
            let data = try encode(options)
            if Int64(data.count) <= target {
                best = data
                low = (options.quality, log(Double(data.count)))
            } else {
                high = (options.quality, log(Double(data.count)))
            }
        }
        return best
    }

    /// Frame rate, then width, then colors.
    private static func fitGIF(
        _ plan: Plan, under target: Int64, compression: ImageCompression, smallest: inout Int64, context: ItemContext
    ) throws -> Data {
        func attempt(_ candidate: Plan) throws -> Data? {
            try Task.checkCancellation()
            for frame in candidate.frames {
                try ImageOutput.validateTransparency(
                    frame.image, as: .gif, keepsOriginal: context.settings.outputMode == .newFile, context: context)
            }
            var options = candidate.options
            var quantized = false
            options.reportGIFReduction = { quantized = quantized || $0 }
            let data = try ImageEncoder.encode(
                candidate.frames, as: .gif, options: options, retaining: candidate.retained)
            smallest = min(smallest, Int64(data.count))
            guard Int64(data.count) <= target else { return nil }
            try report(candidate, encoded: data, gifQuantized: quantized, context: context)
            return data
        }
        var current = plan
        if let data = try attempt(current) { return data }
        if compression.allowsFrameRateReduction, plan.frames.count > 1 {
            for stride in gifFrameStrides {
                current = plan
                current.frames = decimated(plan.frames, stride: stride)
                if let data = try attempt(current) { return data }
            }
        }
        if compression.allowsDownscale {
            let reduced = current
            for step in 1...maximumDownscaleSteps {
                current = try scaled(reduced, by: pow(downscaleStep, Double(step)))
                if let data = try attempt(current) { return data }
            }
        }
        for colors in gifTargetColors {
            current.options.gifColors = colors
            if let data = try attempt(current) { return data }
        }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }

    /// Keeps every `stride`-th frame; durations add up.
    static func decimated(_ frames: [ImageFrame], stride: Int) -> [ImageFrame] {
        Swift.stride(from: 0, to: frames.count, by: stride).map { start in
            let group = frames[start..<min(start + stride, frames.count)]
            return ImageFrame(image: frames[start].image, duration: group.reduce(0) { $0 + $1.duration })
        }
    }

    private static func scaled(_ plan: Plan, by factor: Double) throws -> Plan {
        try autoreleasepool {
            guard factor < 1 else { return plan }
            var scaled = plan
            scaled.retained += plan.frames.map(\.image)
            for index in scaled.frames.indices {
                let image = scaled.frames[index].image
                let width = max(1, Int((Double(image.width) * factor).rounded()))
                let height = max(1, Int((Double(image.height) * factor).rounded()))
                let resized = try ImagePixels.scaled(image, width: width, height: height)
                if index == 0 {
                    scaled.options.gainMaps = try plan.options.gainMaps.map {
                        try $0.applying(.resize(image, to: resized))
                    }
                }
                scaled.frames[index].image = resized
            }
            return scaled
        }
    }

    /// Applies aspect, maximum dimensions and maximum frames.
    static func fitted(_ frames: [ImageFrame], to limits: MediaLimits?) throws -> [ImageFrame] {
        var gainMaps: [ImageGainMap] = []
        return try fitted(frames, to: limits, gainMaps: &gainMaps)
    }

    private static func fitted(_ frames: [ImageFrame], to limits: MediaLimits?, gainMaps: inout [ImageGainMap]) throws
        -> [ImageFrame]
    {
        guard let limits else { return frames }
        guard limits.maxFrames.map({ $0 > 0 }) ?? true,
            limits.maxWidth.map({ $0 > 0 }) ?? true,
            limits.maxHeight.map({ $0 > 0 }) ?? true,
            limits.aspect.map(\.isValid) ?? true
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        var result = frames
        if let maxFrames = limits.maxFrames, result.count > maxFrames {
            result = decimated(result, stride: Int((Double(result.count) / Double(maxFrames)).rounded(.up)))
        }
        for index in result.indices {
            var image = result[index].image
            if let aspect = limits.aspect {
                let original = image
                let rect = try reshapeBounds(image, aspect)
                image = try reshaped(image, aspect)
                if index == 0 {
                    gainMaps = try gainMaps.map { try $0.applying(.crop(original, to: rect)) }
                }
            }
            let widthScale = limits.maxWidth.map { Double($0) / Double(image.width) } ?? 1
            let heightScale = limits.maxHeight.map { Double($0) / Double(image.height) } ?? 1
            let scale = min(widthScale, heightScale)
            if scale < 1 {
                let resized = try ImagePixels.scaled(
                    image, width: max(1, Int((Double(image.width) * scale).rounded())),
                    height: max(1, Int((Double(image.height) * scale).rounded())))
                if index == 0 {
                    gainMaps = try gainMaps.map { try $0.applying(.resize(image, to: resized)) }
                }
                image = resized
            }
            result[index].image = image
        }
        return result
    }

    private static func reshapeBounds(_ image: CGImage, _ aspect: AspectRange) throws -> CGRect {
        let width = Double(image.width)
        let height = Double(image.height)
        let ratio = width / height
        let goal = min(max(ratio, aspect.min.value), aspect.max.value)
        guard goal.isFinite, goal > 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
        guard abs(goal - ratio) > shapeTolerance else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        let outputWidth: Double
        let outputHeight: Double
        switch aspect.fit {
        case .crop:
            outputWidth = goal < ratio ? (height * goal).rounded() : width
            outputHeight = goal < ratio ? height : (width / goal).rounded()
        case .letterbox:
            outputWidth = (goal > ratio ? height * goal : width).rounded()
            outputHeight = (goal > ratio ? height : width / goal).rounded()
        }
        return CGRect(
            x: ((width - outputWidth) / 2).rounded(.up), y: ((height - outputHeight) / 2).rounded(.up),
            width: outputWidth, height: outputHeight)
    }

    private static func reshaped(_ image: CGImage, _ aspect: AspectRange) throws -> CGImage {
        let rect = try reshapeBounds(image, aspect)
        switch aspect.fit {
        case .crop: return try ImagePixels.cropped(image, to: rect)
        case .letterbox:
            guard let width = Int(exactly: rect.width), let height = Int(exactly: rect.height) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            return try ImagePixels.padded(image, width: width, height: height, fill: ImagePixels.color(letterboxFill))
        }
    }

    private struct AnimatedPlan {
        let document: ImageDocument
        let format: ImageFormat
        let limits: MediaLimits?
        let durations: [Double]
        let baseStride: Int
        var frameStride: Int
        var scale = 1.0
        var options: EncodeOptions

        var frameCount: Int {
            1 + (document.frameCount - 1) / frameStride
        }
    }

    private static func compressAnimated(
        _ document: ImageDocument, as format: ImageFormat, limits: MediaLimits?,
        compression: ImageCompression, context: ItemContext
    ) async throws -> ItemResult {
        guard limits?.maxFrames.map({ $0 > 0 }) ?? true else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        context.reportImageResult(
            originalWidth: document.first.width, originalHeight: document.first.height,
            outputWidth: document.first.width, outputHeight: document.first.height,
            reducedDimensions: false, quantized: false,
            frameCount: document.frameCount, isMultiPage: false)
        let count = try ImageOutput.keptFrameCount(of: document, for: format)
        let stride = limits?.maxFrames.map { 1 + (count - 1) / $0 } ?? 1
        var durations: [Double] = []
        durations.reserveCapacity(count)
        var unchanged = !document.toneMapsHDR && format == document.format && stride == 1
        for index in 0..<count {
            try Task.checkCancellation()
            durations.append(try document.frameDuration(at: index))
            if unchanged, limits != nil {
                unchanged = try autoreleasepool {
                    let source = try document.frame(at: index)
                    let fittedFrame = try fitted([source], to: limits)[0]
                    return source.image.width == fittedFrame.image.width
                        && source.image.height == fittedFrame.image.height
                }
            }
        }
        var options = ImageOutput.defaultOptions(for: document, format: format, settings: context.settings.image)
        if compression.stripsGPS {
            options.metadata = ImageMetadata.filtered(document.metadata, removing: [.gps])
        }
        var plan = AnimatedPlan(
            document: document, format: format, limits: limits, durations: durations,
            baseStride: stride, frameStride: stride, options: options)
        let target = targetBytes(for: compression.goal, limits: limits)
        let originalBytes = Int64(try document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if let target, unchanged, originalBytes <= target {
            return try await keptSize(
                document.url, stripsGPS: compression.stripsGPS, reason: .alreadyDone, context)
        }
        let name = ImageOutput.outputName(for: document, format: format)
        let directory = try context.stagingDirectory(for: document.url)
        let output = directory.appending(path: name)
        let trials = try context.stagingDirectory(for: document.url)
        let candidate = trials.appending(path: "candidate.\(format.fileExtension)")
        let best = trials.appending(path: "best.\(format.fileExtension)")
        guard let target else {
            apply(qualityFor: compression.goal, limits: limits, format: format, options: &plan.options)
            var quantized = false
            if format == .gif { plan.options.reportGIFReduction = { quantized = quantized || $0 } }
            let size = try await encodeAnimated(plan, to: output, context: context)
            if unchanged, size >= originalBytes {
                return try await keptSize(
                    document.url, stripsGPS: compression.stripsGPS, reason: .outputNotSmaller, context)
            }
            try reportAnimated(plan, output: output, gifQuantized: quantized, context: context)
            return ImageOutput.staged(output, for: document, as: format)
        }
        var smallest = Int64.max
        if format == .gif {
            let accepted = try await fitAnimatedGIF(
                plan, under: target, candidate: candidate, output: output,
                smallest: &smallest, compression: compression, context: context)
            try reportAnimated(accepted.plan, output: output, gifQuantized: accepted.quantized, context: context)
            return ImageOutput.staged(output, for: document, as: format)
        } else {
            let steps = compression.allowsDownscale ? maximumDownscaleSteps : 0
            var fitted = false
            for step in 0...steps {
                try Task.checkCancellation()
                context.phase(.searching)
                plan.scale = pow(downscaleStep, Double(step))
                if try await fitAnimatedScale(
                    plan, under: target, candidate: candidate, best: best, output: output,
                    smallest: &smallest, context: context)
                {
                    fitted = true
                    break
                }
            }
            if !fitted { throw EngineError.targetUnreachable(smallestBytes: smallest) }
        }
        try reportAnimated(plan, output: output, context: context)
        return ImageOutput.staged(output, for: document, as: format)
    }

    private static func reportAnimated(
        _ plan: AnimatedPlan, output: URL, gifQuantized: Bool = false, context: ItemContext
    ) throws {
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw EngineError.decodeFailed(output.lastPathComponent) }
        let original = plan.document.first
        let reduced = width < original.width || height < original.height
        context.reportImageResult(
            originalWidth: original.width, originalHeight: original.height,
            outputWidth: width, outputHeight: height,
            reducedDimensions: reduced, quantized: gifQuantized,
            paletteColors: gifQuantized ? plan.options.gifColors : nil,
            frameCount: plan.document.frameCount, isMultiPage: false)
        if reduced { context.warn(.imageDimensionsReduced) }
        if gifQuantized { context.warn(.imagePaletteReduced(colors: plan.options.gifColors)) }
    }

    private static func encodeAnimated(_ plan: AnimatedPlan, to output: URL, context: ItemContext) async throws
        -> Int64
    {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try await ImageEncoder.encodeStreaming(
            frameCount: plan.frameCount, as: plan.format, options: plan.options, to: output
        ) { index in
            try Task.checkCancellation()
            return try autoreleasepool {
                let sourceIndex = index * plan.frameStride
                var frame = try plan.document.frame(at: sourceIndex)
                frame.duration = plan.durations[sourceIndex..<min(sourceIndex + plan.frameStride, plan.durations.count)]
                    .reduce(0, +)
                frame = try fitted([frame], to: plan.limits)[0]
                if plan.scale < 1 {
                    frame.image = try ImagePixels.scaled(
                        frame.image,
                        width: max(1, Int((Double(frame.image.width) * plan.scale).rounded())),
                        height: max(1, Int((Double(frame.image.height) * plan.scale).rounded())))
                }
                try ImageOutput.validateTransparency(
                    frame.image, as: plan.format,
                    keepsOriginal: context.settings.outputMode == .newFile, context: context)
                context.progress(Double(index + 1) / Double(plan.frameCount))
                return frame
            }
        }
        var refreshed = output
        refreshed.removeCachedResourceValue(forKey: .fileSizeKey)
        guard let size = try refreshed.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw EngineError.encodeFailed(plan.format.rawValue)
        }
        return Int64(size)
    }

    private static func accept(_ candidate: URL, as output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: candidate, to: output)
    }

    private static func fitAnimatedScale(
        _ plan: AnimatedPlan, under target: Int64, candidate: URL, best: URL, output: URL,
        smallest: inout Int64, context: ItemContext
    ) async throws -> Bool {
        if plan.format.usesQuality {
            var options = plan.options
            options.quality = lowestQuality
            var trial = plan
            trial.options = options
            var size = try await encodeAnimated(trial, to: candidate, context: context)
            smallest = min(smallest, size)
            guard size <= target else { return false }
            try accept(candidate, as: best)
            var low = (quality: lowestQuality, logSize: log(Double(size)))
            var high: (quality: Double, logSize: Double)?
            let goal = log(Double(target))
            for _ in 1..<maximumSearchEncodes {
                let fraction = high.map { (goal - low.logSize) / ($0.logSize - low.logSize) } ?? midpoint
                let upper = high?.quality ?? highestQuality
                options.quality = low.quality + (upper - low.quality) * min(max(fraction, minimumStep), 1 - minimumStep)
                trial.options = options
                size = try await encodeAnimated(trial, to: candidate, context: context)
                smallest = min(smallest, size)
                if size <= target {
                    try accept(candidate, as: best)
                    low = (options.quality, log(Double(size)))
                } else {
                    high = (options.quality, log(Double(size)))
                }
            }
            try accept(best, as: output)
            return true
        }
        if plan.format == .png, plan.frameCount > 1 {
            let size = try await encodeAnimated(plan, to: candidate, context: context)
            smallest = min(smallest, size)
            guard size <= target else { return false }
            try accept(candidate, as: output)
            return true
        }
        var trial = plan
        trial.options.optimizesPNG = true
        do {
            let size = try await encodeAnimated(trial, to: candidate, context: context)
            smallest = min(smallest, size)
            if size <= target {
                try accept(candidate, as: output)
                return true
            }
        } catch EngineError.invalidInput(.frameMemoryExceeded) {
            if !context.warnings.contains(.pngOptimizationSkipped) {
                context.warn(.pngOptimizationSkipped)
            }
        }
        for colors in pngTargetColors {
            trial.options.pngColors = colors
            let size = try await encodeAnimated(trial, to: candidate, context: context)
            smallest = min(smallest, size)
            if size <= target {
                try accept(candidate, as: output)
                return true
            }
        }
        return false
    }

    private static func fitAnimatedGIF(
        _ plan: AnimatedPlan, under target: Int64, candidate: URL, output: URL,
        smallest: inout Int64, compression: ImageCompression, context: ItemContext
    ) async throws -> (plan: AnimatedPlan, quantized: Bool) {
        var quantized = false
        func attempt(_ trial: AnimatedPlan) async throws -> Bool {
            try Task.checkCancellation()
            var candidatePlan = trial
            quantized = false
            candidatePlan.options.reportGIFReduction = { quantized = quantized || $0 }
            let size = try await encodeAnimated(candidatePlan, to: candidate, context: context)
            smallest = min(smallest, size)
            guard size <= target else { return false }
            try accept(candidate, as: output)
            return true
        }
        var current = plan
        if try await attempt(current) { return (current, quantized) }
        if compression.allowsFrameRateReduction, plan.frameCount > 1 {
            for stride in gifFrameStrides {
                current = plan
                current.frameStride = plan.baseStride * stride
                if try await attempt(current) { return (current, quantized) }
            }
        }
        if compression.allowsDownscale {
            let reduced = current
            for step in 1...maximumDownscaleSteps {
                current = reduced
                current.scale = pow(downscaleStep, Double(step))
                if try await attempt(current) { return (current, quantized) }
            }
        }
        for colors in gifTargetColors {
            current.options.gifColors = colors
            if try await attempt(current) { return (current, quantized) }
        }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }
}
