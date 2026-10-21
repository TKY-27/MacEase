import CoreImage
import CoreVideo
import Foundation

/// Geometry applied to every re-encoded frame.
struct FrameEdit: Hashable, Sendable {
    /// Clockwise degrees.
    var rotation: Double = 0
    var flipsHorizontally = false
    var flipsVertically = false
    var fill = RGBColor.black
    /// Even; `nil` keeps the transformed size.
    var size: PixelSize?
    var aspect: AspectRange?
}

struct PixelSize: Hashable, Sendable {
    var width: Int
    var height: Int

    /// H.264 and HEVC 4:2:0 need even sizes.
    func evened() -> PixelSize {
        PixelSize(width: max(2, width / 2 * 2), height: max(2, height / 2 * 2))
    }
}

/// Unmanaged color, so values pass through.
final class FrameProcessor {
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]
        return CIContext(options: options)
    }()
    private let pool: CVPixelBufferPool
    private let geometry: CGAffineTransform
    private let scale: CGAffineTransform
    private let viewport: CGRect
    private let background: CIImage?
    let size: PixelSize

    static func outputSize(source: PixelSize, edit: FrameEdit) throws -> PixelSize {
        let geometry = orientation(edit, width: Double(source.width), height: Double(source.height))
        let bounds = viewport(source: source, edit: edit, geometry: geometry)
        guard let width = Int(exactly: bounds.width.rounded()),
            let height = Int(exactly: bounds.height.rounded()), width > 0, height > 0
        else { throw EngineError.decodeFailed("video dimensions out of range") }
        let natural = PixelSize(width: width, height: height)
        return (edit.size ?? natural).evened()
    }

    init(source: PixelSize, edit: FrameEdit) throws {
        geometry = Self.orientation(edit, width: Double(source.width), height: Double(source.height))
        let bounds = Self.viewport(source: source, edit: edit, geometry: geometry)
        viewport = bounds
        size = try Self.outputSize(source: source, edit: edit)
        scale = CGAffineTransform(
            scaleX: CGFloat(size.width) / bounds.width, y: CGFloat(size.height) / bounds.height)
        let rightAngle = edit.rotation.truncatingRemainder(dividingBy: 90) == 0
        background =
            rightAngle && edit.aspect?.fit != .letterbox
            ? nil
            : CIImage(
                color: CIColor(
                    red: CGFloat(edit.fill.red) / 255, green: CGFloat(edit.fill.green) / 255,
                    blue: CGFloat(edit.fill.blue) / 255))
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size.width, kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw EngineError.encodeFailed("frame pool \(status)") }
        pool = created
    }

    private static func viewport(source: PixelSize, edit: FrameEdit, geometry: CGAffineTransform) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height).applying(geometry)
        guard let aspect = edit.aspect else { return bounds }
        let ratio = bounds.width / bounds.height
        let target = min(max(ratio, aspect.min.value), aspect.max.value)
        let narrows = target < ratio
        let crops = aspect.fit == .crop
        let width = narrows == crops ? bounds.height * target : bounds.width
        let height = narrows == crops ? bounds.height : bounds.width / target
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// Y-up space: clockwise turns are negative.
    private static func orientation(_ edit: FrameEdit, width: Double, height: Double) -> CGAffineTransform {
        var transform = CGAffineTransform(translationX: -width / 2, y: -height / 2)
        if edit.flipsHorizontally { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        if edit.flipsVertically { transform = transform.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        transform = transform.concatenating(CGAffineTransform(rotationAngle: -edit.rotation * .pi / 180))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        return transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }

    func process(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        var image = CIImage(cvPixelBuffer: frame).transformed(by: geometry).cropped(to: viewport)
            .transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
            .transformed(by: scale)
        let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if let background { image = image.composited(over: background) }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard status == kCVReturnSuccess, let output else { throw EngineError.encodeFailed("frame buffer \(status)") }
        context.render(image.cropped(to: extent), to: output, bounds: extent, colorSpace: nil)
        return output
    }
}
