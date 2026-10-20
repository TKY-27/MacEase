import Foundation

/// Palette quantization in premultiplied Oklab.
public enum PNGQuantizer {
    public static func encode(
        _ pixels: PixelBuffer,
        colors: Int,
        dithering: Dithering,
        ancillary: [PNGChunk] = []
    ) throws -> Data {
        guard pixels.pixelCount > 0 else { throw FormatError.encoderFailure("empty image") }
        let includesAlpha = !pixels.isOpaque
        let quantizer = ColorQuantizer(includesAlpha: includesAlpha)
        let limit = min(max(colors, 2), 256)
        let palette: [PaletteColor]
        if let exact = ColorQuantizer.exactPalette(of: pixels.rgba, limit: limit, includesAlpha: includesAlpha) {
            palette = exact
        } else {
            let samples = ColorQuantizer.samples(of: pixels.rgba, includesAlpha: includesAlpha)
            let initial = quantizer.palette(from: samples, count: limit)
            var draft = PaletteMapper(palette: initial, includesAlpha: includesAlpha, dithering: .none)
            let draftIndices = draft.map(pixels.rgba, width: pixels.width, height: pixels.height, dithering: .none)
            // tRNS needs every translucent entry first.
            palette = quantizer.refined(initial, pixels: pixels.rgba, indices: draftIndices).sorted {
                $0.alpha < $1.alpha
            }
        }
        var mapper = PaletteMapper(palette: palette, includesAlpha: includesAlpha, dithering: dithering)
        let indices = mapper.map(pixels.rgba, width: pixels.width, height: pixels.height, dithering: dithering)
        let (raster, transparency) = PNGOptimizer.paletteRaster(
            indices: indices, palette: palette, width: pixels.width, height: pixels.height
        )
        let candidates = try [PNGFilterStrategy.none, .adaptive].map { strategy in
            try PNGFile.encode(
                raster, transparency: transparency, ancillary: ancillary, strategy: strategy,
                level: PNGFile.maximumLevel
            )
        }
        return candidates.min { $0.count < $1.count } ?? candidates[0]
    }
}
