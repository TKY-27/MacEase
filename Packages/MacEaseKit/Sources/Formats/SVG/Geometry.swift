import Foundation

public struct Point: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: Point, rhs: Double) -> Point { Point(x: lhs.x * rhs, y: lhs.y * rhs) }
    static prefix func - (point: Point) -> Point { Point(x: -point.x, y: -point.y) }

    func dot(_ other: Point) -> Double { x * other.x + y * other.y }
    var length: Double { (x * x + y * y).squareRoot() }

    var normalized: Point {
        let length = self.length
        return length > 0 ? self * (1 / length) : self
    }

    func distance(to other: Point) -> Double { (self - other).length }
}

public struct BezierSegment: Hashable, Sendable {
    public var start: Point
    public var control1: Point
    public var control2: Point
    public var end: Point

    func point(at t: Double) -> Point {
        let u = 1 - t
        return start * (u * u * u) + control1 * (3 * u * u * t) + control2 * (3 * u * t * t) + end * (t * t * t)
    }

    func derivative(at t: Double) -> Point {
        let u = 1 - t
        return (control1 - start) * (3 * u * u) + (control2 - control1) * (6 * u * t) + (end - control2) * (3 * t * t)
    }

    func secondDerivative(at t: Double) -> Point {
        (control2 - control1 * 2 + start) * (6 * (1 - t)) + (end - control2 * 2 + control1) * (6 * t)
    }
}

/// Marching squares over a binary mask.
enum Contours {
    /// Closed loops in pixel coordinates.
    static func trace(_ mask: [Bool], width: Int, height: Int) -> [[Point]] {
        func inside(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x]
        }
        // Even ids are horizontal edges, odd vertical.
        let columns = width + 2
        func horizontal(_ x: Int, _ y: Int) -> Int { 2 * ((y + 1) * columns + (x + 1)) }
        func vertical(_ x: Int, _ y: Int) -> Int { 2 * ((y + 1) * columns + (x + 1)) + 1 }
        func position(_ edge: Int) -> Point {
            let cell = edge / 2
            let x = Double(cell % columns - 1)
            let y = Double(cell / columns - 1)
            return edge % 2 == 0 ? Point(x: x + 1, y: y + 0.5) : Point(x: x + 0.5, y: y + 1)
        }
        var next: [Int: Int] = [:]
        for y in -1..<height {
            if SVGTraceCancellation.isCancelled { return [] }
            for x in -1..<width {
                let topLeft = inside(x, y)
                let topRight = inside(x + 1, y)
                let bottomRight = inside(x + 1, y + 1)
                let bottomLeft = inside(x, y + 1)
                let top = horizontal(x, y)
                let right = vertical(x + 1, y)
                let bottom = horizontal(x, y + 1)
                let left = vertical(x, y)
                let code = (topLeft ? 8 : 0) | (topRight ? 4 : 0) | (bottomRight ? 2 : 0) | (bottomLeft ? 1 : 0)
                // Consistent winding: inside on one side.
                switch code {
                case 1: next[bottom] = left
                case 2: next[right] = bottom
                case 3: next[right] = left
                case 4: next[top] = right
                case 5:
                    next[top] = left
                    next[bottom] = right
                case 6: next[top] = bottom
                case 7: next[top] = left
                case 8: next[left] = top
                case 9: next[bottom] = top
                case 10:
                    next[left] = bottom
                    next[right] = top
                case 11: next[right] = top
                case 12: next[left] = right
                case 13: next[bottom] = right
                case 14: next[left] = bottom
                default: break
                }
            }
        }
        var loops: [[Point]] = []
        var visited = Set<Int>()
        for start in next.keys.sorted() where !visited.contains(start) {
            if SVGTraceCancellation.isCancelled { return [] }
            var loop: [Point] = []
            var edge = start
            while !visited.contains(edge), let following = next[edge] {
                if SVGTraceCancellation.isCancelled { return [] }
                visited.insert(edge)
                loop.append(position(edge))
                edge = following
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    static func signedArea(_ loop: [Point]) -> Double {
        var area = 0.0
        for index in loop.indices {
            if SVGTraceCancellation.isCancelled { return 0 }
            let current = loop[index]
            let next = loop[(index + 1) % loop.count]
            area += current.x * next.y - next.x * current.y
        }
        return area / 2
    }

}

/// Douglas–Peucker on a closed loop.
enum Simplifier {
    static func closedLoop(_ loop: [Point], epsilon: Double) -> [Int] {
        guard loop.count > 3 else { return Array(loop.indices) }
        let far = loop.indices.max { loop[$0].distance(to: loop[0]) < loop[$1].distance(to: loop[0]) } ?? 0
        let first = reduce(loop, 0, far, epsilon)
        let second = reduce(loop + [loop[0]], far, loop.count, epsilon).map { $0 % loop.count }
        return Array(Set(first + second)).sorted()
    }

    private static func reduce(_ points: [Point], _ start: Int, _ end: Int, _ epsilon: Double) -> [Int] {
        guard end > start + 1 else { return [start, end] }
        var farthest = start
        var distance = 0.0
        for index in (start + 1)..<end {
            if SVGTraceCancellation.isCancelled { return [start, end] }
            let candidate = perpendicularDistance(points[index], points[start], points[end])
            if candidate > distance {
                distance = candidate
                farthest = index
            }
        }
        guard distance > epsilon else { return [start, end] }
        return reduce(points, start, farthest, epsilon) + reduce(points, farthest, end, epsilon).dropFirst()
    }

    private static func perpendicularDistance(_ point: Point, _ lineStart: Point, _ lineEnd: Point) -> Double {
        let line = lineEnd - lineStart
        let length = line.length
        guard length > 0 else { return point.distance(to: lineStart) }
        return abs(line.x * (lineStart.y - point.y) - line.y * (lineStart.x - point.x)) / length
    }
}
