import Foundation
import simd

private struct PNGWindowQuality {
    var ssim: Double
    var chroma: Double
}

enum PNGPaletteQuality {
    private static let gridSide = 8
    private static let radius = 5
    private static let minimumSSIM = 0.97
    private static let maximumChroma = 0.02
    private static let lumaWeights = SIMD3<Double>(0.299, 0.587, 0.114)
    private static let gaussian: [Double] = {
        let sigma = 1.5
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }()

    static func accepts(_ raster: PNGRaster, original: PixelBuffer, cancelled: (() -> Bool)?) throws -> Bool {
        try raster.samples.withUnsafeBytes { indices in
            var blackSSIM = 0.0
            var whiteSSIM = 0.0
            for row in 0..<gridSide {
                for column in 0..<gridSide {
                    if cancelled?() == true { throw CancellationError() }
                    let x = column * (original.width - 1) / (gridSide - 1)
                    let y = row * (original.height - 1) / (gridSide - 1)
                    let black = window(raster, indices: indices, original: original, x: x, y: y, background: 0)
                    let white = window(raster, indices: indices, original: original, x: x, y: y, background: 255)
                    guard black.chroma <= maximumChroma, white.chroma <= maximumChroma else { return false }
                    blackSSIM += black.ssim
                    whiteSSIM += white.ssim
                }
            }
            let windows = Double(gridSide * gridSide)
            return blackSSIM / windows >= minimumSSIM && whiteSSIM / windows >= minimumSSIM
        }
    }

    private static func window(
        _ raster: PNGRaster, indices: UnsafeRawBufferPointer, original: PixelBuffer,
        x: Int, y: Int, background: Double
    ) -> PNGWindowQuality {
        var sourceMean = 0.0
        var outputMean = 0.0
        var sourceSquares = 0.0
        var outputSquares = 0.0
        var products = 0.0
        var chroma = 0.0
        for dy in -radius...radius {
            let row = min(max(y + dy, 0), original.height - 1)
            for dx in -radius...radius {
                let column = min(max(x + dx, 0), original.width - 1)
                let base = (row * original.width + column) * 4
                let source = composite(
                    original.rgba[base], original.rgba[base + 1], original.rgba[base + 2],
                    original.rgba[base + 3], background: background)
                let packed = indices[row * raster.rowBytes + column * raster.bitDepth / 8]
                let shift = 8 - raster.bitDepth - column * raster.bitDepth % 8
                let index = Int(packed >> shift) & ((1 << raster.bitDepth) - 1)
                let color = raster.palette[index]
                let output = composite(color.red, color.green, color.blue, color.alpha, background: background)
                let sourceLuma = (source * lumaWeights).sum()
                let outputLuma = (output * lumaWeights).sum()
                let weight = gaussian[dy + radius] * gaussian[dx + radius]
                sourceMean += sourceLuma * weight
                outputMean += outputLuma * weight
                sourceSquares += sourceLuma * sourceLuma * weight
                outputSquares += outputLuma * outputLuma * weight
                products += sourceLuma * outputLuma * weight
                let sourceLab = lab(source)
                let outputLab = lab(output)
                chroma += Double(hypot(sourceLab.a - outputLab.a, sourceLab.b - outputLab.b))
            }
        }
        let c1Scale = 0.01 * Double(UInt8.max)
        let c2Scale = 0.03 * Double(UInt8.max)
        let c1 = c1Scale * c1Scale
        let c2 = c2Scale * c2Scale
        let sourceVariance = max(0, sourceSquares - sourceMean * sourceMean)
        let outputVariance = max(0, outputSquares - outputMean * outputMean)
        let covariance = products - sourceMean * outputMean
        let ssim =
            (2 * sourceMean * outputMean + c1) * (2 * covariance + c2)
            / ((sourceMean * sourceMean + outputMean * outputMean + c1) * (sourceVariance + outputVariance + c2))
        let diameter = radius * 2 + 1
        return PNGWindowQuality(ssim: ssim, chroma: chroma / Double(diameter * diameter))
    }

    private static func composite(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8, background: Double)
        -> SIMD3<Double>
    {
        let opacity = Double(alpha) / 255
        return SIMD3(Double(red), Double(green), Double(blue)) * opacity
            + SIMD3(repeating: background * (1 - opacity))
    }

    private static func lab(_ rgb: SIMD3<Double>) -> Oklab {
        Oklab(
            red: UInt8(clamping: Int(rgb.x.rounded())), green: UInt8(clamping: Int(rgb.y.rounded())),
            blue: UInt8(clamping: Int(rgb.z.rounded())))
    }
}
