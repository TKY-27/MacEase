import Foundation
import simd

public struct PaletteColor: Hashable, Sendable {
    /// Lower alpha counts as transparent.
    public static let opacityCutoff: UInt8 = 128

    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8
}

/// Wu seeds the palette; k-means refines it.
struct ColorQuantizer {
    struct Sample {
        var color: PaletteColor
        var weight: Double
    }

    /// Alpha weight in premultiplied Oklab distances.
    private static let alphaScale: Float = 1.2
    /// Luma-heavy distances favor lightness steps.
    private static let lightnessScale: Float = 6
    private static let kMeansIterations = 10
    private static let convergence: Float = 1e-10
    private static let cancellationCheckMask = 4_095

    let includesAlpha: Bool

    static func samples(
        of pixels: [UInt8], includesAlpha: Bool, skip: (Int) -> Bool = { _ in false },
        cancelled: (() -> Bool)? = nil
    ) -> [Sample] {
        for shift in [2, 3] {
            let bits = 8 - shift
            let alphaBits = includesAlpha ? 4 : 0
            var counts = [UInt32](repeating: 0, count: 1 << (3 * bits + alphaBits))
            var occupied = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                if index & (Self.cancellationCheckMask << 2) == 0, cancelled?() == true { return [] }
                if skip(index / 4) { continue }
                let key = histogramKey(pixels, index, shift: shift, alphaBits: alphaBits)
                if counts[key] == 0 { occupied += 1 }
                counts[key] += 1
            }
            if occupied > 65_536, shift == 2 { continue }
            var samples: [Sample] = []
            samples.reserveCapacity(occupied)
            for (key, count) in counts.enumerated() {
                if key & Self.cancellationCheckMask == 0, cancelled?() == true { return [] }
                if count == 0 { continue }
                samples.append(Sample(color: binCenter(key, shift: shift, alphaBits: alphaBits), weight: Double(count)))
            }
            return samples
        }
        return []
    }

    private static func histogramKey(_ pixels: [UInt8], _ index: Int, shift: Int, alphaBits: Int) -> Int {
        let bits = 8 - shift
        var key =
            Int(pixels[index] >> shift) << (2 * bits) | Int(pixels[index + 1] >> shift) << bits
            | Int(pixels[index + 2] >> shift)
        if alphaBits > 0 { key = key << alphaBits | Int(pixels[index + 3] >> 4) }
        return key
    }

    private static func binCenter(_ key: Int, shift: Int, alphaBits: Int) -> PaletteColor {
        let bits = 8 - shift
        let mask = (1 << bits) - 1
        let rgbKey = key >> alphaBits
        let half = (1 << shift) / 2
        let channel = { (value: Int) in UInt8(min(255, value << shift + half)) }
        let alpha: UInt8
        if alphaBits > 0 {
            let level = key & 0xF
            alpha = level == 0xF ? 255 : level == 0 ? 0 : UInt8(level << 4 + 8)
        } else {
            alpha = 255
        }
        return PaletteColor(
            red: channel(rgbKey >> (2 * bits) & mask), green: channel(rgbKey >> bits & mask),
            blue: channel(rgbKey & mask), alpha: alpha
        )
    }

    func point(_ color: PaletteColor) -> SIMD4<Float> {
        let lab = Oklab(red: color.red, green: color.green, blue: color.blue)
        let l = lab.l * Self.lightnessScale
        guard includesAlpha else { return SIMD4(l, lab.a, lab.b, 0) }
        let alpha = Float(color.alpha) / 255
        return SIMD4(l * alpha, lab.a * alpha, lab.b * alpha, alpha * Self.alphaScale)
    }

    func color(of point: SIMD4<Float>) -> PaletteColor {
        guard includesAlpha else {
            let (r, g, b) = Oklab(l: point.x / Self.lightnessScale, a: point.y, b: point.z).srgb
            return PaletteColor(red: r, green: g, blue: b, alpha: 255)
        }
        let alpha = min(max(point.w / Self.alphaScale, 0), 1)
        guard alpha > 0.001 else { return PaletteColor(red: 0, green: 0, blue: 0, alpha: 0) }
        let (r, g, b) = Oklab(l: point.x / alpha / Self.lightnessScale, a: point.y / alpha, b: point.z / alpha).srgb
        return PaletteColor(red: r, green: g, blue: b, alpha: UInt8((alpha * 255).rounded()))
    }

    /// Every distinct color, when they fit.
    static func exactPalette(
        of pixels: [UInt8],
        limit: Int,
        includesAlpha: Bool,
        skip: (Int) -> Bool = { _ in false },
        cancelled: (() -> Bool)? = nil
    ) -> [PaletteColor]? {
        var colors = Set<PaletteColor>()
        for base in stride(from: 0, to: pixels.count, by: 4) {
            if base & (Self.cancellationCheckMask << 2) == 0, cancelled?() == true { return nil }
            if skip(base / 4) { continue }
            let alpha = includesAlpha ? pixels[base + 3] : 255
            colors.insert(
                PaletteColor(red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2], alpha: alpha))
            if colors.count > limit { return nil }
        }
        return colors.sorted { ($0.alpha, $0.red, $0.green, $0.blue) < ($1.alpha, $1.red, $1.green, $1.blue) }
    }

    func palette(from samples: [Sample], count: Int, cancelled: (() -> Bool)? = nil) -> [PaletteColor] {
        guard !samples.isEmpty, count > 0 else { return [] }
        if samples.count <= count { return samples.map(\.color) }
        let points = samples.map { point($0.color) }
        let weights = samples.map(\.weight)
        var centers = WuSplitter(points: points, weights: weights).centers(count: count)
        if cancelled?() == true { return [] }
        centers = refine(centers, points: points, weights: weights, cancelled: cancelled)
        return Array(Set(centers.map(color(of:)))).sorted {
            ($0.alpha, $0.red, $0.green, $0.blue) < ($1.alpha, $1.red, $1.green, $1.blue)
        }
    }

    /// One Lloyd step on full-resolution pixels.
    func refined(_ palette: [PaletteColor], pixels: [UInt8], indices: [UInt8]) -> [PaletteColor] {
        var sums = [SIMD4<Double>](repeating: .zero, count: palette.count)
        var counts = [Double](repeating: 0, count: palette.count)
        for (pixel, index) in indices.enumerated() {
            let base = pixel * 4
            let color = PaletteColor(
                red: pixels[base], green: pixels[base + 1], blue: pixels[base + 2], alpha: pixels[base + 3]
            )
            sums[Int(index)] += SIMD4<Double>(point(color))
            counts[Int(index)] += 1
        }
        return palette.indices.map { index in
            counts[index] > 0 ? color(of: SIMD4<Float>(sums[index] / counts[index])) : palette[index]
        }
    }

    private func refine(
        _ initial: [SIMD4<Float>], points: [SIMD4<Float>], weights: [Double], cancelled: (() -> Bool)?
    ) -> [SIMD4<Float>] {
        var centers = initial
        for _ in 0..<Self.kMeansIterations {
            var sums = [SIMD4<Double>](repeating: .zero, count: centers.count)
            var totals = [Double](repeating: 0, count: centers.count)
            for (index, (point, weight)) in zip(points, weights).enumerated() {
                if index & Self.cancellationCheckMask == 0, cancelled?() == true { return centers }
                let nearest = Self.nearest(point, in: centers)
                sums[nearest] += SIMD4<Double>(point) * weight
                totals[nearest] += weight
            }
            var moved = false
            for index in centers.indices where totals[index] > 0 {
                let updated = SIMD4<Float>(sums[index] / totals[index])
                if simd_distance_squared(updated, centers[index]) > Self.convergence { moved = true }
                centers[index] = updated
            }
            if !moved { break }
        }
        return centers
    }

    static func nearest(_ point: SIMD4<Float>, in centers: [SIMD4<Float>]) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = simd_distance_squared(center, point)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}

/// Xiaolin Wu's variance-minimizing box split.
private struct WuSplitter {
    private static let side = 33
    private struct Box {
        var lower: SIMD3<Int>
        var upper: SIMD3<Int>
    }

    private var weight: [Double]
    private var moments: [SIMD4<Double>]
    private var squares: [Double]
    private let minimum: SIMD3<Float>
    private let range: SIMD3<Float>

    init(points: [SIMD4<Float>], weights: [Double]) {
        let count = Self.side * Self.side * Self.side
        weight = [Double](repeating: 0, count: count)
        moments = [SIMD4<Double>](repeating: .zero, count: count)
        squares = [Double](repeating: 0, count: count)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in points {
            let xyz = SIMD3(point.x, point.y, point.z)
            low = pointwiseMin(low, xyz)
            high = pointwiseMax(high, xyz)
        }
        minimum = low
        range = pointwiseMax(high - low, SIMD3(repeating: 1e-6))
        for (point, pointWeight) in zip(points, weights) {
            let coordinates = SIMD4<Double>(point)
            let index = Self.index(bin(point))
            weight[index] += pointWeight
            moments[index] += coordinates * pointWeight
            squares[index] += (coordinates * coordinates).sum() * pointWeight
        }
        accumulate()
    }

    private func bin(_ point: SIMD4<Float>) -> SIMD3<Int> {
        let normalized = (SIMD3(point.x, point.y, point.z) - minimum) / range
        let scaled = SIMD3<Int>((normalized * 31.999).rounded(.down)) &+ 1
        return pointwiseMin(pointwiseMax(scaled, SIMD3(repeating: 1)), SIMD3(repeating: 32))
    }

    private static func index(_ position: SIMD3<Int>) -> Int {
        (position.x * side + position.y) * side + position.z
    }

    private mutating func accumulate() {
        for x in 1..<Self.side {
            for y in 1..<Self.side {
                for z in 1..<Self.side {
                    let current = Self.index(SIMD3(x, y, z))
                    let neighbors = [
                        (SIMD3(x - 1, y, z), 1.0), (SIMD3(x, y - 1, z), 1), (SIMD3(x, y, z - 1), 1),
                        (SIMD3(x - 1, y - 1, z), -1), (SIMD3(x - 1, y, z - 1), -1), (SIMD3(x, y - 1, z - 1), -1),
                        (SIMD3(x - 1, y - 1, z - 1), 1),
                    ]
                    for (position, sign) in neighbors {
                        let other = Self.index(position)
                        weight[current] += sign * weight[other]
                        moments[current] += moments[other] * sign
                        squares[current] += sign * squares[other]
                    }
                }
            }
        }
    }

    private func corners(_ box: Box) -> (plus: [Int], minus: [Int]) {
        let (l, u) = (box.lower, box.upper)
        let plus = [SIMD3(u.x, u.y, u.z), SIMD3(u.x, l.y, l.z), SIMD3(l.x, u.y, l.z), SIMD3(l.x, l.y, u.z)]
        let minus = [SIMD3(u.x, u.y, l.z), SIMD3(u.x, l.y, u.z), SIMD3(l.x, u.y, u.z), SIMD3(l.x, l.y, l.z)]
        return (plus.map(Self.index), minus.map(Self.index))
    }

    private func volume(_ box: Box, _ table: [Double]) -> Double {
        let (plus, minus) = corners(box)
        return plus.reduce(0) { $0 + table[$1] } - minus.reduce(0) { $0 + table[$1] }
    }

    private func volume(_ box: Box, _ table: [SIMD4<Double>]) -> SIMD4<Double> {
        let (plus, minus) = corners(box)
        return plus.reduce(.zero) { $0 + table[$1] } - minus.reduce(.zero) { $0 + table[$1] }
    }

    private func variance(_ box: Box) -> Double {
        let boxWeight = volume(box, weight)
        guard boxWeight > 0 else { return 0 }
        let moment = volume(box, moments)
        return volume(box, squares) - (moment * moment).sum() / boxWeight
    }

    private func split(_ box: Box) -> (Box, Box)? {
        let totalWeight = volume(box, weight)
        let totalMoment = volume(box, moments)
        var best: (score: Double, axis: Int, cut: Int)?
        for axis in 0..<3 {
            for cut in (box.lower[axis] + 1)..<box.upper[axis] {
                var lowerHalf = box
                lowerHalf.upper[axis] = cut
                let lowerWeight = volume(lowerHalf, weight)
                let upperWeight = totalWeight - lowerWeight
                guard lowerWeight > 0, upperWeight > 0 else { continue }
                let lowerMoment = volume(lowerHalf, moments)
                let upperMoment = totalMoment - lowerMoment
                let score =
                    (lowerMoment * lowerMoment).sum() / lowerWeight
                    + (upperMoment * upperMoment).sum() / upperWeight
                if score > best?.score ?? -1 { best = (score, axis, cut) }
            }
        }
        guard let best else { return nil }
        var first = box
        var second = box
        first.upper[best.axis] = best.cut
        second.lower[best.axis] = best.cut
        return (first, second)
    }

    func centers(count: Int) -> [SIMD4<Float>] {
        var boxes = [Box(lower: SIMD3(repeating: 0), upper: SIMD3(repeating: 32))]
        var variances = [variance(boxes[0])]
        while boxes.count < count {
            guard let target = variances.indices.max(by: { variances[$0] < variances[$1] }), variances[target] > 0,
                let (first, second) = split(boxes[target])
            else { break }
            boxes[target] = first
            variances[target] = variance(first)
            boxes.append(second)
            variances.append(variance(second))
        }
        return boxes.compactMap { box -> SIMD4<Float>? in
            let boxWeight = volume(box, weight)
            guard boxWeight > 0 else { return nil }
            return SIMD4<Float>(volume(box, moments) / boxWeight)
        }
    }
}
