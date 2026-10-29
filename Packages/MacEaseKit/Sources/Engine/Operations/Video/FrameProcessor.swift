import CoreImage
import CoreVideo
import Formats
import Foundation

enum VideoDisplayOrientation: Hashable, Sendable {
    case identity, right, left, halfTurn
    case horizontalMirror, verticalMirror, diagonalMirror, oppositeDiagonalMirror

    private static let floatingPointTolerance: CGFloat = 1e-10

    init(_ transform: CGAffineTransform) throws {
        let coefficients = [transform.a, transform.b, transform.c, transform.d]
        guard coefficients.allSatisfy(\.isFinite), transform.tx.isFinite, transform.ty.isFinite,
            coefficients.allSatisfy({ abs($0) <= 1 + Self.floatingPointTolerance })
        else { throw EngineError.videoDisplayTransformUnsupported }
        let rounded = coefficients.map { Int($0.rounded()) }
        guard zip(coefficients, rounded).allSatisfy({ abs($0.0 - CGFloat($0.1)) <= Self.floatingPointTolerance })
        else { throw EngineError.videoDisplayTransformUnsupported }
        switch rounded {
        case [1, 0, 0, 1]: self = .identity
        case [0, 1, -1, 0]: self = .right
        case [0, -1, 1, 0]: self = .left
        case [-1, 0, 0, -1]: self = .halfTurn
        case [-1, 0, 0, 1]: self = .horizontalMirror
        case [1, 0, 0, -1]: self = .verticalMirror
        case [0, 1, 1, 0]: self = .diagonalMirror
        case [0, -1, -1, 0]: self = .oppositeDiagonalMirror
        default: throw EngineError.videoDisplayTransformUnsupported
        }
    }

    var pixelTransform: CGAffineTransform {
        let coefficients: (CGFloat, CGFloat, CGFloat, CGFloat) =
            switch self {
            case .identity: (1, 0, 0, 1)
            case .right: (0, -1, 1, 0)
            case .left: (0, 1, -1, 0)
            case .halfTurn: (-1, 0, 0, -1)
            case .horizontalMirror: (-1, 0, 0, 1)
            case .verticalMirror: (1, 0, 0, -1)
            case .diagonalMirror: (0, -1, -1, 0)
            case .oppositeDiagonalMirror: (0, 1, 1, 0)
            }
        return CGAffineTransform(
            a: coefficients.0, b: coefficients.1, c: coefficients.2, d: coefficients.3, tx: 0, ty: 0)
    }
}

/// Geometry applied to every re-encoded frame.
struct FrameEdit: Hashable, Sendable {
    /// Clockwise degrees.
    var rotation: Double = 0
    var displayOrientation: VideoDisplayOrientation = .identity
    var flipsHorizontally = false
    var flipsVertically = false
    var fill = RGBColor.black
    var flattensAlpha = false
    var preservesAlpha = false
    /// Even; `nil` keeps the transformed size.
    var size: PixelSize?
    var aspect: AspectRange?
    var editorGeometry: EditGeometry?
    var adjustments: MediaAdjustments?
}

struct PixelSize: Hashable, Sendable {
    var width: Int
    var height: Int

    /// H.264 and HEVC 4:2:0 need even sizes.
    func evened() -> PixelSize {
        PixelSize(width: max(2, width / 2 * 2), height: max(2, height / 2 * 2))
    }
}

final class FrameProcessor {
    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let hdr: VideoHDRConfiguration?
    private let outputColorSpace: CGColorSpace?
    private let geometry: CGAffineTransform
    private let sourceCrop: CGRect
    private let scale: CGAffineTransform
    private let viewport: CGRect
    private let background: CIImage?
    private let editorGeometry: EditGeometry?
    private let adjustments: MediaAdjustments?
    let size: PixelSize

    static func outputSize(
        source: PixelSize, edit: FrameEdit, display: VideoDisplayGeometry? = nil
    ) throws -> PixelSize {
        let source = presentationSize(source, display: display)
        let geometry = orientation(edit, width: Double(source.width), height: Double(source.height))
        let bounds = viewport(source: source, edit: edit, geometry: geometry)
        guard let width = Int(exactly: bounds.width.rounded()),
            let height = Int(exactly: bounds.height.rounded()), width > 0, height > 0
        else { throw EngineError.decodeFailed("video dimensions out of range") }
        let edited = edit.editorGeometry?.outputSize(CGSize(width: width, height: height))
        let natural = PixelSize(
            width: edited.map { Int($0.width) } ?? width, height: edited.map { Int($0.height) } ?? height)
        return (edit.size ?? natural).evened()
    }

    init(
        source: PixelSize, edit: FrameEdit, hdr: VideoHDRConfiguration? = nil, display: VideoDisplayGeometry? = nil
    ) throws {
        self.hdr = hdr
        editorGeometry = edit.editorGeometry
        adjustments = edit.adjustments
        if let hdr {
            guard let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
                let output = CGColorSpace(
                    name: hdr.transfer == .pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG)
            else { throw EngineError.encodeFailed("HDR color space unavailable") }
            context = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAh])
            outputColorSpace = output
        } else if edit.adjustments?.isIdentity == false {
            context = CIContext(options: [.cacheIntermediates: false])
            outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709)
        } else {
            context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            outputColorSpace = nil
        }
        let presentation = Self.presentationSize(source, display: display)
        if let display, display.presentationSize(width: source.width, height: source.height) != nil {
            sourceCrop = display.cropRect(width: source.width, height: source.height)
        } else {
            sourceCrop = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        }
        let orientation = Self.orientation(edit, width: Double(presentation.width), height: Double(presentation.height))
        geometry = CGAffineTransform(translationX: -sourceCrop.minX, y: -sourceCrop.minY)
            .concatenating(
                CGAffineTransform(
                    scaleX: CGFloat(presentation.width) / sourceCrop.width,
                    y: CGFloat(presentation.height) / sourceCrop.height)
            )
            .concatenating(orientation)
        let bounds = Self.viewport(source: presentation, edit: edit, geometry: orientation)
        viewport = bounds
        size = try Self.outputSize(source: source, edit: edit, display: display)
        let editedSize = edit.editorGeometry?.outputSize(bounds.size) ?? bounds.size
        scale = CGAffineTransform(
            scaleX: CGFloat(size.width) / editedSize.width, y: CGFloat(size.height) / editedSize.height)
        let rightAngle = edit.rotation.truncatingRemainder(dividingBy: 90) == 0
        background =
            !edit.flattensAlpha && (edit.preservesAlpha || rightAngle && edit.aspect?.fit != .letterbox)
            ? nil
            : CIImage(
                color: CIColor(
                    red: CGFloat(edit.fill.red) / 255, green: CGFloat(edit.fill.green) / 255,
                    blue: CGFloat(edit.fill.blue) / 255))
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: hdr == nil
                ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey: size.width, kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw EngineError.encodeFailed("frame pool \(status)") }
        pool = created
    }

    private static func presentationSize(_ source: PixelSize, display: VideoDisplayGeometry?) -> PixelSize {
        guard let size = display?.presentationSize(width: source.width, height: source.height) else { return source }
        return PixelSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
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
        transform = transform.concatenating(edit.displayOrientation.pixelTransform)
        if edit.flipsHorizontally { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        if edit.flipsVertically { transform = transform.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        transform = transform.concatenating(CGAffineTransform(rotationAngle: -edit.rotation * .pi / 180))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        return transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }

    func process(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        var image = CIImage(cvPixelBuffer: frame).cropped(to: sourceCrop).transformed(by: geometry).cropped(
            to: viewport
        )
        .transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
        if let editorGeometry { image = editorGeometry.applying(to: image) }
        if let adjustments { image = adjustments.applying(to: image) }
        image = image.transformed(by: scale)
        let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if let background { image = image.composited(over: background) }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard status == kCVReturnSuccess, let output else { throw EngineError.encodeFailed("frame buffer \(status)") }
        if let hdr {
            CVBufferSetAttachment(
                output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, hdr.transferFunction, .shouldPropagate)
            CVBufferSetAttachment(
                output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        context.render(image.cropped(to: extent), to: output, bounds: extent, colorSpace: outputColorSpace)
        return output
    }
}
