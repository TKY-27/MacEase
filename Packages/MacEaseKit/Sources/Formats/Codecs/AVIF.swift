import CAVIF
import CoreGraphics
import Foundation

/// Still AVIF through libavif with libaom.
public enum AVIFEncoder {
    /// Balances size against encode time.
    static let speed: Int32 = 6
    static let bitDepth: UInt32 = 8

    public static func encode(_ pixels: PixelBuffer, quality: Int, xmp: Data? = nil) throws -> Data {
        guard
            let image = avifImageCreate(UInt32(pixels.width), UInt32(pixels.height), bitDepth, AVIF_PIXEL_FORMAT_YUV420)
        else { throw FormatError.encoderFailure("AVIF image allocation") }
        defer { avifImageDestroy(image) }
        image.pointee.yuvRange = AVIF_RANGE_FULL
        image.pointee.matrixCoefficients = avifMatrixCoefficients(AVIF_MATRIX_COEFFICIENTS_BT601)
        if pixels.colorSpace.name == CGColorSpace.sRGB {
            image.pointee.colorPrimaries = avifColorPrimaries(AVIF_COLOR_PRIMARIES_BT709)
            image.pointee.transferCharacteristics = avifTransferCharacteristics(AVIF_TRANSFER_CHARACTERISTICS_SRGB)
        } else if let icc = pixels.colorSpace.copyICCData() as Data? {
            try check(
                icc.withUnsafeBytes {
                    avifImageSetProfileICC(image, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                })
        }
        if let xmp {
            try check(
                xmp.withUnsafeBytes {
                    avifImageSetMetadataXMP(image, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                })
        }
        try convert(pixels, into: image)

        guard let encoder = avifEncoderCreate() else { throw FormatError.encoderFailure("AVIF encoder allocation") }
        defer { avifEncoderDestroy(encoder) }
        let clamped = Int32(min(max(quality, 0), 100))
        encoder.pointee.quality = clamped
        encoder.pointee.qualityAlpha = clamped
        encoder.pointee.speed = speed
        encoder.pointee.maxThreads = Int32(ProcessInfo.processInfo.activeProcessorCount)
        var output = avifRWData()
        defer { avifRWDataFree(&output) }
        try check(avifEncoderWrite(encoder, image, &output))
        return Data(bytes: output.data, count: output.size)
    }

    private static func convert(_ pixels: PixelBuffer, into image: UnsafeMutablePointer<avifImage>) throws {
        var rgb = avifRGBImage()
        avifRGBImageSetDefaults(&rgb, image)
        rgb.format = AVIF_RGB_FORMAT_RGBA
        rgb.depth = bitDepth
        rgb.chromaDownsampling = AVIF_CHROMA_DOWNSAMPLING_AUTOMATIC
        rgb.rowBytes = UInt32(pixels.width * 4)
        var rgba = pixels.rgba
        try rgba.withUnsafeMutableBufferPointer { buffer in
            rgb.pixels = buffer.baseAddress
            try check(avifImageRGBToYUV(image, &rgb))
        }
        // Opaque images carry no alpha plane.
        if pixels.isOpaque, image.pointee.alphaPlane != nil {
            avifImageFreePlanes(image, avifPlanesFlags(AVIF_PLANES_A.rawValue))
        }
    }

    private static func check(_ result: avifResult) throws {
        guard result == AVIF_RESULT_OK else {
            throw FormatError.encoderFailure("AVIF: \(String(cString: avifResultToString(result)))")
        }
    }
}
