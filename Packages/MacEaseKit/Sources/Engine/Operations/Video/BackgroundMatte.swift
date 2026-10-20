import CoreImage
import CoreVideo
import Foundation
import Vision

/// SPEC 8.11: smoothed masks, feathered, then composited.
final class BackgroundMatte {
    static let smoothing = 0.6
    static let featherRadius = 3.0
    /// Overlap is compared on small masks.
    private static let overlapEdge = 64

    private let source: MaskSource
    private let fill: BackgroundFill
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]
        return CIContext(options: options)
    }()
    private var previous: CIImage?
    private var pool: CVPixelBufferPool?
    private var maskPool: CVPixelBufferPool?

    init(source: MaskSource, fill: BackgroundFill) {
        self.source = source
        self.fill = fill
    }

    func apply(_ frame: CVPixelBuffer) async throws -> CVPixelBuffer {
        let image = CIImage(cvPixelBuffer: frame)
        let extent = image.extent
        let current = try await mask(for: frame, extent: extent)
        let smoothed = try materialized(previous.map { blend(current, $0) } ?? current, extent: extent)
        previous = smoothed
        let matte = smoothed.clampedToExtent().applyingGaussianBlur(sigma: Self.featherRadius).cropped(to: extent)
        let composited = image.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: background(for: image), kCIInputMaskImageKey: matte])
        let output = try buffer(like: frame)
        context.render(composited.cropped(to: extent), to: output, bounds: extent, colorSpace: nil)
        return output
    }

    private func blend(_ current: CIImage, _ earlier: CIImage) -> CIImage {
        let weight = CGFloat(Self.smoothing)
        func scaled(_ image: CIImage, _ factor: CGFloat) -> CIImage {
            let vector = CIVector(x: factor, y: 0, z: 0, w: 0)
            return image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": vector, "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
                ])
        }
        return scaled(current, weight).applyingFilter(
            "CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled(earlier, 1 - weight)])
    }

    private func background(for image: CIImage) -> CIImage {
        let extent = image.extent
        switch fill {
        case .transparent: return CIImage(color: .clear).cropped(to: extent)
        case .color(let rgb):
            return CIImage(
                color: CIColor(
                    red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255)
            ).cropped(to: extent)
        case .blur(let radius): return image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
    }

    private func mask(for frame: CVPixelBuffer, extent: CGRect) async throws -> CIImage {
        let raw: CIImage
        switch source {
        case .person:
            let request = GeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            raw = CIImage(cgImage: try await request.perform(on: frame).cgImage)
        case .subject:
            let handler = ImageRequestHandler(frame)
            guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()),
                !observation.allInstances.isEmpty
            else { return CIImage(color: .black).cropped(to: extent) }
            let chosen = try instance(in: observation, handler: handler)
            raw = CIImage(cvPixelBuffer: try observation.generateScaledMask(for: chosen, scaledToImageFrom: handler))
        case .colorKey:
            throw EngineError.invalidInput(.malformed("color key is for images"))
        }
        return raw.transformed(
            by: CGAffineTransform(scaleX: extent.width / raw.extent.width, y: extent.height / raw.extent.height))
    }

    /// Follows the subject from the last frame.
    private func instance(in observation: InstanceMaskObservation, handler: ImageRequestHandler) throws -> IndexSet {
        guard let previous else { return observation.allInstances }
        let target = sample(previous)
        var best: (instance: Int, overlap: Double)?
        for instance in observation.allInstances {
            let candidate = CIImage(
                cvPixelBuffer: try observation.generateScaledMask(for: [instance], scaledToImageFrom: handler))
            let overlap = zip(sample(candidate), target).reduce(0.0) { $0 + min($1.0, $1.1) }
            if best == nil || overlap > best?.overlap ?? 0 { best = (instance, overlap) }
        }
        return best.map { IndexSet(integer: $0.instance) } ?? observation.allInstances
    }

    private func sample(_ image: CIImage) -> [Double] {
        let edge = Self.overlapEdge
        let small = image.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(edge) / image.extent.width, y: CGFloat(edge) / image.extent.height))
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        context.render(
            small, toBitmap: &bytes, rowBytes: edge * 4, bounds: CGRect(x: 0, y: 0, width: edge, height: edge),
            format: .RGBA8, colorSpace: nil)
        return stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) / 255 }
    }

    /// Pixels, so history never chains filters.
    private func materialized(_ mask: CIImage, extent: CGRect) throws -> CIImage {
        if maskPool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferWidthKey: Int(extent.width), kCVPixelBufferHeightKey: Int(extent.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &maskPool)
        }
        var output: CVPixelBuffer?
        guard let maskPool, CVPixelBufferPoolCreatePixelBuffer(nil, maskPool, &output) == kCVReturnSuccess,
            let output
        else { throw EngineError.encodeFailed("matte mask buffer") }
        context.render(mask.cropped(to: extent), to: output, bounds: extent, colorSpace: nil)
        return CIImage(cvPixelBuffer: output)
    }

    private func buffer(like frame: CVPixelBuffer) throws -> CVPixelBuffer {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(frame),
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(frame),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            throw EngineError.encodeFailed("matte frame buffer")
        }
        return output
    }
}
