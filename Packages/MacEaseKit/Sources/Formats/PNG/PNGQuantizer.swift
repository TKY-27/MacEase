import Foundation

/// Palette quantization in premultiplied Oklab.
public enum PNGQuantizer {
    public enum QualityError: Error {
        case unsuitablePalette
    }

    public static func reducesColors(
        _ pixels: PixelBuffer, to colors: Int, cancelled: (() -> Bool)? = nil
    ) throws -> Bool {
        let exact = ColorQuantizer.exactPalette(
            of: pixels.rgba, limit: min(max(colors, 2), 256), includesAlpha: true, cancelled: cancelled)
        if cancelled?() == true { throw CancellationError() }
        return exact == nil
    }

    public static func encode(
        _ pixels: PixelBuffer,
        colors: Int,
        dithering: Dithering,
        ancillary: [PNGChunk] = [],
        maximumBytes: Int64? = nil,
        checkingQuality: Bool = false,
        cancelled: (() -> Bool)? = nil
    ) throws -> Data {
        let (raster, transparency) = try paletteRaster(
            pixels, colors: colors, dithering: dithering, cancelled: cancelled)
        if checkingQuality, try !PNGPaletteQuality.accepts(raster, original: pixels, cancelled: cancelled) {
            throw QualityError.unsuitablePalette
        }
        let strategies: [PNGFilterStrategy] = [.none, .adaptive]
        if let maximumBytes {
            let sample = PNGOptimizer.sampled(raster)
            let estimates = try strategies.map { strategy in
                (
                    strategy,
                    try PNGFile.encode(
                        sample, transparency: transparency, strategy: strategy,
                        level: PNGFile.trialLevel, cancelled: cancelled
                    ).count
                )
            }
            for (strategy, _) in estimates.sorted(by: { $0.1 < $1.1 }) {
                do {
                    let balanced = try PNGFile.encode(
                        raster, transparency: transparency, ancillary: ancillary, strategy: strategy,
                        level: PNGFile.trialLevel, maximumCompressedBytes: maximumBytes, cancelled: cancelled)
                    if Int64(balanced.count) <= maximumBytes { return balanced }
                } catch PNGOutputError.sizeLimitExceeded {
                    continue
                }
            }
        }
        var best: Data?
        for strategy in strategies {
            do {
                let encoded = try PNGFile.encode(
                    raster, transparency: transparency, ancillary: ancillary, strategy: strategy,
                    level: PNGFile.maximumLevel, maximumCompressedBytes: maximumBytes, cancelled: cancelled)
                if maximumBytes.map({ Int64(encoded.count) <= $0 }) == true { return encoded }
                if encoded.count < best?.count ?? .max { best = encoded }
            } catch PNGOutputError.sizeLimitExceeded {
                continue
            }
        }
        guard let best else { throw PNGOutputError.sizeLimitExceeded }
        return best
    }

    public static func encodeTarget(
        _ pixels: PixelBuffer, colors: Int, dithering: Dithering, ancillary: [PNGChunk] = [],
        maximumBytes: Int64, parallelMaximumFilters: Bool, checkingQuality: Bool = false
    ) async throws -> Data {
        if !parallelMaximumFilters {
            let encoded = try autoreleasepool {
                try encode(
                    pixels, colors: colors, dithering: dithering, ancillary: ancillary,
                    maximumBytes: maximumBytes, checkingQuality: checkingQuality, cancelled: { Task.isCancelled })
            }
            try Task.checkCancellation()
            guard Int64(encoded.count) <= maximumBytes else { throw PNGOutputError.sizeLimitExceeded }
            return encoded
        }
        let trials = try autoreleasepool {
            try targetTrials(
                pixels, colors: colors, dithering: dithering, ancillary: ancillary, maximumBytes: maximumBytes,
                checkingQuality: checkingQuality)
        }
        try Task.checkCancellation()
        if let balanced = trials.balanced { return balanced }
        async let first = maximum(trials.prepared[0], under: maximumBytes)
        async let second = maximum(trials.prepared[1], under: maximumBytes)
        do {
            let encoded = try await first
            try Task.checkCancellation()
            return encoded
        } catch PNGOutputError.sizeLimitExceeded {
            let encoded = try await second
            try Task.checkCancellation()
            return encoded
        }
    }

    public static func encodeBalanced(
        _ pixels: PixelBuffer, colors: Int, dithering: Dithering, ancillary: [PNGChunk] = [],
        maximumBytes: Int64, checkingQuality: Bool = true, cancelled: (() -> Bool)? = nil
    ) throws -> (encoded: Data, fixedBytes: Int) {
        let (raster, transparency) = try paletteRaster(
            pixels, colors: colors, dithering: dithering, cancelled: cancelled)
        if checkingQuality, try !PNGPaletteQuality.accepts(raster, original: pixels, cancelled: cancelled) {
            throw QualityError.unsuitablePalette
        }
        let sample = PNGOptimizer.sampled(raster)
        let estimates = try [PNGFilterStrategy.none, .adaptive].map { strategy in
            (
                strategy,
                try PNGFile.encode(
                    sample, transparency: transparency, strategy: strategy, level: PNGFile.trialLevel,
                    cancelled: cancelled
                ).count
            )
        }
        guard let best = estimates.min(by: { $0.1 < $1.1 }) else {
            throw FormatError.encoderFailure("no PNG candidate")
        }
        let prepared = try PNGFile.prepare(
            raster, transparency: transparency, ancillary: ancillary, strategy: best.0, cancelled: cancelled)
        let chunkOverhead = 12
        let terminalChunks = 2
        let fixedBytes =
            PNGFile.signature.count + prepared.chunks.reduce(0) { $0 + $1.payload.count + chunkOverhead }
            + terminalChunks * chunkOverhead
        guard maximumBytes > Int64(fixedBytes) else { throw PNGOutputError.sizeLimitExceeded }
        let capacity = maximumBytes - Int64(fixedBytes)
        if cancelled?() == true { throw CancellationError() }
        let encoded = try PNGFile.encode(
            prepared, level: PNGFile.trialLevel, maximumCompressedBytes: capacity)
        if cancelled?() == true { throw CancellationError() }
        return (encoded, fixedBytes)
    }

    private static func maximum(_ prepared: PNGFile.Prepared, under maximumBytes: Int64) throws -> Data {
        try Task.checkCancellation()
        let encoded = try PNGFile.encode(prepared, level: PNGFile.maximumLevel, maximumCompressedBytes: maximumBytes)
        try Task.checkCancellation()
        guard Int64(encoded.count) <= maximumBytes else { throw PNGOutputError.sizeLimitExceeded }
        return encoded
    }

    private static func targetTrials(
        _ pixels: PixelBuffer, colors: Int, dithering: Dithering, ancillary: [PNGChunk], maximumBytes: Int64,
        checkingQuality: Bool
    ) throws -> (balanced: Data?, prepared: [PNGFile.Prepared]) {
        let cancelled = { Task.isCancelled }
        let (raster, transparency) = try paletteRaster(
            pixels, colors: colors, dithering: dithering, cancelled: cancelled)
        if checkingQuality, try !PNGPaletteQuality.accepts(raster, original: pixels, cancelled: cancelled) {
            throw QualityError.unsuitablePalette
        }
        let strategies: [PNGFilterStrategy] = [.none, .adaptive]
        let sample = PNGOptimizer.sampled(raster)
        let estimates = try strategies.enumerated().map { index, strategy in
            (
                index,
                try PNGFile.encode(
                    sample, transparency: transparency, strategy: strategy, level: PNGFile.trialLevel,
                    cancelled: cancelled
                ).count
            )
        }
        var prepared: [PNGFile.Prepared?] = [nil, nil]
        for (index, _) in estimates.sorted(by: { $0.1 < $1.1 }) {
            let candidate = try PNGFile.prepare(
                raster, transparency: transparency, ancillary: ancillary, strategy: strategies[index],
                cancelled: cancelled)
            prepared[index] = candidate
            do {
                try Task.checkCancellation()
                let balanced = try PNGFile.encode(
                    candidate, level: PNGFile.trialLevel, maximumCompressedBytes: maximumBytes)
                if Int64(balanced.count) <= maximumBytes { return (balanced, []) }
            } catch PNGOutputError.sizeLimitExceeded {
                continue
            }
        }
        return (nil, prepared.compactMap { $0 })
    }

    private static func paletteRaster(
        _ pixels: PixelBuffer, colors: Int, dithering: Dithering, cancelled: (() -> Bool)?
    ) throws -> (PNGRaster, [UInt8]?) {
        if cancelled?() == true { throw CancellationError() }
        guard pixels.pixelCount > 0 else { throw FormatError.encoderFailure("empty image") }
        let includesAlpha = !pixels.isOpaque
        let quantizer = ColorQuantizer(includesAlpha: includesAlpha)
        let limit = min(max(colors, 2), 256)
        let palette: [PaletteColor]
        let mappingDithering: Dithering
        if let exact = ColorQuantizer.exactPalette(
            of: pixels.rgba, limit: limit, includesAlpha: includesAlpha, cancelled: cancelled)
        {
            palette = exact
            mappingDithering = .none
        } else {
            mappingDithering = dithering
            let samples = ColorQuantizer.samples(of: pixels.rgba, includesAlpha: includesAlpha, cancelled: cancelled)
            let initial = quantizer.palette(from: samples, count: limit, cancelled: cancelled)
            let draftIndices = try mappedIndices(
                pixels, palette: initial, includesAlpha: includesAlpha, dithering: .none, cancelled: cancelled)
            // tRNS needs every translucent entry first.
            palette = quantizer.refined(initial, pixels: pixels.rgba, indices: draftIndices, cancelled: cancelled)
                .sorted {
                    $0.alpha < $1.alpha
                }
        }
        if cancelled?() == true { throw CancellationError() }
        let indices = try mappedIndices(
            pixels, palette: palette, includesAlpha: includesAlpha, dithering: mappingDithering, cancelled: cancelled)
        if cancelled?() == true { throw CancellationError() }
        let (raster, transparency) = try PNGOptimizer.paletteRaster(
            indices: indices, palette: palette, width: pixels.width, height: pixels.height, cancelled: cancelled
        )
        return (raster, transparency)
    }

    private static func mappedIndices(
        _ pixels: PixelBuffer, palette: [PaletteColor], includesAlpha: Bool, dithering: Dithering,
        cancelled: (() -> Bool)?
    ) throws -> Data {
        var mapper = PaletteMapper(palette: palette, includesAlpha: includesAlpha, dithering: dithering)
        var indices = try PNGFile.mappedBytes(count: pixels.pixelCount)
        let completed = indices.withUnsafeMutableBytes { destination in
            mapper.map(
                pixels.rgba, width: pixels.width, height: pixels.height, dithering: dithering, into: destination,
                cancelled: cancelled)
        }
        guard completed else { throw CancellationError() }
        return indices
    }
}
