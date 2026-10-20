import CoreImage
import CoreImage.CIFilterBuiltins
import Formats
import Foundation
import Vision

/// Masks the subject and replaces the background.
enum ImageBackground {
    static let featherRadius = 1.0
    /// Largest RGB distance, so tolerance spans 0...1.
    private static let maximumDistance = (3.0 * 255 * 255).squareRoot()

    static func replace(_ url: URL, _ options: BackgroundOptions, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        guard let firstMask = try await mask(for: document.first, source: options.mask) else {
            return .skipped(.nothingToRemove)
        }
        let source = document.writableFormat
        let format = options.fill == .transparent && !source.holdsAlpha ? .png : source
        return try await ImageOutput.transformed(document, as: format, keepsGainMap: false, context: context) { image in
            let found = image === document.first ? firstMask : try await mask(for: image, source: options.mask)
            guard let found else { return image }
            return try composite(image, mask: found, fill: options.fill)
        }
    }

    /// `nil` when nothing is foreground.
    static func mask(for image: CGImage, source: MaskSource) async throws -> CIImage? {
        let raw: CIImage
        switch source {
        case .subject, .person:
            let handler = ImageRequestHandler(image)
            let observation =
                source == .person
                ? try await handler.perform(GeneratePersonInstanceMaskRequest())
                : try await handler.perform(GenerateForegroundInstanceMaskRequest())
            guard let observation, !observation.allInstances.isEmpty else { return nil }
            raw = CIImage(
                cvPixelBuffer: try observation.generateScaledMask(
                    for: observation.allInstances, scaledToImageFrom: handler))
        case .colorKey(let key, let tolerance):
            guard let keyed = try colorKeyMask(image, key: key, tolerance: tolerance) else { return nil }
            raw = keyed
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return raw.clampedToExtent().applyingGaussianBlur(sigma: featherRadius).cropped(to: extent)
    }

    private static func colorKeyMask(_ image: CGImage, key: RGBColor, tolerance: Double) throws -> CIImage? {
        let pixels = try PixelBuffer(cgImage: image)
        let target = [Double(key.red), Double(key.green), Double(key.blue)]
        var coverage = [UInt8](repeating: 0, count: pixels.pixelCount * 4)
        var keepsAny = false
        for pixel in 0..<pixels.pixelCount {
            let base = pixel * 4
            let distance = (0..<3).reduce(0.0) { sum, channel in
                let difference = Double(pixels.rgba[base + channel]) - target[channel]
                return sum + difference * difference
            }.squareRoot()
            let kept: UInt8 = distance / maximumDistance <= tolerance ? 0 : 255
            keepsAny = keepsAny || kept == 255
            coverage[base] = kept
            coverage[base + 1] = kept
            coverage[base + 2] = kept
            coverage[base + 3] = 255
        }
        guard keepsAny else { return nil }
        let mask = PixelBuffer(width: pixels.width, height: pixels.height, rgba: coverage)
        return CIImage(cgImage: try mask.makeCGImage())
    }

    static func composite(_ image: CGImage, mask: CIImage, fill: BackgroundFill) throws -> CGImage {
        let foreground = CIImage(cgImage: image)
        let extent = foreground.extent
        let background: CIImage
        switch fill {
        case .transparent:
            background = CIImage(color: .clear).cropped(to: extent)
        case .color(let rgb):
            background = CIImage(color: CIColor(cgColor: ImagePixels.color(rgb))).cropped(to: extent)
        case .blur(let radius):
            background = foreground.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = background
        blend.maskImage = mask
        guard let output = blend.outputImage else { throw EngineError.encodeFailed("mask blend") }
        return try ImagePixels.render(output, like: image)
    }
}
