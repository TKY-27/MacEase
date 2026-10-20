import Foundation

/// Bitmap to stacked, filled cubic-Bézier SVG paths.
public enum SVGTracer {
    public static let maximumColors = 8
    private static let simplification = 0.8
    private static let fitError = 0.6
    private static let cornerAngle = Double.pi / 3.2
    private static let minimumArea = 3.0

    public struct Layer: Sendable {
        public var color: PaletteColor
        public var contours: [[BezierSegment]]
    }

    /// One means a single dark layer.
    public static func trace(_ pixels: PixelBuffer, colors: Int) -> [Layer] {
        let labels = colors <= 1 ? monochromeLabels(pixels) : colorLabels(pixels, count: min(colors, maximumColors))
        let order = labels.palette.indices.sorted { labels.counts[$0] > labels.counts[$1] }
            .filter { labels.counts[$0] > 0 }
        var layers: [Layer] = []
        for (position, label) in order.enumerated() {
            let covered = Set(order[position...])
            var mask = [Bool](repeating: false, count: pixels.pixelCount)
            for pixel in mask.indices where labels.map[pixel] >= 0 && covered.contains(Int(labels.map[pixel])) {
                mask[pixel] = true
            }
            let contours = Contours.trace(mask, width: pixels.width, height: pixels.height)
                .filter { abs(Contours.signedArea($0)) >= minimumArea }
                .map { fit($0) }
            layers.append(Layer(color: labels.palette[label], contours: contours))
        }
        return layers
    }

    public static func svg(_ layers: [Layer], width: Int, height: Int) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(width)" height="\#(height)" viewBox="0 0 \#(width) \#(height)">"#,
        ]
        for layer in layers where !layer.contours.isEmpty {
            let color = String(format: "#%02x%02x%02x", layer.color.red, layer.color.green, layer.color.blue)
            let opacity = layer.color.alpha < 255 ? #" fill-opacity="\#(Double(layer.color.alpha) / 255)""# : ""
            lines.append(#"<path fill="\#(color)"\#(opacity) fill-rule="evenodd" d="\#(pathData(layer.contours))"/>"#)
        }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func pathData(_ contours: [[BezierSegment]]) -> String {
        contours.compactMap { segments -> String? in
            guard let first = segments.first else { return nil }
            var parts = ["M\(number(first.start.x)) \(number(first.start.y))"]
            for segment in segments {
                parts.append(
                    "C\(number(segment.control1.x)) \(number(segment.control1.y)) "
                        + "\(number(segment.control2.x)) \(number(segment.control2.y)) "
                        + "\(number(segment.end.x)) \(number(segment.end.y))"
                )
            }
            return parts.joined() + "Z"
        }.joined()
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    struct Labels {
        var map: [Int16]
        var palette: [PaletteColor]
        var counts: [Int]
    }

    private static func monochromeLabels(_ pixels: PixelBuffer) -> Labels {
        let luma = (0..<pixels.pixelCount).map { pixel -> Int in
            let base = pixel * 4
            return (299 * Int(pixels.rgba[base]) + 587 * Int(pixels.rgba[base + 1]) + 114 * Int(pixels.rgba[base + 2]))
                / 1000
        }
        let threshold = otsuThreshold(
            luma, alpha: stride(from: 3, to: pixels.rgba.count, by: 4).map { pixels.rgba[$0] })
        var map = [Int16](repeating: -1, count: pixels.pixelCount)
        var count = 0
        for pixel in map.indices
        where pixels.rgba[pixel * 4 + 3] >= PaletteColor.opacityCutoff && luma[pixel] < threshold {
            map[pixel] = 0
            count += 1
        }
        return Labels(map: map, palette: [PaletteColor(red: 0, green: 0, blue: 0, alpha: 255)], counts: [count])
    }

    private static func otsuThreshold(_ luma: [Int], alpha: [UInt8]) -> Int {
        var histogram = [Double](repeating: 0, count: 256)
        for (value, opacity) in zip(luma, alpha) where opacity >= PaletteColor.opacityCutoff { histogram[value] += 1 }
        let total = histogram.reduce(0, +)
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        var backgroundWeight = 0.0
        var backgroundSum = 0.0
        var best = (threshold: 128, variance: -1.0)
        for value in 0..<256 {
            backgroundWeight += histogram[value]
            guard backgroundWeight > 0, total - backgroundWeight > 0 else { continue }
            backgroundSum += Double(value) * histogram[value]
            let meanBackground = backgroundSum / backgroundWeight
            let meanForeground = (sum - backgroundSum) / (total - backgroundWeight)
            let variance = backgroundWeight * (total - backgroundWeight) * pow(meanBackground - meanForeground, 2)
            if variance > best.variance { best = (value + 1, variance) }
        }
        return best.threshold
    }

    private static func colorLabels(_ pixels: PixelBuffer, count: Int) -> Labels {
        let quantizer = ColorQuantizer(includesAlpha: false)
        let transparent = { (pixel: Int) in pixels.rgba[pixel * 4 + 3] < PaletteColor.opacityCutoff }
        let palette =
            ColorQuantizer.exactPalette(of: pixels.rgba, limit: count, includesAlpha: false, skip: transparent)
            ?? quantizer.palette(
                from: ColorQuantizer.samples(of: pixels.rgba, includesAlpha: false, skip: transparent), count: count)
        var mapper = PaletteMapper(palette: palette, includesAlpha: false, dithering: .none)
        var map = [Int16](repeating: -1, count: pixels.pixelCount)
        var counts = [Int](repeating: 0, count: palette.count)
        for pixel in map.indices where !transparent(pixel) {
            let base = pixel * 4
            let index = mapper.index(
                red: pixels.rgba[base], green: pixels.rgba[base + 1], blue: pixels.rgba[base + 2], alpha: 255)
            map[pixel] = Int16(index)
            counts[index] += 1
        }
        return Labels(map: map, palette: palette, counts: counts)
    }

    /// Splits at Douglas–Peucker corners, then fits.
    static func fit(_ loop: [Point]) -> [BezierSegment] {
        let kept = Simplifier.closedLoop(loop, epsilon: simplification)
        let corners = kept.filter { index in
            let previous = loop[(index - 2 + loop.count) % loop.count]
            let next = loop[(index + 2) % loop.count]
            return turningAngle(previous, loop[index], next) > cornerAngle
        }
        let anchors = corners.isEmpty ? [kept.first ?? 0] : corners
        var segments: [BezierSegment] = []
        for (position, start) in anchors.enumerated() {
            let end = anchors[(position + 1) % anchors.count]
            var run: [Point] = []
            var index = start
            repeat {
                run.append(loop[index])
                index = (index + 1) % loop.count
            } while index != end
            run.append(loop[end])
            let smoothJoin = corners.isEmpty
            let reach = min(3, run.count - 1)
            let startTangent = smoothJoin ? centerTangent(loop, at: start) : (run[reach] - run[0]).normalized
            let endTangent =
                smoothJoin
                ? -centerTangent(loop, at: end) : (run[run.count - 1 - reach] - run[run.count - 1]).normalized
            segments += CurveFitter.fit(run, startTangent: startTangent, endTangent: endTangent, error: fitError)
        }
        return segments
    }

    private static func turningAngle(_ a: Point, _ b: Point, _ c: Point) -> Double {
        let first = (b - a).normalized
        let second = (c - b).normalized
        return acos(min(max(first.dot(second), -1), 1))
    }

    private static func centerTangent(_ loop: [Point], at index: Int) -> Point {
        (loop[(index + 2) % loop.count] - loop[(index - 2 + loop.count) % loop.count]).normalized
    }
}
