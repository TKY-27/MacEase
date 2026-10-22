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
    public var matrix = YUVMatrix.bt601
    public var isFullRange = false

    public var chromaWidth: Int { (width + 1) / 2 }
    public var chromaHeight: Int { (height + 1) / 2 }

    public init(width: Int, height: Int, luma: [UInt8], blueDifference: [UInt8], redDifference: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.blueDifference = blueDifference
        self.redDifference = redDifference
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

    public static let worstQuality = 63
    private static let speed: Int32 = 4
    private static let log2TileColumns: Int32 = 2
    private var context = vpx_codec_ctx_t()
    private let settings: Settings
    private var image = vpx_image_t()

    public init(settings: Settings) throws {
        guard settings.width > 0, settings.height > 0,
            Int32(exactly: settings.width) != nil, Int32(exactly: settings.height) != nil,
            settings.framesPerSecond > 0, Int32(exactly: settings.framesPerSecond) != nil,
            (0...Int(UInt32.max)).contains(settings.keyframeInterval),
            (0...Self.worstQuality).contains(settings.constantQuality),
            settings.kilobitsPerSecond.map({ (1...Int(UInt32.max)).contains($0) }) ?? true
        else {
            throw FormatError.corrupt(String(localized: "VPX settings out of range", comment: "Invalid video metadata"))
        }
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
                    image.cs = frame.matrix == .bt709 ? VPX_CS_BT_709 : VPX_CS_BT_601
                    image.range = frame.isFullRange ? VPX_CR_FULL_RANGE : VPX_CR_STUDIO_RANGE
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
        guard payload.count <= Int(UInt32.max) else {
            throw FormatError.corrupt(String(localized: "VPX packet too large", comment: "Invalid video packet"))
        }
        try payload.withUnsafeBytes { bytes in
            try VPXEncoder.check(
                vpx_codec_decode(&context, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count), nil, 0)
            )
        }
        var frames: [YUVFrame] = []
        var iterator: vpx_codec_iter_t?
        while let image = vpx_codec_get_frame(&context, &iterator) {
            guard image.pointee.fmt == VPX_IMG_FMT_I420 else { throw FormatError.unsupported("VPX image format") }
            frames.append(try Self.copy(image.pointee))
        }
        return frames
    }

    private static func copy(_ image: vpx_image_t) throws -> YUVFrame {
        let width = Int(image.d_w)
        let height = Int(image.d_h)
        _ = try VideoDecoders.checkedFrameBytes(width: width, height: height)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        var frame = YUVFrame(
            width: width, height: height,
            luma: try YUVConverter.copyPlane(image.planes.0, stride: Int(image.stride.0), columns: width, rows: height),
            blueDifference: try YUVConverter.copyPlane(
                image.planes.1, stride: Int(image.stride.1), columns: chromaWidth, rows: chromaHeight),
            redDifference: try YUVConverter.copyPlane(
                image.planes.2, stride: Int(image.stride.2), columns: chromaWidth, rows: chromaHeight)
        )
        frame.matrix = image.cs == VPX_CS_BT_709 ? .bt709 : .bt601
        frame.isFullRange = image.range == VPX_CR_FULL_RANGE
        return frame
    }
}
