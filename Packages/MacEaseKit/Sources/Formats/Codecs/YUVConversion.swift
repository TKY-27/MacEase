import Accelerate
import CoreVideo
import Foundation

public enum YUVMatrix: Sendable {
    case bt601
    case bt709

    /// Luma weights from each standard.
    var weights: (red: Float, blue: Float) {
        switch self {
        case .bt601: (0.299, 0.114)
        case .bt709: (0.2126, 0.0722)
        }
    }
}

/// vImage 4:2:0 conversions; BGRA sides are premultiplied.
struct YUVConverter {
    private static let limitedRange = vImage_YpCbCrPixelRange(
        Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
    private static let fullRange = vImage_YpCbCrPixelRange(
        Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
    private static let bgraFromARGB: [UInt8] = [3, 2, 1, 0]
    private static let opaque: UInt8 = 255

    private var toBGRA = vImage_YpCbCrToARGB()
    private var fromBGRA = vImage_ARGBToYpCbCr()
    let matrix: YUVMatrix
    let isFullRange: Bool

    init(matrix: YUVMatrix, fullRange: Bool) throws {
        self.matrix = matrix
        isFullRange = fullRange
        let (red, blue) = matrix.weights
        let green = 1 - red - blue
        var decode = vImage_YpCbCrToARGBMatrix(
            Yp: 1, Cr_R: 2 * (1 - red), Cr_G: -2 * red * (1 - red) / green, Cb_G: -2 * blue * (1 - blue) / green,
            Cb_B: 2 * (1 - blue))
        var encode = vImage_ARGBToYpCbCrMatrix(
            R_Yp: red, G_Yp: green, B_Yp: blue, R_Cb: -red / (2 * (1 - blue)), G_Cb: -green / (2 * (1 - blue)),
            B_Cb_R_Cr: 0.5, G_Cr: -green / (2 * (1 - red)), B_Cr: -blue / (2 * (1 - red)))
        var range = fullRange ? Self.fullRange : Self.limitedRange
        let flags = vImage_Flags(kvImageNoFlags)
        var status = vImageConvert_YpCbCrToARGB_GenerateConversion(
            &decode, &range, &toBGRA, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, flags)
        guard status == kvImageNoError else { throw FormatError.decoderFailure("YUV conversion setup \(status)") }
        status = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            &encode, &range, &fromBGRA, kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, flags)
        guard status == kvImageNoError else { throw FormatError.encoderFailure("YUV conversion setup \(status)") }
    }

    /// `alpha` is a full-range opacity plane.
    func image(from frame: YUVFrame, alpha: [UInt8]?) throws -> CVPixelBuffer {
        let image = try VideoDecoders.makeImage(width: frame.width, height: frame.height)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw FormatError.decoderFailure("pixel buffer") }
        var destination = buffer(
            base, width: frame.width, height: frame.height, rowBytes: CVPixelBufferGetBytesPerRow(image))
        var planes = (frame.luma, frame.blueDifference, frame.redDifference)
        var conversion = toBGRA
        let status = withPlanes(&planes, frame: frame) { y, cb, cr in
            vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
                &y, &cb, &cr, &destination, &conversion, Self.bgraFromARGB, Self.opaque, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { throw FormatError.decoderFailure("YUV conversion \(status)") }
        guard let alpha else { return image }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<frame.height {
            for column in 0..<frame.width {
                pixels[row * destination.rowBytes + column * 4 + 3] = alpha[row * frame.width + column]
            }
        }
        guard vImagePremultiplyData_RGBA8888(&destination, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { throw FormatError.decoderFailure("premultiply") }
        return image
    }

    /// VP9 wants straight color; opacity as gray.
    func planes(of image: CVPixelBuffer, withAlpha: Bool) throws -> (YUVFrame, YUVFrame?) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw FormatError.encoderFailure("pixel buffer") }
        var straight = [UInt8](UnsafeRawBufferPointer(start: base, count: rowBytes * height))
        let gray: [UInt8]? =
            withAlpha ? (0..<(width * height)).map { straight[($0 / width) * rowBytes + ($0 % width) * 4 + 3] } : nil
        var frame = YUVFrame(
            width: width, height: height, luma: [UInt8](repeating: 0, count: width * height),
            blueDifference: [UInt8](repeating: 0, count: ((width + 1) / 2) * ((height + 1) / 2)),
            redDifference: [UInt8](repeating: 0, count: ((width + 1) / 2) * ((height + 1) / 2)))
        frame.matrix = matrix
        frame.isFullRange = isFullRange
        var conversion = fromBGRA
        var planes = (frame.luma, frame.blueDifference, frame.redDifference)
        let status = straight.withUnsafeMutableBytes { bytes in
            var source = buffer(bytes.baseAddress, width: width, height: height, rowBytes: rowBytes)
            if withAlpha { vImageUnpremultiplyData_RGBA8888(&source, &source, vImage_Flags(kvImageNoFlags)) }
            return withPlanes(&planes, frame: frame) { y, cb, cr in
                vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(
                    &source, &y, &cb, &cr, &conversion, Self.bgraFromARGB, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw FormatError.encoderFailure("YUV conversion \(status)") }
        (frame.luma, frame.blueDifference, frame.redDifference) = planes
        return (frame, gray.map { YUVFrame(gray: $0, width: width, height: height) })
    }

    private func buffer(_ data: UnsafeMutableRawPointer?, width: Int, height: Int, rowBytes: Int) -> vImage_Buffer {
        vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    private func withPlanes(
        _ planes: inout ([UInt8], [UInt8], [UInt8]), frame: YUVFrame,
        _ body: (inout vImage_Buffer, inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error
    ) -> vImage_Error {
        planes.0.withUnsafeMutableBytes { luma in
            planes.1.withUnsafeMutableBytes { blue in
                planes.2.withUnsafeMutableBytes { red in
                    var y = buffer(luma.baseAddress, width: frame.width, height: frame.height, rowBytes: frame.width)
                    var cb = buffer(
                        blue.baseAddress, width: frame.chromaWidth, height: frame.chromaHeight,
                        rowBytes: frame.chromaWidth)
                    var cr = buffer(
                        red.baseAddress, width: frame.chromaWidth, height: frame.chromaHeight,
                        rowBytes: frame.chromaWidth)
                    return body(&y, &cb, &cr)
                }
            }
        }
    }

    /// Narrows high bit depths to 8 bits.
    static func copyPlane(
        _ base: UnsafeRawPointer?, stride: Int, columns: Int, rows: Int, bitDepth: Int = 8
    ) throws -> [UInt8] {
        guard let base else { throw FormatError.decoderFailure("missing image plane") }
        var result = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let line = base.advanced(by: row * stride)
            for column in 0..<columns {
                result[row * columns + column] =
                    bitDepth == 8
                    ? line.load(fromByteOffset: column, as: UInt8.self)
                    : UInt8(
                        truncatingIfNeeded: line.loadUnaligned(fromByteOffset: column * 2, as: UInt16.self)
                            >> (bitDepth - 8))
            }
        }
        return result
    }
}
