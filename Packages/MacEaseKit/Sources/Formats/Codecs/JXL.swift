import CJXL
import CoreGraphics
import Foundation

/// Still JPEG XL through libjxl.
public enum JXLEncoder {
    private static let outputChunk = 1 << 16
    private static let bitsPerSample: UInt32 = 8
    /// The library's default effort.
    private static let effort: Int64 = 7

    public static func encode(_ pixels: PixelBuffer, quality: Int, xmp: Data? = nil) throws -> Data {
        guard let encoder = JxlEncoderCreate(nil) else { throw FormatError.encoderFailure("JXL encoder allocation") }
        defer { JxlEncoderDestroy(encoder) }
        let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads())
        defer { JxlThreadParallelRunnerDestroy(runner) }
        try check(JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner), encoder)

        let lossless = quality >= 100
        let hasAlpha = !pixels.isOpaque
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(pixels.width)
        info.ysize = UInt32(pixels.height)
        info.bits_per_sample = bitsPerSample
        info.num_color_channels = 3
        info.num_extra_channels = hasAlpha ? 1 : 0
        info.alpha_bits = hasAlpha ? bitsPerSample : 0
        info.uses_original_profile = lossless ? 1 : 0
        try check(JxlEncoderSetBasicInfo(encoder, &info), encoder)
        try setColor(of: pixels, on: encoder)
        if let xmp {
            try check(JxlEncoderUseBoxes(encoder), encoder)
            try check(
                xmp.withUnsafeBytes {
                    JxlEncoderAddBox(encoder, "xml ", $0.bindMemory(to: UInt8.self).baseAddress, $0.count, 0)
                },
                encoder)
            JxlEncoderCloseBoxes(encoder)
        }

        guard let settings = JxlEncoderFrameSettingsCreate(encoder, nil) else {
            throw FormatError.encoderFailure("JXL frame settings")
        }
        try check(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, effort), encoder)
        if lossless {
            try check(JxlEncoderSetFrameLossless(settings, 1), encoder)
        } else {
            let distance = JxlEncoderDistanceFromQuality(Float(max(quality, 0)))
            try check(JxlEncoderSetFrameDistance(settings, distance), encoder)
        }
        var format = JxlPixelFormat(
            num_channels: hasAlpha ? 4 : 3, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)
        let samples = hasAlpha ? pixels.rgba : rgb(of: pixels)
        try check(
            samples.withUnsafeBytes { JxlEncoderAddImageFrame(settings, &format, $0.baseAddress, $0.count) }, encoder)
        JxlEncoderCloseInput(encoder)
        return try drain(encoder)
    }

    private static func setColor(of pixels: PixelBuffer, on encoder: OpaquePointer) throws {
        if pixels.colorSpace.name != CGColorSpace.sRGB, let icc = pixels.colorSpace.copyICCData() as Data? {
            try check(
                icc.withUnsafeBytes {
                    JxlEncoderSetICCProfile(encoder, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                },
                encoder)
            return
        }
        var color = JxlColorEncoding()
        JxlColorEncodingSetToSRGB(&color, 0)
        try check(JxlEncoderSetColorEncoding(encoder, &color), encoder)
    }

    private static func rgb(of pixels: PixelBuffer) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(pixels.pixelCount * 3)
        for index in stride(from: 0, to: pixels.rgba.count, by: 4) {
            output.append(contentsOf: pixels.rgba[index..<index + 3])
        }
        return output
    }

    private static func drain(_ encoder: OpaquePointer) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: outputChunk)
        while true {
            let (status, written) = buffer.withUnsafeMutableBufferPointer { chunk in
                var next = chunk.baseAddress
                var available = chunk.count
                let status = JxlEncoderProcessOutput(encoder, &next, &available)
                return (status, chunk.count - available)
            }
            output.append(contentsOf: buffer[0..<written])
            switch status {
            case JXL_ENC_SUCCESS: return output
            case JXL_ENC_NEED_MORE_OUTPUT: continue
            default: throw FormatError.encoderFailure("JXL error \(JxlEncoderGetError(encoder).rawValue)")
            }
        }
    }

    private static func check(_ status: JxlEncoderStatus, _ encoder: OpaquePointer) throws {
        guard status == JXL_ENC_SUCCESS else {
            throw FormatError.encoderFailure("JXL error \(JxlEncoderGetError(encoder).rawValue)")
        }
    }
}
