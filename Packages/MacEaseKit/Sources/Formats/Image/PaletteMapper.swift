import Foundation
import simd

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
    private let exactPalette: [PaletteColor: Int]
    private let transparentIndex: Int?
    /// Dithered colors share 6-bit cells.
    private let coarse: Bool
    private var cells: [UInt16]
    private static let cacheCount = 1 << 18
    private static let cacheMultiplier: UInt32 = 2_654_435_761
    private static let cancellationCheckMask = 4_095
    private var exactKeys: [UInt32]
    private var exactValues: [UInt16]
    private let search: PaletteSearch

    /// `transparentIndex` receives pixels below the opacity cutoff.
    init(palette: [PaletteColor], includesAlpha: Bool, dithering: Dithering, transparentIndex: Int? = nil) {
        self.palette = palette
        let quantizer = ColorQuantizer(includesAlpha: includesAlpha)
        self.quantizer = quantizer
        self.transparentIndex = transparentIndex
        exactPalette = palette.enumerated().reduce(into: [:]) { lookup, entry in
            if entry.offset != transparentIndex, lookup[entry.element] == nil { lookup[entry.element] = entry.offset }
        }
        let points = palette.enumerated().map { index, color in
            index == transparentIndex ? SIMD4(repeating: .greatestFiniteMagnitude) : quantizer.point(color)
        }
        search = PaletteSearch(points: points)
        coarse = dithering != .none
        exactKeys = dithering == .none ? [UInt32](repeating: 0, count: Self.cacheCount) : []
        exactValues = dithering == .none ? [UInt16](repeating: .max, count: Self.cacheCount) : []
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
        let slot = Int((key &* Self.cacheMultiplier) >> 14)
        if exactValues[slot] != .max, exactKeys[slot] == key { return Int(exactValues[slot]) }
        let nearest = nearestIndex(PaletteColor(red: red, green: green, blue: blue, alpha: opacity))
        exactKeys[slot] = key
        exactValues[slot] = UInt16(nearest)
        return nearest
    }

    private func nearestIndex(_ color: PaletteColor) -> Int {
        exactPalette[color] ?? search.nearest(quantizer.point(color))
    }

    mutating func map(_ pixels: [UInt8], width: Int, height: Int, dithering: Dithering, cancelled: (() -> Bool)? = nil)
        -> [UInt8]
    {
        var indices = [UInt8](repeating: 0, count: pixels.count / 4)
        let completed = indices.withUnsafeMutableBytes { destination in
            map(pixels, width: width, height: height, dithering: dithering, into: destination, cancelled: cancelled)
        }
        return completed ? indices : []
    }

    mutating func map(
        _ pixels: [UInt8], width: Int, height: Int, dithering: Dithering,
        into indices: UnsafeMutableRawBufferPointer, cancelled: (() -> Bool)? = nil
    ) -> Bool {
        switch dithering {
        case .none: mapDirect(pixels, into: indices, cancelled: cancelled)
        case .ordered: mapOrdered(pixels, width: width, into: indices, cancelled: cancelled)
        case .floydSteinberg:
            mapDiffused(pixels, width: width, height: height, into: indices, cancelled: cancelled)
        }
    }

    private mutating func mapDirect(
        _ pixels: [UInt8], into indices: UnsafeMutableRawBufferPointer, cancelled: (() -> Bool)?
    ) -> Bool {
        for base in stride(from: 0, to: pixels.count, by: 4) {
            if base & (Self.cancellationCheckMask << 2) == 0, cancelled?() == true { return false }
            indices[base / 4] = UInt8(
                index(red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2], alpha: pixels[base + 3]))
        }
        return true
    }

    private mutating func mapOrdered(
        _ pixels: [UInt8], width: Int, into indices: UnsafeMutableRawBufferPointer, cancelled: (() -> Bool)?
    ) -> Bool {
        let amplitude = Self.orderedAmplitude
        for base in stride(from: 0, to: pixels.count, by: 4) {
            if base & (Self.cancellationCheckMask << 2) == 0, cancelled?() == true { return false }
            let pixel = base / 4
            let threshold = Self.bayer[(pixel / width % 8) * 8 + pixel % width % 8] * amplitude
            let channel = { (value: UInt8) in UInt8(min(max(Float(value) + threshold, 0), 255)) }
            indices[pixel] = UInt8(
                index(
                    red: channel(pixels[base]), green: channel(pixels[base + 1]), blue: channel(pixels[base + 2]),
                    alpha: pixels[base + 3]
                )
            )
        }
        return true
    }

    private mutating func mapDiffused(
        _ pixels: [UInt8], width: Int, height: Int, into indices: UnsafeMutableRawBufferPointer,
        cancelled: (() -> Bool)?
    ) -> Bool {
        var current = [SIMD4<Float>](repeating: .zero, count: width + 2)
        var next = [SIMD4<Float>](repeating: .zero, count: width + 2)
        for y in 0..<height {
            if cancelled?() == true { return false }
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
        return true
    }
}

private struct PaletteSearch {
    private struct Node {
        let index: Int
        let axis: Int
        let left: Int
        let right: Int
    }
    private let points: [SIMD4<Float>]
    private var nodes: [Node] = []
    private var root = -1

    init(points: [SIMD4<Float>]) {
        self.points = points
        root = build(Array(points.indices))
    }

    private mutating func build(_ indices: [Int]) -> Int {
        guard !indices.isEmpty else { return -1 }
        var minimum = SIMD4<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD4<Float>(repeating: -.greatestFiniteMagnitude)
        for index in indices {
            minimum = pointwiseMin(minimum, points[index])
            maximum = pointwiseMax(maximum, points[index])
        }
        let spans = maximum - minimum
        let axis = (0..<4).max { spans[$0] < spans[$1] } ?? 0
        let ordered = indices.sorted { points[$0][axis] < points[$1][axis] }
        let middle = ordered.count / 2
        let left = build(Array(ordered[..<middle]))
        let right = build(Array(ordered[(middle + 1)...]))
        nodes.append(Node(index: ordered[middle], axis: axis, left: left, right: right))
        return nodes.count - 1
    }

    func nearest(_ point: SIMD4<Float>) -> Int {
        var best = 0
        var distance = Float.greatestFiniteMagnitude
        visit(root, point, best: &best, distance: &distance)
        return best
    }

    private func visit(_ branch: Int, _ point: SIMD4<Float>, best: inout Int, distance: inout Float) {
        guard branch >= 0 else { return }
        let node = nodes[branch]
        let candidate = simd_distance_squared(point, points[node.index])
        if candidate < distance || candidate == distance && node.index < best {
            best = node.index
            distance = candidate
        }
        let delta = point[node.axis] - points[node.index][node.axis]
        let near = delta < 0 ? node.left : node.right
        let far = delta < 0 ? node.right : node.left
        visit(near, point, best: &best, distance: &distance)
        if delta * delta <= distance { visit(far, point, best: &best, distance: &distance) }
    }
}
