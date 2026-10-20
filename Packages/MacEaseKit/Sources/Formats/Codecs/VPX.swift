import CVPX
import Foundation
import NativeShims

/// Planar 8-bit 4:2:0 with tightly packed rows.
public struct YUVFrame: Sendable {
    public let width: Int
    public let height: Int
    public var luma: [UInt8]
    public var blueDifference: [UInt8]
    public var redDifference: [UInt8]

    public var chromaWidth: Int { (width + 1) / 2 }
    public var chromaHeight: Int { (height + 1) / 2 }

    public init(width: Int, height: Int, luma: [UInt8], blueDifference: [UInt8], redDifference: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.blueDifference = blueDifference
        self.redDifference = redDifference
    }

    /// BT.601 limited range, as browsers assume.
    public init(rgba pixels: PixelBuffer) {
        let width = pixels.width
        let height = pixels.height
        var luma = [UInt8](repeating: 0, count: width * height)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        var blue = [UInt8](repeating: 128, count: chromaWidth * chromaHeight)
        var red = [UInt8](repeating: 128, count: chromaWidth * chromaHeight)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let r = Double(pixels.rgba[base])
                let g = Double(pixels.rgba[base + 1])
                let b = Double(pixels.rgba[base + 2])
                luma[y * width + x] = UInt8(min(max(16 + 0.257 * r + 0.504 * g + 0.098 * b, 0), 255).rounded())
            }
        }
        for y in 0..<chromaHeight {
            for x in 0..<chromaWidth {
                var sums = (r: 0.0, g: 0.0, b: 0.0, count: 0.0)
                for dy in 0..<2 where 2 * y + dy < height {
                    for dx in 0..<2 where 2 * x + dx < width {
                        let base = ((2 * y + dy) * width + 2 * x + dx) * 4
                        sums.r += Double(pixels.rgba[base])
                        sums.g += Double(pixels.rgba[base + 1])
                        sums.b += Double(pixels.rgba[base + 2])
                        sums.count += 1
                    }
                }
                let (r, g, b) = (sums.r / sums.count, sums.g / sums.count, sums.b / sums.count)
                blue[y * chromaWidth + x] = UInt8(min(max(128 - 0.148 * r - 0.291 * g + 0.439 * b, 0), 255).rounded())
                red[y * chromaWidth + x] = UInt8(min(max(128 + 0.439 * r - 0.368 * g - 0.071 * b, 0), 255).rounded())
            }
        }
        self.init(width: width, height: height, luma: luma, blueDifference: blue, redDifference: red)
    }

    /// Gray planes carry VP9 alpha.
    public init(gray: [UInt8], width: Int, height: Int) {
        let chroma = [UInt8](repeating: 128, count: ((width + 1) / 2) * ((height + 1) / 2))
        self.init(width: width, height: height, luma: gray, blueDifference: chroma, redDifference: chroma)
    }
}

public struct EncodedVideoFrame: Sendable {
    public let payload: Data
    /// In frame-duration units.
    public let presentation: Int64
    public let isKeyframe: Bool
}

public final class VPXEncoder {
    public enum Codec: Sendable {
        case vp8
        case vp9
    }

    public struct Settings: Sendable {
        public var codec: Codec
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        /// `nil` selects constant quality.
        public var kilobitsPerSecond: Int?
        /// 0 (best) to 63, without a bitrate.
        public var constantQuality = 32
        public var keyframeInterval = 240

        public init(codec: Codec, width: Int, height: Int, framesPerSecond: Int, kilobitsPerSecond: Int?) {
            self.codec = codec
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.kilobitsPerSecond = kilobitsPerSecond
        }
    }

    private static let speed: Int32 = 4
    private static let log2TileColumns: Int32 = 2
    private var context = vpx_codec_ctx_t()
    private let settings: Settings
    private var image = vpx_image_t()

    public init(settings: Settings) throws {
        self.settings = settings
        let vp9: Int32 = settings.codec == .vp9 ? 1 : 0
        var config = vpx_codec_enc_cfg_t()
        try Self.check(macease_vpx_default_config(&config, vp9))
        config.g_w = UInt32(settings.width)
        config.g_h = UInt32(settings.height)
        config.g_timebase = vpx_rational(num: 1, den: Int32(settings.framesPerSecond))
        config.g_threads = UInt32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        config.g_lag_in_frames = 0
        config.kf_max_dist = UInt32(settings.keyframeInterval)
        config.g_error_resilient = 0
        if let bitrate = settings.kilobitsPerSecond {
            config.rc_end_usage = VPX_VBR
            config.rc_target_bitrate = UInt32(bitrate)
        } else {
            config.rc_end_usage = VPX_Q
        }
        try Self.check(macease_vpx_encoder_init(&context, &config, vp9))
        try Self.check(macease_vpx_control(&context, macease_vpx_control_cpu_used(), Self.speed))
        if settings.kilobitsPerSecond == nil {
            try Self.check(
                macease_vpx_control(&context, macease_vpx_control_cq_level(), Int32(settings.constantQuality)))
        }
        if settings.codec == .vp9 {
            try Self.check(macease_vpx_control(&context, macease_vpx_control_row_mt(), 1))
            try Self.check(macease_vpx_control(&context, macease_vpx_control_tile_columns(), Self.log2TileColumns))
        }
    }

    deinit {
        vpx_codec_destroy(&context)
    }

    static func check(_ status: vpx_codec_err_t) throws {
        guard status == VPX_CODEC_OK else {
            throw FormatError.encoderFailure("libvpx: \(String(cString: vpx_codec_err_to_string(status)))")
        }
    }

    public func encode(_ frame: YUVFrame, index: Int64, forceKeyframe: Bool = false) throws -> [EncodedVideoFrame] {
        guard frame.width == settings.width, frame.height == settings.height else {
            throw FormatError.encoderFailure("frame size changed")
        }
        let chromaSize = frame.chromaWidth * frame.chromaHeight
        guard frame.luma.count == frame.width * frame.height, frame.blueDifference.count == chromaSize,
            frame.redDifference.count == chromaSize
        else { throw FormatError.encoderFailure("plane sizes do not match the frame") }
        var planes = frame
        try planes.luma.withUnsafeMutableBufferPointer { luma in
            try planes.blueDifference.withUnsafeMutableBufferPointer { blue in
                try planes.redDifference.withUnsafeMutableBufferPointer { red in
                    vpx_img_wrap(
                        &image, VPX_IMG_FMT_I420, UInt32(frame.width), UInt32(frame.height), 1, luma.baseAddress)
                    image.planes.0 = luma.baseAddress
                    image.planes.1 = blue.baseAddress
                    image.planes.2 = red.baseAddress
                    image.stride.0 = Int32(frame.width)
                    image.stride.1 = Int32(frame.chromaWidth)
                    image.stride.2 = Int32(frame.chromaWidth)
                    let flags = forceKeyframe ? vpx_enc_frame_flags_t(VPX_EFLAG_FORCE_KF) : 0
                    try Self.check(vpx_codec_encode(&context, &image, index, 1, flags, UInt(VPX_DL_GOOD_QUALITY)))
                }
            }
        }
        return drain()
    }

    public func finish() throws -> [EncodedVideoFrame] {
        var collected: [EncodedVideoFrame] = []
        while true {
            try Self.check(vpx_codec_encode(&context, nil, 0, 1, 0, UInt(VPX_DL_GOOD_QUALITY)))
            let frames = drain()
            if frames.isEmpty { return collected }
            collected += frames
        }
    }

    private func drain() -> [EncodedVideoFrame] {
        var frames: [EncodedVideoFrame] = []
        var iterator: vpx_codec_iter_t?
        while let packet = vpx_codec_get_cx_data(&context, &iterator) {
            guard packet.pointee.kind == VPX_CODEC_CX_FRAME_PKT else { continue }
            let frame = packet.pointee.data.frame
            frames.append(
                EncodedVideoFrame(
                    payload: Data(bytes: frame.buf, count: frame.sz), presentation: frame.pts,
                    isKeyframe: frame.flags & vpx_codec_frame_flags_t(VPX_FRAME_IS_KEY) != 0
                )
            )
        }
        return frames
    }
}

public final class VPXDecoder {
    private var context = vpx_codec_ctx_t()

    public init(vp9: Bool) throws {
        let threads = UInt32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        try VPXEncoder.check(macease_vpx_decoder_init(&context, vp9 ? 1 : 0, threads))
    }

    deinit {
        vpx_codec_destroy(&context)
    }

    public func decode(_ payload: Data) throws -> [YUVFrame] {
        try payload.withUnsafeBytes { bytes in
            try VPXEncoder.check(
                vpx_codec_decode(&context, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count), nil, 0)
            )
        }
        var frames: [YUVFrame] = []
        var iterator: vpx_codec_iter_t?
        while let image = vpx_codec_get_frame(&context, &iterator) {
            guard image.pointee.fmt == VPX_IMG_FMT_I420 else { throw FormatError.unsupported("VPX image format") }
            frames.append(Self.copy(image.pointee))
        }
        return frames
    }

    private static func copy(_ image: vpx_image_t) -> YUVFrame {
        let width = Int(image.d_w)
        let height = Int(image.d_h)
        func plane(_ pointer: UnsafeMutablePointer<UInt8>?, stride: Int32, columns: Int, rows: Int) -> [UInt8] {
            guard let pointer else { return [] }
            var result = [UInt8](repeating: 0, count: columns * rows)
            for row in 0..<rows {
                for column in 0..<columns { result[row * columns + column] = pointer[row * Int(stride) + column] }
            }
            return result
        }
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        return YUVFrame(
            width: width, height: height,
            luma: plane(image.planes.0, stride: image.stride.0, columns: width, rows: height),
            blueDifference: plane(image.planes.1, stride: image.stride.1, columns: chromaWidth, rows: chromaHeight),
            redDifference: plane(image.planes.2, stride: image.stride.2, columns: chromaWidth, rows: chromaHeight)
        )
    }
}
