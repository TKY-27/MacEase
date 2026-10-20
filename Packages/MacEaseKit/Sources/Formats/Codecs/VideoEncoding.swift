import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public struct VideoEncoding: Sendable {
    public enum Codec: Sendable {
        case h264
        case hevc
        case vp9
        case mjpeg
        case prores4444
    }

    public var codec: Codec
    public var width: Int
    public var height: Int
    public var frameDuration: Int64
    /// Bits per second; `nil` encodes by `quality`.
    public var bitrate: Int?
    /// 0 to 1.
    public var quality = 0.7
    public var keyframeInterval = 2 * Nanoseconds.perSecond
    /// ProRes 4444 keeps alpha regardless.
    public var alpha = false

    public init(codec: Codec, width: Int, height: Int, frameDuration: Int64, bitrate: Int?) {
        self.codec = codec
        self.width = width
        self.height = height
        self.frameDuration = frameDuration
        self.bitrate = bitrate
    }

    var mediaCodec: MediaCodec {
        switch codec {
        case .h264: .h264
        case .hevc: .hevc
        case .vp9: .vp9
        case .mjpeg: .mjpeg
        case .prores4444: .prores
        }
    }
}

public protocol VideoFrameEncoder {
    /// Complete after the first packet.
    var track: MediaTrack { get }
    /// AVAssetWriter needs it for ProRes.
    var formatDescription: CMFormatDescription? { get }
    /// BGRA in, decode order out.
    mutating func encode(_ image: CVPixelBuffer, timestamp: Int64) throws -> [MediaPacket]
    mutating func finish() throws -> [MediaPacket]
}

public enum VideoEncoders {
    public static func make(_ settings: VideoEncoding, track number: Int) throws -> any VideoFrameEncoder {
        switch settings.codec {
        case .h264, .hevc, .prores4444: try ToolboxFrameEncoder(settings, number: number)
        case .vp9: try LibVPXFrameEncoder(settings, number: number)
        case .mjpeg: JPEGFrameEncoder(settings, number: number)
        }
    }

    static func track(_ settings: VideoEncoding, number: Int) -> MediaTrack {
        var track = MediaTrack(
            number: number, kind: .video(width: settings.width, height: settings.height), codec: settings.mediaCodec)
        track.defaultDuration = settings.frameDuration
        track.hasAlpha = settings.alpha
        return track
    }
}

/// H.264, HEVC with alpha, or ProRes 4444.
final class ToolboxFrameEncoder: VideoFrameEncoder {
    private let bitsPerByte = 8
    private(set) var track: MediaTrack
    private(set) var formatDescription: CMFormatDescription?
    private let session: VTCompressionSession
    private let settings: VideoEncoding
    private let output = CallbackResults<CMSampleBuffer> { .encoderFailure("VideoToolbox frame (\($0))") }

    init(_ settings: VideoEncoding, number: Int) throws {
        self.settings = settings
        track = VideoEncoders.track(settings, number: number)
        let codecType =
            switch settings.codec {
            case .h264: kCMVideoCodecType_H264
            case .hevc where settings.alpha: kCMVideoCodecType_HEVCWithAlpha
            case .prores4444: kCMVideoCodecType_AppleProRes4444
            default: kCMVideoCodecType_HEVC
            }
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.width), height: Int32(settings.height), codecType: codecType,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw FormatError.encoderFailure("VideoToolbox session (\(status))") }
        session = created
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: Double(Nanoseconds.perSecond) / Double(settings.frameDuration),
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        if settings.codec != .prores4444 {
            properties[kVTCompressionPropertyKey_ProfileLevel] =
                settings.codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
            properties[kVTCompressionPropertyKey_AllowFrameReordering] = true
            properties[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration] =
                Double(settings.keyframeInterval) / Double(Nanoseconds.perSecond)
            if let bitrate = settings.bitrate {
                properties[kVTCompressionPropertyKey_AverageBitRate] = bitrate
                // Hardware encoders overshoot averages on noisy content.
                properties[kVTCompressionPropertyKey_DataRateLimits] = [bitrate / bitsPerByte, 1] as CFArray
            } else {
                properties[kVTCompressionPropertyKey_Quality] = settings.quality
            }
        }
        if codecType == kCMVideoCodecType_HEVCWithAlpha {
            properties[kVTCompressionPropertyKey_TargetQualityForAlpha] = settings.quality
        }
        status = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        guard status == noErr else { throw FormatError.encoderFailure("VideoToolbox properties (\(status))") }
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else { throw FormatError.encoderFailure("VideoToolbox prepare (\(status))") }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func encode(_ image: CVPixelBuffer, timestamp: Int64) throws -> [MediaPacket] {
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image,
            presentationTimeStamp: CMTime(value: timestamp, timescale: SampleBuffers.nanosecondScale),
            duration: CMTime(value: settings.frameDuration, timescale: SampleBuffers.nanosecondScale),
            frameProperties: nil, infoFlagsOut: nil
        ) { [output] status, _, sample in
            if status != noErr { output.fail(status) }
            if let sample { output.append(sample) }
        }
        guard status == noErr else { throw FormatError.encoderFailure("VideoToolbox encode (\(status))") }
        return try drained()
    }

    func finish() throws -> [MediaPacket] {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw FormatError.encoderFailure("VideoToolbox flush (\(status))") }
        return try drained()
    }

    private func drained() throws -> [MediaPacket] {
        let samples = try output.take()
        if formatDescription == nil, let format = samples.first.flatMap(CMSampleBufferGetFormatDescription) {
            formatDescription = format
            track.codecPrivate = VideoFormat.decoderConfiguration(of: format)
        }
        return try samples.flatMap { try SampleBuffers.packets(from: $0, track: track.number) }
    }
}

extension SampleBuffers {
    /// Audio buffers hold many samples.
    public static func packets(from sample: CMSampleBuffer, track: Int) throws -> [MediaPacket] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw FormatError.encoderFailure("empty sample") }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length)
        let status = payload.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return noErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { throw FormatError.encoderFailure("sample copy (\(status))") }
        let count = CMSampleBufferGetNumSamples(sample)
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        var packets: [MediaPacket] = []
        var offset = 0
        for index in 0..<count {
            let size = count == 1 ? length : CMSampleBufferGetSampleSize(sample, at: index)
            guard size > 0, offset + size <= length else { throw FormatError.encoderFailure("sample sizes") }
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr else {
                throw FormatError.encoderFailure("sample timing")
            }
            let attachment = attachments.flatMap { $0.count > index ? $0[index] : nil }
            packets.append(
                MediaPacket(
                    track: track, timestamp: nanoseconds(timing.presentationTimeStamp),
                    decodeTimestamp: timing.decodeTimeStamp.isValid ? nanoseconds(timing.decodeTimeStamp) : nil,
                    duration: timing.duration.isValid ? nanoseconds(timing.duration) : nil,
                    isKeyframe: attachment?[kCMSampleAttachmentKey_NotSync] as? Bool != true,
                    payload: payload.subdata(in: offset..<(offset + size))))
            offset += size
        }
        return packets
    }

    public static func nanoseconds(_ time: CMTime) -> Int64 {
        time.convertScale(nanosecondScale, method: .roundHalfAwayFromZero).value
    }
}

/// VP9 alpha is a second gray stream.
final class LibVPXFrameEncoder: VideoFrameEncoder {
    private(set) var track: MediaTrack
    let formatDescription: CMFormatDescription? = nil
    private let settings: VideoEncoding
    private let color: VPXEncoder
    private let alpha: VPXEncoder?
    private let converter: YUVConverter
    private var frameIndex: Int64 = 0
    /// libvpx counts frames; packets need real times.
    private var timestamps: [Int64: Int64] = [:]

    init(_ settings: VideoEncoding, number: Int) throws {
        self.settings = settings
        track = VideoEncoders.track(settings, number: number)
        let framesPerSecond = Int((Double(Nanoseconds.perSecond) / Double(settings.frameDuration)).rounded())
        var vpx = VPXEncoder.Settings(
            codec: .vp9, width: settings.width, height: settings.height, framesPerSecond: max(framesPerSecond, 1),
            kilobitsPerSecond: settings.bitrate.map { max($0 / 1_000, 1) })
        vpx.constantQuality = Int((1 - settings.quality) * Double(VPXEncoder.worstQuality))
        vpx.keyframeInterval = Int(settings.keyframeInterval / settings.frameDuration)
        color = try VPXEncoder(settings: vpx)
        alpha = settings.alpha ? try VPXEncoder(settings: vpx) : nil
        converter = try YUVConverter(matrix: .bt601, fullRange: false)
    }

    func encode(_ image: CVPixelBuffer, timestamp: Int64) throws -> [MediaPacket] {
        let (picture, mask) = try converter.planes(of: image, withAlpha: alpha != nil)
        timestamps[frameIndex] = timestamp
        let colorFrames = try color.encode(picture, index: frameIndex)
        var alphaFrames: [EncodedVideoFrame] = []
        if let alpha, let mask {
            let keyframe = colorFrames.contains { $0.presentation == frameIndex && $0.isKeyframe }
            alphaFrames = try alpha.encode(mask, index: frameIndex, forceKeyframe: keyframe)
        }
        frameIndex += 1
        return try packets(colorFrames, alphaFrames)
    }

    func finish() throws -> [MediaPacket] {
        try packets(try color.finish(), try alpha?.finish() ?? [])
    }

    private func packets(_ colorFrames: [EncodedVideoFrame], _ alphaFrames: [EncodedVideoFrame]) throws
        -> [MediaPacket]
    {
        try colorFrames.map { frame in
            guard let timestamp = timestamps.removeValue(forKey: frame.presentation) else {
                throw FormatError.encoderFailure("libvpx returned an unknown frame")
            }
            return MediaPacket(
                track: track.number, timestamp: timestamp, duration: settings.frameDuration,
                isKeyframe: frame.isKeyframe, payload: frame.payload,
                additional: alphaFrames.first { $0.presentation == frame.presentation }?.payload)
        }
    }
}

/// ImageIO baseline JPEG per frame.
final class JPEGFrameEncoder: VideoFrameEncoder {
    let track: MediaTrack
    let formatDescription: CMFormatDescription? = nil
    private let quality: Double

    init(_ settings: VideoEncoding, number: Int) {
        track = VideoEncoders.track(settings, number: number)
        quality = settings.quality
    }

    func encode(_ image: CVPixelBuffer, timestamp: Int64) throws -> [MediaPacket] {
        let picture = try CGImage.make(from: image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw FormatError.encoderFailure("JPEG destination") }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, picture, options)
        guard CGImageDestinationFinalize(destination) else { throw FormatError.encoderFailure("JPEG frame") }
        return [MediaPacket(track: track.number, timestamp: timestamp, isKeyframe: true, payload: data as Data)]
    }

    func finish() throws -> [MediaPacket] { [] }
}

extension CGImage {
    /// Copies a BGRA pixel buffer.
    public static func make(from image: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        guard let base = CVPixelBufferGetBaseAddress(image),
            let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * height) as CFData),
            let picture = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FormatError.encoderFailure("frame image") }
        return picture
    }
}
