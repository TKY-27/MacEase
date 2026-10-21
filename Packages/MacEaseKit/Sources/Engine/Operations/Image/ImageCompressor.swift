import CoreGraphics
import Formats
import Foundation

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
    static let letterboxFill = RGBColor.black
    static let shapeTolerance = 0.01

    struct Plan {
        var format: ImageFormat
        var frames: [ImageFrame]
        var options: EncodeOptions
    }

    static func compress(_ url: URL, _ compression: ImageCompression, context: ItemContext) async throws
        -> ItemResult
    {
        let document = try await ImageDocument.load(url)
        let limits = try limits(for: compression.goal, document: document)
        let format = outputFormat(for: document, limits: limits)
        var plan = Plan(
            format: format,
            frames: try fitted(ImageOutput.frames(of: document, for: format, context: context), to: limits),
            options: ImageOutput.defaultOptions(for: document, format: format, settings: context.settings.image))
        if compression.stripsGPS { plan.options.metadata = ImageMetadata.filtered(document.metadata, removing: [.gps]) }
        let sizes = { (frames: [ImageFrame]) in frames.map { [$0.image.width, $0.image.height] } }
        let unchanged = format == document.format && sizes(plan.frames) == sizes(document.frames)
        if sameShape(plan.frames[0].image, document.first) { plan.options.gainMap = document.gainMap }
        let originalBytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        guard let target = targetBytes(for: compression.goal, limits: limits) else {
            apply(qualityFor: compression.goal, limits: limits, to: &plan)
            let data = try ImageEncoder.encode(plan.frames, as: plan.format, options: plan.options)
            if unchanged, Int64(data.count) >= originalBytes {
                return try await keptSize(url, stripsGPS: compression.stripsGPS, reason: .outputNotSmaller, context)
            }
            return try ImageOutput.stage(data, for: document, as: format, context: context)
        }
        if unchanged, originalBytes <= target {
            return try await keptSize(url, stripsGPS: compression.stripsGPS, reason: .alreadyDone, context)
        }
        let data = try fit(plan, under: target, compression: compression, context: context)
        return try ImageOutput.stage(data, for: document, as: format, context: context)
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

    /// Gain maps survive scaling, not crops.
    private static func sameShape(_ output: CGImage, _ source: CGImage) -> Bool {
        let outputRatio = Double(output.width) / Double(output.height)
        return abs(outputRatio - Double(source.width) / Double(source.height)) < shapeTolerance
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
        let level: QualityLevel
        switch goal {
        case .level(let chosen): level = chosen
        case .quality(let quality): level = self.level(for: quality)
        case .platform, .bytes: level = limits?.quality.map(self.level(for:)) ?? .high
        }
        let table = plan.format == .avif ? levelQualityAVIF : levelQuality
        switch goal {
        case .quality(let quality): plan.options.quality = Double(quality)
        case .platform where limits?.quality != nil:
            plan.options.quality = limits?.quality.map(Double.init) ?? plan.options.quality
        default: plan.options.quality = table[level].map(Double.init) ?? plan.options.quality
        }
        if plan.format == .png { plan.options.pngColors = levelColors[level] }
        if plan.format == .gif { plan.options.gifColors = levelColors[level] ?? plan.options.gifColors }
    }

    private static func level(for quality: Int) -> QualityLevel {
        quality >= levelQuality[.high, default: 0]
            ? .high : quality >= levelQuality[.medium, default: 0] ? .medium : .low
    }

    private static func fit(_ plan: Plan, under target: Int64, compression: ImageCompression, context: ItemContext)
        throws -> Data
    {
        var smallest = Int64.max
        let steps = compression.allowsDownscale ? maximumDownscaleSteps : 0
        if plan.format == .gif {
            return try fitGIF(plan, under: target, compression: compression, smallest: &smallest)
        }
        for step in 0...steps {
            try Task.checkCancellation()
            context.progress(Double(step) / Double(steps + 1))
            let scaled = try scaled(plan, by: pow(downscaleStep, Double(step)))
            let candidates = try fitting(scaled, under: target, smallest: &smallest)
            if let data = candidates { return data }
        }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }

    /// `nil` when nothing fits at this scale.
    private static func fitting(_ plan: Plan, under target: Int64, smallest: inout Int64) throws -> Data? {
        func encode(_ options: EncodeOptions) throws -> Data {
            let data = try ImageEncoder.encode(plan.frames, as: plan.format, options: options)
            smallest = min(smallest, Int64(data.count))
            return data
        }
        let underTarget = { (data: Data) in Int64(data.count) <= target ? data : nil }
        if plan.format.usesQuality {
            return try searchQuality(plan.options, under: target, encode: encode)
        }
        var options = plan.options
        guard plan.format == .png else { return underTarget(try encode(options)) }
        options.optimizesPNG = true
        if let lossless = underTarget(try encode(options)) { return lossless }
        for colors in pngTargetColors {
            options.pngColors = colors
            if let quantized = underTarget(try encode(options)) { return quantized }
        }
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
    private static func fitGIF(_ plan: Plan, under target: Int64, compression: ImageCompression, smallest: inout Int64)
        throws -> Data
    {
        func attempt(_ candidate: Plan) throws -> Data? {
            try Task.checkCancellation()
            let data = try ImageEncoder.encode(candidate.frames, as: .gif, options: candidate.options)
            smallest = min(smallest, Int64(data.count))
            return Int64(data.count) <= target ? data : nil
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
        guard factor < 1 else { return plan }
        var scaled = plan
        for index in scaled.frames.indices {
            let image = scaled.frames[index].image
            let width = max(1, Int((Double(image.width) * factor).rounded()))
            let height = max(1, Int((Double(image.height) * factor).rounded()))
            scaled.frames[index].image = try ImagePixels.scaled(image, width: width, height: height)
        }
        return scaled
    }

    /// Applies aspect, maximum dimensions and maximum frames.
    static func fitted(_ frames: [ImageFrame], to limits: MediaLimits?) throws -> [ImageFrame] {
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
            if let aspect = limits.aspect { image = try reshaped(image, aspect) }
            let widthScale = limits.maxWidth.map { Double($0) / Double(image.width) } ?? 1
            let heightScale = limits.maxHeight.map { Double($0) / Double(image.height) } ?? 1
            let scale = min(widthScale, heightScale)
            if scale < 1 {
                image = try ImagePixels.scaled(
                    image, width: max(1, Int((Double(image.width) * scale).rounded())),
                    height: max(1, Int((Double(image.height) * scale).rounded())))
            }
            result[index].image = image
        }
        return result
    }

    private static func reshaped(_ image: CGImage, _ aspect: AspectRange) throws -> CGImage {
        let width = Double(image.width)
        let height = Double(image.height)
        let ratio = width / height
        let goal = min(max(ratio, aspect.min.value), aspect.max.value)
        guard goal.isFinite, goal > 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
        guard abs(goal - ratio) > shapeTolerance else { return image }
        switch aspect.fit {
        case .crop:
            let cropWidth = goal < ratio ? (height * goal).rounded() : width
            let cropHeight = goal < ratio ? height : (width / goal).rounded()
            let rect = CGRect(
                x: ((width - cropWidth) / 2).rounded(), y: ((height - cropHeight) / 2).rounded(),
                width: cropWidth, height: cropHeight)
            return try ImagePixels.cropped(image, to: rect)
        case .letterbox:
            guard let canvasWidth = Int(exactly: (goal > ratio ? height * goal : width).rounded()),
                let canvasHeight = Int(exactly: (goal > ratio ? height : width / goal).rounded())
            else { throw EngineError.invalidInput(.invalidNumericParameter) }
            return try ImagePixels.padded(
                image, width: canvasWidth, height: canvasHeight, fill: ImagePixels.color(letterboxFill))
        }
    }
}
