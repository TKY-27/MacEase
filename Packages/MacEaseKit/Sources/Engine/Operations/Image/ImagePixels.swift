import CoreImage
import CoreImage.CIFilterBuiltins
import Formats
import Foundation
import ImageIO

/// Geometry and compositing on decoded frames.
enum ImagePixels {
    static func workingSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? PixelBuffer.sRGB
    }

    static func render(_ image: CIImage, like reference: CGImage) throws -> CGImage {
        let extent = image.extent.integral
        let format: CIFormat = reference.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let width = Int(exactly: extent.width), let height = Int(exactly: extent.height) else {
            throw FrameMemoryBudget.exceeded
        }
        var budget = FrameMemoryBudget()
        try budget.reserve(reference)
        try budget.reserve(
            width: width, height: height,
            bytesPerPixel: reference.bitsPerComponent > 8 ? 8 : 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard
            let rendered = context.createCGImage(
                image, from: extent, format: format, colorSpace: workingSpace(of: reference))
        else { throw EngineError.encodeFailed("Core Image render") }
        return rendered
    }

    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        return try render(CIImage(cgImage: image).oriented(orientation), like: image)
    }

    /// Clamped edges keep borders from darkening.
    static func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width != image.width || height != image.height else { return image }
        let source = CIImage(cgImage: image)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source.clampedToExtent()
        let verticalScale = Double(height) / Double(image.height)
        filter.scale = Float(verticalScale)
        filter.aspectRatio = Float((Double(width) / Double(image.width)) / verticalScale)
        guard let output = filter.outputImage else { throw EngineError.encodeFailed("Lanczos scale") }
        return try render(output.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), like: image)
    }

    static func flipped(_ image: CGImage, _ axis: FlipAxis) throws -> CGImage {
        try render(CIImage(cgImage: image).oriented(axis == .horizontal ? .upMirrored : .downMirrored), like: image)
    }

    /// Clockwise; the canvas grows to fit.
    static func rotated(_ image: CGImage, degrees: Double, fill: CGColor?) throws -> CGImage {
        guard degrees.isFinite else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let quarterTurns = degrees / 90
        if quarterTurns == quarterTurns.rounded() {
            let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            let normalized = quarterTurns.truncatingRemainder(dividingBy: 4)
            let index = ((Int(normalized) % 4) + 4) % 4
            return try oriented(image, orientations[index])
        }
        let radians = degrees * .pi / 180
        let width = Double(image.width)
        let height = Double(image.height)
        guard
            let canvasWidth = Int(exactly: (abs(width * cos(radians)) + abs(height * sin(radians))).rounded(.up)),
            let canvasHeight = Int(exactly: (abs(width * sin(radians)) + abs(height * cos(radians))).rounded(.up))
        else { throw FrameMemoryBudget.exceeded }
        return try draw(width: canvasWidth, height: canvasHeight, like: image, fill: fill) { context in
            context.translateBy(x: Double(canvasWidth) / 2, y: Double(canvasHeight) / 2)
            context.rotate(by: -radians)
            context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }
    }

    /// Centers `image` on a larger canvas.
    static func padded(_ image: CGImage, width: Int, height: Int, fill: CGColor?) throws -> CGImage {
        try draw(width: width, height: height, like: image, fill: fill) { context in
            let origin = CGPoint(x: (width - image.width) / 2, y: (height - image.height) / 2)
            context.draw(image, in: CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)))
        }
    }

    static func cropped(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        guard let cropped = image.cropping(to: rect) else { throw EngineError.encodeFailed("crop") }
        return cropped
    }

    static func draw(
        width: Int, height: Int, like reference: CGImage, fill: CGColor?, _ body: (CGContext) -> Void
    ) throws -> CGImage {
        var budget = FrameMemoryBudget()
        try budget.reserve(reference)
        try budget.reserve(width: width, height: height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: workingSpace(of: reference), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw EngineError.encodeFailed("bitmap context") }
        context.interpolationQuality = .high
        if let fill {
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        body(context)
        guard let image = context.makeImage() else { throw EngineError.encodeFailed("bitmap image") }
        return image
    }

    static func color(_ rgb: RGBColor) -> CGColor {
        CGColor(
            srgbRed: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255, alpha: 1)
    }
}
