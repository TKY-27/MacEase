import Foundation

/// Schneider's least-squares cubic fitting (Graphics Gems, 1990).
enum CurveFitter {
    private static let reparameterizations = 4

    /// `error` is a squared pixel distance.
    static func fit(_ points: [Point], startTangent: Point, endTangent: Point, error: Double) -> [BezierSegment] {
        guard points.count >= 2 else { return [] }
        return fitCubic(points[...], startTangent: startTangent, endTangent: endTangent, error: error)
    }

    private static func fitCubic(
        _ points: ArraySlice<Point>,
        startTangent: Point,
        endTangent: Point,
        error: Double
    ) -> [BezierSegment] {
        let first = points[points.startIndex]
        let last = points[points.endIndex - 1]
        if points.count == 2 {
            let third = first.distance(to: last) / 3
            return [
                BezierSegment(
                    start: first, control1: first + startTangent * third, control2: last + endTangent * third, end: last
                )
            ]
        }
        var parameters = chordLengths(points)
        var curve = generate(points, parameters, startTangent, endTangent)
        var (maximum, split) = maximumError(points, curve, parameters)
        if maximum < error { return [curve] }
        if maximum < error * 4 {
            for _ in 0..<reparameterizations {
                parameters = reparameterize(points, parameters, curve)
                curve = generate(points, parameters, startTangent, endTangent)
                (maximum, split) = maximumError(points, curve, parameters)
                if maximum < error { return [curve] }
            }
        }
        let splitIndex = min(max(split, points.startIndex + 1), points.endIndex - 2)
        let center = (points[splitIndex - 1] - points[splitIndex + 1]).normalized
        return fitCubic(
            points[points.startIndex...splitIndex], startTangent: startTangent, endTangent: center, error: error)
            + fitCubic(points[splitIndex...], startTangent: -center, endTangent: endTangent, error: error)
    }

    private static func chordLengths(_ points: ArraySlice<Point>) -> [Double] {
        var lengths = [0.0]
        for index in (points.startIndex + 1)..<points.endIndex {
            lengths.append(lengths[lengths.count - 1] + points[index].distance(to: points[index - 1]))
        }
        guard let total = lengths.last, total > 0 else { return lengths }
        return lengths.map { $0 / total }
    }

    private static func generate(
        _ points: ArraySlice<Point>,
        _ parameters: [Double],
        _ startTangent: Point,
        _ endTangent: Point
    ) -> BezierSegment {
        let first = points[points.startIndex]
        let last = points[points.endIndex - 1]
        var c00 = 0.0
        var c01 = 0.0
        var c11 = 0.0
        var x0 = 0.0
        var x1 = 0.0
        for (offset, t) in parameters.enumerated() {
            let u = 1 - t
            let a1 = startTangent * (3 * t * u * u)
            let a2 = endTangent * (3 * t * t * u)
            c00 += a1.dot(a1)
            c01 += a1.dot(a2)
            c11 += a2.dot(a2)
            let basis = first * (u * u * u + 3 * t * u * u) + last * (t * t * t + 3 * t * t * u)
            let difference = points[points.startIndex + offset] - basis
            x0 += a1.dot(difference)
            x1 += a2.dot(difference)
        }
        let determinant = c00 * c11 - c01 * c01
        let segmentLength = first.distance(to: last)
        let epsilon = 1e-6 * segmentLength
        var alphaStart = determinant == 0 ? 0 : (x0 * c11 - x1 * c01) / determinant
        var alphaEnd = determinant == 0 ? 0 : (c00 * x1 - c01 * x0) / determinant
        // Near-singular systems yield runaway handles.
        let runaway = 10 * segmentLength
        if !(alphaStart.isFinite && alphaEnd.isFinite) || alphaStart < epsilon || alphaEnd < epsilon
            || alphaStart > runaway || alphaEnd > runaway
        {
            alphaStart = segmentLength / 3
            alphaEnd = segmentLength / 3
        }
        return BezierSegment(
            start: first, control1: first + startTangent * alphaStart, control2: last + endTangent * alphaEnd, end: last
        )
    }

    private static func maximumError(
        _ points: ArraySlice<Point>,
        _ curve: BezierSegment,
        _ parameters: [Double]
    ) -> (Double, Int) {
        var maximum = 0.0
        var split = points.startIndex + points.count / 2
        for (offset, t) in parameters.enumerated() {
            let distance = curve.point(at: t) - points[points.startIndex + offset]
            let squared = distance.dot(distance)
            if squared >= maximum {
                maximum = squared
                split = points.startIndex + offset
            }
        }
        return (maximum, split)
    }

    /// Newton–Raphson toward each point's closest parameter.
    private static func reparameterize(_ points: ArraySlice<Point>, _ parameters: [Double], _ curve: BezierSegment)
        -> [Double]
    {
        parameters.enumerated().map { offset, t in
            let difference = curve.point(at: t) - points[points.startIndex + offset]
            let first = curve.derivative(at: t)
            let second = curve.secondDerivative(at: t)
            let denominator = first.dot(first) + difference.dot(second)
            guard denominator != 0 else { return t }
            return min(max(t - difference.dot(first) / denominator, 0), 1)
        }
    }
}
