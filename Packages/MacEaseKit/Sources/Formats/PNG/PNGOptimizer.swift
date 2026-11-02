import CoreGraphics
import Foundation
import ImageIO

public enum PNGOptimizer {
    private static let cancellationCheckMask = 4_095
    /// Never larger than `original`; pixels stay identical.
    public static func optimize(
        _ original: Data, maximumBytes: Int64? = nil, maximumCompression: Bool = true,
        cancelled: (() -> Bool)? = nil
    ) throws -> Data {
        if cancelled?() == true { throw CancellationError() }
        let chunks = try PNGFile.chunks(in: original)
        guard !chunks.contains(where: { $0.type == "acTL" }),
            let source = CGImageSourceCreateWithData(original as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return original }
        let hasProfile = chunks.contains { $0.type == "iCCP" }
        guard image.colorSpace?.model == .rgb || !hasProfile,
            let pixels = PixelBuffer(exactly: image)
        else { return original }
        let ancillary = chunks.filter { PNGFile.portableAncillaryTypes.contains($0.type) }
        // Gray PNGs cannot carry RGB profiles.
        let allowsGray = !chunks.contains { $0.type == "iCCP" }
        let candidate = try encodeLossless(
            pixels, ancillary: ancillary, allowsGray: allowsGray, maximumBytes: maximumBytes,
            maximumCompression: maximumCompression, cancelled: cancelled)
        guard candidate.count < original.count, try decodesIdentically(candidate, to: pixels) else { return original }
        return candidate
    }

    public static func encodeLossless(
        _ pixels: PixelBuffer, ancillary: [PNGChunk], allowsGray: Bool,
        maximumBytes: Int64? = nil, maximumCompression: Bool = true, cancelled: (() -> Bool)? = nil
    ) throws -> Data {
        guard pixels.pixelCount > 0 else { throw FormatError.encoderFailure("empty image") }
        var best: (size: Int, raster: PNGRaster, transparency: [UInt8]?, strategy: PNGFilterStrategy)?
        for (raster, transparency) in try rasters(for: pixels, allowsGray: allowsGray, cancelled: cancelled) {
            let strategies: [PNGFilterStrategy] = raster.colorType == .palette ? [.none] : PNGFilterStrategy.allCases
            for strategy in strategies {
                let trial = try PNGFile.encode(
                    sampled(raster), transparency: transparency, strategy: strategy, level: PNGFile.trialLevel,
                    cancelled: cancelled
                )
                if trial.count < best?.size ?? .max { best = (trial.count, raster, transparency, strategy) }
            }
        }
        guard let best else { throw FormatError.encoderFailure("no PNG candidate") }
        let prepared = try PNGFile.prepare(
            best.raster, transparency: best.transparency, ancillary: ancillary, strategy: best.strategy,
            cancelled: cancelled)
        if maximumBytes != nil || !maximumCompression {
            do {
                if cancelled?() == true { throw CancellationError() }
                let balanced = try PNGFile.encode(
                    prepared, level: PNGFile.trialLevel, maximumCompressedBytes: maximumBytes)
                if !maximumCompression || maximumBytes.map({ Int64(balanced.count) <= $0 }) == true { return balanced }
            } catch PNGOutputError.sizeLimitExceeded {
                if !maximumCompression { throw PNGOutputError.sizeLimitExceeded }
            }
        }
        if cancelled?() == true { throw CancellationError() }
        return try PNGFile.encode(
            prepared, level: PNGFile.maximumLevel, maximumCompressedBytes: maximumBytes)
    }

    static func sampled(_ raster: PNGRaster) -> PNGRaster {
        let maximumRows = 64
        guard raster.height > maximumRows else { return raster }
        var sample = raster
        sample.height = maximumRows
        var samples = [UInt8]()
        samples.reserveCapacity(raster.sourceRowBytes * maximumRows)
        raster.samples.withUnsafeBytes { bytes in
            for row in 0..<maximumRows {
                let sourceRow = row * (raster.height - 1) / (maximumRows - 1)
                let offset = sourceRow * raster.sourceRowBytes
                samples.append(contentsOf: bytes[offset..<(offset + raster.sourceRowBytes)])
            }
        }
        sample.samples = samples
        return sample
    }

    static func decodesIdentically(_ candidate: Data, to pixels: PixelBuffer) throws -> Bool {
        guard let source = CGImageSourceCreateWithData(candidate as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        return try PixelBuffer(cgImage: image).rgba == pixels.rgba
    }

    private static func rasters(
        for pixels: PixelBuffer, allowsGray: Bool, cancelled: (() -> Bool)?
    ) throws -> [(PNGRaster, [UInt8]?)] {
        var opaque = true
        var gray = allowsGray
        for base in stride(from: 0, to: pixels.rgba.count, by: 4) {
            if base & (Self.cancellationCheckMask << 2) == 0, cancelled?() == true { throw CancellationError() }
            opaque = opaque && pixels.rgba[base + 3] == 255
            gray = gray && pixels.rgba[base] == pixels.rgba[base + 1] && pixels.rgba[base] == pixels.rgba[base + 2]
            if !opaque && !gray { break }
        }
        var candidates: [(PNGRaster, [UInt8]?)] = []
        if let palette = try paletteRaster(for: pixels, cancelled: cancelled) { candidates.append(palette) }
        if gray {
            let channels = opaque ? [0] : [0, 3]
            var samples = [UInt8](repeating: 0, count: pixels.pixelCount * channels.count)
            for pixel in 0..<pixels.pixelCount {
                if pixel & Self.cancellationCheckMask == 0, cancelled?() == true { throw CancellationError() }
                for (offset, channel) in channels.enumerated() {
                    samples[pixel * channels.count + offset] = pixels.rgba[pixel * 4 + channel]
                }
            }
            let depth = opaque ? try grayDepth(samples, cancelled: cancelled) : 8
            var packed = samples
            if depth < 8 {
                let levels: Int = (1 << depth) - 1
                let step = UInt8(255 / levels)
                for index in packed.indices {
                    if index & Self.cancellationCheckMask == 0, cancelled?() == true { throw CancellationError() }
                    packed[index] /= step
                }
                packed = try pack(packed, depth: depth, width: pixels.width, cancelled: cancelled)
            }
            let raster = PNGRaster(
                width: pixels.width, height: pixels.height, colorType: opaque ? .gray : .grayAlpha, bitDepth: depth,
                samples: packed
            )
            candidates.append((raster, nil))
        } else {
            let raster: PNGRaster
            if opaque {
                raster = PNGRaster(
                    width: pixels.width, height: pixels.height, colorType: .rgb, bitDepth: 8,
                    samples: pixels.rgba, omitsOpaqueAlpha: true)
            } else {
                raster = PNGRaster(
                    width: pixels.width, height: pixels.height, colorType: .rgba, bitDepth: 8, samples: pixels.rgba)
            }
            candidates.append((raster, nil))
        }
        return candidates
    }

    private static func grayDepth(_ samples: [UInt8], cancelled: (() -> Bool)?) throws -> Int {
        for depth in [1, 2, 4] {
            let step = UInt8(255 / ((1 << depth) - 1))
            var matches = true
            for index in samples.indices {
                if index & Self.cancellationCheckMask == 0, cancelled?() == true { throw CancellationError() }
                if samples[index] % step != 0 { matches = false; break }
            }
            if matches { return depth }
        }
        return 8
    }

    private static func paletteRaster(for pixels: PixelBuffer, cancelled: (() -> Bool)?) throws -> (
        PNGRaster, [UInt8]?
    )? {
        var counts: [UInt32: Int] = [:]
        for base in stride(from: 0, to: pixels.rgba.count, by: 4) {
            if base & (Self.cancellationCheckMask << 2) == 0, cancelled?() == true { throw CancellationError() }
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
        var indices = [UInt8](repeating: 0, count: pixels.pixelCount)
        for pixel in indices.indices {
            if pixel & Self.cancellationCheckMask == 0, cancelled?() == true { throw CancellationError() }
            guard let index = lookup[packed(pixels.rgba, pixel * 4)] else {
                throw FormatError.encoderFailure("palette lookup")
            }
            indices[pixel] = index
        }
        return try paletteRaster(
            indices: indices, palette: palette, width: pixels.width, height: pixels.height, cancelled: cancelled)
    }

    static func paletteRaster<Indices: ContiguousBytes & Collection & Sendable>(
        indices: Indices, palette: [PaletteColor], width: Int, height: Int, cancelled: (() -> Bool)? = nil
    ) throws -> (
        PNGRaster, [UInt8]?
    ) where Indices.Element == UInt8 {
        let depth = palette.count <= 2 ? 1 : palette.count <= 4 ? 2 : palette.count <= 16 ? 4 : 8
        let raster: PNGRaster
        if depth == 8 {
            raster = PNGRaster(
                width: width, height: height, colorType: .palette, bitDepth: depth, samples: indices, palette: palette)
        } else {
            raster = PNGRaster(
                width: width, height: height, colorType: .palette, bitDepth: depth,
                samples: try pack(indices, depth: depth, width: width, cancelled: cancelled), palette: palette)
        }
        let transparency = palette.prefix { $0.alpha < 255 }.map(\.alpha)
        return (raster, transparency.isEmpty ? nil : transparency)
    }

    private static func packed(_ rgba: [UInt8], _ base: Int) -> UInt32 {
        UInt32(rgba[base]) << 24 | UInt32(rgba[base + 1]) << 16 | UInt32(rgba[base + 2]) << 8 | UInt32(rgba[base + 3])
    }

    static func pack<Values: ContiguousBytes & Collection>(
        _ values: Values, depth: Int, width: Int, cancelled: (() -> Bool)? = nil
    ) throws -> [UInt8] where Values.Element == UInt8 {
        guard depth < 8 else { return Array(values) }
        let perByte = 8 / depth
        let rowBytes = (width * depth + 7) / 8
        let height = values.count / width
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        try values.withUnsafeBytes { bytes in
            for y in 0..<height {
                if cancelled?() == true { throw CancellationError() }
                for x in 0..<width {
                    let value = bytes[y * width + x]
                    let shift = 8 - depth * (x % perByte + 1)
                    output[y * rowBytes + x / perByte] |= value << shift
                }
            }
        }
        return output
    }
}
