import Foundation

@testable import Formats

/// Mean luma SSIM, 11×11 Gaussian window.
enum SSIM {
    private static let kernel: [Double] = {
        let weights = (-5...5).map { exp(-Double($0 * $0) / (2 * 1.5 * 1.5)) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }()

    static func luma(of buffer: PixelBuffer) -> [Double] {
        (0..<buffer.pixelCount).map { index in
            let base = index * 4
            let alpha = Double(buffer.rgba[base + 3]) / 255
            let composite = { (value: UInt8) in Double(value) * alpha + 255 * (1 - alpha) }
            return 0.299 * composite(buffer.rgba[base]) + 0.587 * composite(buffer.rgba[base + 1])
                + 0.114 * composite(buffer.rgba[base + 2])
        }
    }

    static func compare(_ reference: PixelBuffer, _ candidate: PixelBuffer) -> Double {
        precondition(reference.width == candidate.width && reference.height == candidate.height, "sizes differ")
        return compare(luma: luma(of: reference), luma(of: candidate), width: reference.width, height: reference.height)
    }

    static func compare(luma x: [Double], _ y: [Double], width: Int, height: Int) -> Double {
        let c1: Double = (0.01 * 255) * (0.01 * 255)
        let c2: Double = (0.03 * 255) * (0.03 * 255)
        let meanX = blur(x, width: width, height: height)
        let meanY = blur(y, width: width, height: height)
        let xx = blur(zip(x, x).map { $0 * $1 }, width: width, height: height)
        let yy = blur(zip(y, y).map { $0 * $1 }, width: width, height: height)
        let xy = blur(zip(x, y).map { $0 * $1 }, width: width, height: height)
        var total = 0.0
        for index in x.indices {
            let mx = meanX[index]
            let my = meanY[index]
            let varianceX = xx[index] - mx * mx
            let varianceY = yy[index] - my * my
            let covariance = xy[index] - mx * my
            total +=
                ((2 * mx * my + c1) * (2 * covariance + c2))
                / ((mx * mx + my * my + c1) * (varianceX + varianceY + c2))
        }
        return total / Double(x.count)
    }

    private static func blur(_ values: [Double], width: Int, height: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for (offset, weight) in kernel.enumerated() {
                    let sx = min(max(x + offset - 5, 0), width - 1)
                    sum += values[y * width + sx] * weight
                }
                horizontal[y * width + x] = sum
            }
        }
        var result = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for (offset, weight) in kernel.enumerated() {
                    let sy = min(max(y + offset - 5, 0), height - 1)
                    sum += horizontal[sy * width + x] * weight
                }
                result[y * width + x] = sum
            }
        }
        return result
    }
}
