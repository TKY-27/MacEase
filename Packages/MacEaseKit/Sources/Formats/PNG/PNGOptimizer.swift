import CoreGraphics
import Foundation
import ImageIO

public enum PNGOptimizer {
    /// Never larger than `original`; pixels stay identical.
    public static func optimize(_ original: Data) throws -> Data {
        let chunks = try PNGFile.chunks(in: original)
        guard !chunks.contains(where: { $0.type == "acTL" }),
            let source = CGImageSourceCreateWithData(original as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let pixels = PixelBuffer(exactly: image)
        else { return original }
        let ancillary = chunks.filter { PNGFile.portableAncillaryTypes.contains($0.type) }
        // Gray PNGs cannot carry RGB profiles.
        let allowsGray = !chunks.contains { $0.type == "iCCP" }
        let candidate = try encodeLossless(pixels, ancillary: ancillary, allowsGray: allowsGray)
        guard candidate.count < original.count, try decodesIdentically(candidate, to: pixels) else { return original }
        return candidate
    }

    public static func encodeLossless(_ pixels: PixelBuffer, ancillary: [PNGChunk], allowsGray: Bool) throws -> Data {
        guard pixels.pixelCount > 0 else { throw FormatError.encoderFailure("empty image") }
        var best: (size: Int, raster: PNGRaster, transparency: [UInt8]?, strategy: PNGFilterStrategy)?
        for (raster, transparency) in rasters(for: pixels, allowsGray: allowsGray) {
            let strategies: [PNGFilterStrategy] = raster.colorType == .palette ? [.none] : PNGFilterStrategy.allCases
            for strategy in strategies {
                let trial = try PNGFile.encode(
                    raster, transparency: transparency, strategy: strategy, level: PNGFile.trialLevel
                )
                if trial.count < best?.size ?? .max { best = (trial.count, raster, transparency, strategy) }
            }
        }
        guard let best else { throw FormatError.encoderFailure("no PNG candidate") }
        return try PNGFile.encode(
            best.raster, transparency: best.transparency, ancillary: ancillary, strategy: best.strategy,
            level: PNGFile.maximumLevel
        )
    }

    static func decodesIdentically(_ candidate: Data, to pixels: PixelBuffer) throws -> Bool {
        guard let source = CGImageSourceCreateWithData(candidate as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        return try PixelBuffer(cgImage: image).rgba == pixels.rgba
    }

    private static func rasters(for pixels: PixelBuffer, allowsGray: Bool) -> [(PNGRaster, [UInt8]?)] {
        let opaque = pixels.isOpaque
        let gray =
            allowsGray
            && stride(from: 0, to: pixels.rgba.count, by: 4).allSatisfy { index in
                pixels.rgba[index] == pixels.rgba[index + 1] && pixels.rgba[index] == pixels.rgba[index + 2]
            }
        var candidates: [(PNGRaster, [UInt8]?)] = []
        if let palette = paletteRaster(for: pixels) { candidates.append(palette) }
        if gray {
            let channels = opaque ? [0] : [0, 3]
            let samples = stride(from: 0, to: pixels.rgba.count, by: 4).flatMap { base in
                channels.map { pixels.rgba[base + $0] }
            }
            let depth = opaque ? grayDepth(samples) : 8
            candidates.append(
                (
                    PNGRaster(
                        width: pixels.width, height: pixels.height, colorType: opaque ? .gray : .grayAlpha,
                        bitDepth: depth,
                        samples: depth == 8
                            ? samples
                            : pack(
                                samples.map { $0 / UInt8(255 / ((1 << depth) - 1)) }, depth: depth, width: pixels.width)
                    ), nil
                ))
        } else {
            let samples =
                opaque
                ? stride(from: 0, to: pixels.rgba.count, by: 4).flatMap { pixels.rgba[$0..<($0 + 3)] }
                : pixels.rgba
            candidates.append(
                (
                    PNGRaster(
                        width: pixels.width, height: pixels.height, colorType: opaque ? .rgb : .rgba, bitDepth: 8,
                        samples: samples),
                    nil
                ))
        }
        return candidates
    }

    private static func grayDepth(_ samples: [UInt8]) -> Int {
        for depth in [1, 2, 4] where samples.allSatisfy({ $0 % UInt8(255 / ((1 << depth) - 1)) == 0 }) {
            return depth
        }
        return 8
    }

    private static func paletteRaster(for pixels: PixelBuffer) -> (PNGRaster, [UInt8]?)? {
        var counts: [UInt32: Int] = [:]
        for base in stride(from: 0, to: pixels.rgba.count, by: 4) {
            counts[packed(pixels.rgba, base), default: 0] += 1
            if counts.count > 256 { return nil }
        }
        let ordered = counts.sorted { lhs, rhs in
            let (leftAlpha, rightAlpha) = (lhs.key & 0xFF, rhs.key & 0xFF)
            if (leftAlpha == 255) != (rightAlpha == 255) { return leftAlpha != 255 }
            return lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        let lookup = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.key, UInt8($0.offset)) })
        let palette = ordered.map { entry in
            PaletteColor(
                red: UInt8(entry.key >> 24), green: UInt8(entry.key >> 16 & 0xFF), blue: UInt8(entry.key >> 8 & 0xFF),
                alpha: UInt8(entry.key & 0xFF)
            )
        }
        let indices = stride(from: 0, to: pixels.rgba.count, by: 4).compactMap { lookup[packed(pixels.rgba, $0)] }
        return paletteRaster(indices: indices, palette: palette, width: pixels.width, height: pixels.height)
    }

    static func paletteRaster(indices: [UInt8], palette: [PaletteColor], width: Int, height: Int) -> (
        PNGRaster, [UInt8]?
    ) {
        let depth = palette.count <= 2 ? 1 : palette.count <= 4 ? 2 : palette.count <= 16 ? 4 : 8
        let raster = PNGRaster(
            width: width, height: height, colorType: .palette, bitDepth: depth,
            samples: pack(indices, depth: depth, width: width), palette: palette
        )
        let transparency = palette.prefix { $0.alpha < 255 }.map(\.alpha)
        return (raster, transparency.isEmpty ? nil : transparency)
    }

    private static func packed(_ rgba: [UInt8], _ base: Int) -> UInt32 {
        UInt32(rgba[base]) << 24 | UInt32(rgba[base + 1]) << 16 | UInt32(rgba[base + 2]) << 8 | UInt32(rgba[base + 3])
    }

    static func pack(_ values: [UInt8], depth: Int, width: Int) -> [UInt8] {
        guard depth < 8 else { return values }
        let perByte = 8 / depth
        let rowBytes = (width * depth + 7) / 8
        let height = values.count / width
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = values[y * width + x]
                let shift = 8 - depth * (x % perByte + 1)
                output[y * rowBytes + x / perByte] |= value << shift
            }
        }
        return output
    }
}
