import Foundation

/// Palette quantization in premultiplied Oklab.
public enum PNGQuantizer {
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
        cancelled: (() -> Bool)? = nil
    ) throws -> Data {
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
            var draft = PaletteMapper(palette: initial, includesAlpha: includesAlpha, dithering: .none)
            let draftIndices = draft.map(
                pixels.rgba, width: pixels.width, height: pixels.height, dithering: .none, cancelled: cancelled)
            // tRNS needs every translucent entry first.
            palette = quantizer.refined(initial, pixels: pixels.rgba, indices: draftIndices, cancelled: cancelled)
                .sorted {
                    $0.alpha < $1.alpha
                }
        }
        if cancelled?() == true { throw CancellationError() }
        var mapper = PaletteMapper(palette: palette, includesAlpha: includesAlpha, dithering: mappingDithering)
        let indices = mapper.map(
            pixels.rgba, width: pixels.width, height: pixels.height, dithering: mappingDithering, cancelled: cancelled)
        if cancelled?() == true { throw CancellationError() }
        let (raster, transparency) = try PNGOptimizer.paletteRaster(
            indices: indices, palette: palette, width: pixels.width, height: pixels.height, cancelled: cancelled
        )
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
}
