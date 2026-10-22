import Foundation

/// Nearest-color lookup, memoized per color.
struct PaletteMapper {
    static let bayer: [Float] = {
        let matrix: [Int] = [
            0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20,
            62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37,
            63, 31, 55, 23, 61, 29, 53, 21,
        ]
        return matrix.map { Float($0) / 64 - 0.5 }
    }()

    /// Threshold scale; larger patterns cost SSIM.
    static let orderedAmplitude: Float = 4
    /// Partial diffusion keeps dither noise low.
    static let diffusion: Float = 0.75
    let palette: [PaletteColor]
    private let quantizer: ColorQuantizer
    private let points: [SIMD4<Float>]
    private let transparentIndex: Int?
    /// Dithered colors share 6-bit cells.
    private let coarse: Bool
    private var cells: [UInt16]
    private var exact: [UInt32: UInt16] = [:]

    /// `transparentIndex` receives pixels below the opacity cutoff.
    init(palette: [PaletteColor], includesAlpha: Bool, dithering: Dithering, transparentIndex: Int? = nil) {
        self.palette = palette
        let quantizer = ColorQuantizer(includesAlpha: includesAlpha)
        self.quantizer = quantizer
        self.transparentIndex = transparentIndex
        points = palette.enumerated().map { index, color in
            index == transparentIndex ? SIMD4(repeating: .greatestFiniteMagnitude) : quantizer.point(color)
        }
        coarse = dithering != .none
        cells = coarse ? [UInt16](repeating: .max, count: 1 << (includesAlpha ? 22 : 18)) : []
    }

    mutating func index(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Int {
        if let transparentIndex, alpha < PaletteColor.opacityCutoff { return transparentIndex }
        let opacity = quantizer.includesAlpha ? alpha : 255
        if coarse {
            var key = Int(red >> 2) << 12 | Int(green >> 2) << 6 | Int(blue >> 2)
            if quantizer.includesAlpha { key = key << 4 | Int(alpha >> 4) }
            if cells[key] != .max { return Int(cells[key]) }
            let nearest = nearestIndex(PaletteColor(red: red, green: green, blue: blue, alpha: opacity))
            cells[key] = UInt16(nearest)
            return nearest
        }
        let key = UInt32(red) << 24 | UInt32(green) << 16 | UInt32(blue) << 8 | UInt32(opacity)
        if let known = exact[key] { return Int(known) }
        let nearest = nearestIndex(PaletteColor(red: red, green: green, blue: blue, alpha: opacity))
        exact[key] = UInt16(nearest)
        return nearest
    }

    private func nearestIndex(_ color: PaletteColor) -> Int {
        if let match = palette.firstIndex(of: color), match != transparentIndex { return match }
        return ColorQuantizer.nearest(quantizer.point(color), in: points)
    }

    mutating func map(_ pixels: [UInt8], width: Int, height: Int, dithering: Dithering) -> [UInt8] {
        switch dithering {
        case .none: mapDirect(pixels)
        case .ordered: mapOrdered(pixels, width: width)
        case .floydSteinberg: mapDiffused(pixels, width: width, height: height)
        }
    }

    private mutating func mapDirect(_ pixels: [UInt8]) -> [UInt8] {
        stride(from: 0, to: pixels.count, by: 4).map { base in
            UInt8(index(red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2], alpha: pixels[base + 3]))
        }
    }

    private mutating func mapOrdered(_ pixels: [UInt8], width: Int) -> [UInt8] {
        let amplitude = Self.orderedAmplitude
        return stride(from: 0, to: pixels.count, by: 4).map { base in
            let pixel = base / 4
            let threshold = Self.bayer[(pixel / width % 8) * 8 + pixel % width % 8] * amplitude
            let channel = { (value: UInt8) in UInt8(min(max(Float(value) + threshold, 0), 255)) }
            return UInt8(
                index(
                    red: channel(pixels[base]), green: channel(pixels[base + 1]), blue: channel(pixels[base + 2]),
                    alpha: pixels[base + 3]
                )
            )
        }
    }

    private mutating func mapDiffused(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var indices = [UInt8](repeating: 0, count: width * height)
        var current = [SIMD4<Float>](repeating: .zero, count: width + 2)
        var next = [SIMD4<Float>](repeating: .zero, count: width + 2)
        for y in 0..<height {
            let leftToRight = y % 2 == 0
            for step in 0..<width {
                let x = leftToRight ? step : width - 1 - step
                let base = (y * width + x) * 4
                let original = SIMD4<Float>(
                    Float(pixels[base]), Float(pixels[base + 1]), Float(pixels[base + 2]), Float(pixels[base + 3])
                )
                let wanted = (original + current[x + 1]).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255))
                let chosen = index(
                    red: UInt8(wanted.x.rounded()), green: UInt8(wanted.y.rounded()), blue: UInt8(wanted.z.rounded()),
                    alpha: UInt8(wanted.w.rounded())
                )
                indices[y * width + x] = UInt8(chosen)
                let color = palette[chosen]
                let produced = SIMD4<Float>(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha))
                var error = chosen == transparentIndex ? .zero : (wanted - produced) * Self.diffusion
                if !quantizer.includesAlpha { error.w = 0 }
                let forward = leftToRight ? 1 : -1
                current[x + 1 + forward] += error * (7 / 16)
                next[x + 1 - forward] += error * (3 / 16)
                next[x + 1] += error * (5 / 16)
                next[x + 1 + forward] += error * (1 / 16)
            }
            swap(&current, &next)
            next = [SIMD4<Float>](repeating: .zero, count: width + 2)
        }
        return indices
    }
}
