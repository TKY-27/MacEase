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
    /// VP9 only; alpha travels in BlockAdditions.
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
        }
    }
}

public protocol VideoFrameEncoder {
    /// Complete after the first packet.
    var track: MediaTrack { get }
    /// BGRA in, decode order out.
    mutating func encode(_ image: CVPixelBuffer, timestamp: Int64) throws -> [MediaPacket]
    mutating func finish() throws -> [MediaPacket]
}

public enum VideoEncoders {
    public static func make(_ settings: VideoEncoding, track number: Int) throws -> any VideoFrameEncoder {
        switch settings.codec {
        case .h264, .hevc: try ToolboxFrameEncoder(settings, number: number)
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

/// VideoToolbox H.264 High or HEVC Main.
final class ToolboxFrameEncoder: VideoFrameEncoder {
    private(set) var track: MediaTrack
    private let session: VTCompressionSession
    private let settings: VideoEncoding
    private let output = SampleCollector()

    init(_ settings: VideoEncoding, number: Int) throws {
        self.settings = settings
        track = VideoEncoders.track(settings, number: number)
        let codecType = settings.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.width), height: Int32(settings.height), codecType: codecType,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw FormatError.encoderFailure("VideoToolbox session (\(status))") }
        session = created
        let profile =
            settings.codec == .h264
            ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AllowFrameReordering: true,
            kVTCompressionPropertyKey_ExpectedFrameRate: Double(Nanoseconds.perSecond) / Double(settings.frameDuration),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:
                Double(settings.keyframeInterval) / Double(Nanoseconds.perSecond),
        ]
        if let bitrate = settings.bitrate {
            properties[kVTCompressionPropertyKey_AverageBitRate] = bitrate
        } else {
            properties[kVTCompressionPropertyKey_Quality] = settings.quality
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
        ) { [output] status, _, sample in output.add(status, sample) }
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
        if track.codecPrivate == nil, let format = samples.first.flatMap(CMSampleBufferGetFormatDescription) {
            track.codecPrivate = VideoFormat.decoderConfiguration(of: format)
        }
        return try samples.flatMap { try SampleBuffers.packets(from: $0, track: track.number) }
    }
}

/// Lock-guarded; VideoToolbox handlers must be Sendable.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var failure: OSStatus?

    func add(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.withLock {
            if status != noErr { failure = failure ?? status }
            if let sample { samples.append(sample) }
        }
    }

    func take() throws -> [CMSampleBuffer] {
        try lock.withLock {
            if let failure { throw FormatError.encoderFailure("VideoToolbox frame (\(failure))") }
            defer { samples = [] }
            return samples
        }
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
            let attachment = attachments.map { $0.count > index ? $0[index] : $0.first ?? [:] }
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
    private let settings: VideoEncoding
    private let color: VPXEncoder
    private let alpha: VPXEncoder?
    private var frameIndex: Int64 = 0

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
    }

    func encode(_ image: CVPixelBuffer, timestamp: Int64) throws -> [MediaPacket] {
        let (picture, mask) = try YUVFrame.planes(of: image, withAlpha: alpha != nil)
        let colorFrames = try color.encode(picture, index: frameIndex)
        let alphaFrames = try mask.map { try alpha?.encode($0, index: frameIndex, forceKeyframe: false) ?? [] } ?? []
        frameIndex += 1
        return packets(colorFrames, alphaFrames)
    }

    func finish() throws -> [MediaPacket] {
        packets(try color.finish(), try alpha?.finish() ?? [])
    }

    private func packets(_ colorFrames: [EncodedVideoFrame], _ alphaFrames: [EncodedVideoFrame]) -> [MediaPacket] {
        colorFrames.map { frame in
            MediaPacket(
                track: track.number, timestamp: frame.presentation * settings.frameDuration,
                duration: settings.frameDuration, isKeyframe: frame.isKeyframe, payload: frame.payload,
                additional: alphaFrames.first { $0.presentation == frame.presentation }?.payload)
        }
    }
}

/// ImageIO baseline JPEG per frame.
final class JPEGFrameEncoder: VideoFrameEncoder {
    let track: MediaTrack
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

extension YUVFrame {
    /// ITU-R BT.601 coefficients for encoding, limited range.
    private static let bt601Matrix = vImage_ARGBToYpCbCrMatrix(
        R_Yp: 0.299, G_Yp: 0.587, B_Yp: 0.114, R_Cb: -0.168_736, G_Cb: -0.331_264, B_Cb_R_Cr: 0.5, G_Cr: -0.418_688,
        B_Cr: -0.081_312)
    private static let videoRange = vImage_YpCbCrPixelRange(
        Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)

    /// Alpha comes back as a gray plane.
    static func planes(of image: CVPixelBuffer, withAlpha: Bool) throws -> (YUVFrame, YUVFrame?) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw FormatError.encoderFailure("pixel buffer") }
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        var luma = [UInt8](repeating: 0, count: width * height)
        var blue = [UInt8](repeating: 0, count: chromaWidth * chromaHeight)
        var red = [UInt8](repeating: 0, count: chromaWidth * chromaHeight)
        var conversion = vImage_ARGBToYpCbCr()
        var matrix = bt601Matrix
        var range = videoRange
        var status = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            &matrix, &range, &conversion, kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { throw FormatError.encoderFailure("YUV conversion setup \(status)") }
        var source = vImage_Buffer(
            data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(image))
        status = luma.withUnsafeMutableBytes { lumaBytes in
            blue.withUnsafeMutableBytes { blueBytes in
                red.withUnsafeMutableBytes { redBytes in
                    var y = vImage_Buffer(
                        data: lumaBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                        rowBytes: width)
                    var cb = vImage_Buffer(
                        data: blueBytes.baseAddress, height: vImagePixelCount(chromaHeight),
                        width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    var cr = vImage_Buffer(
                        data: redBytes.baseAddress, height: vImagePixelCount(chromaHeight),
                        width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    let fromBGRA: [UInt8] = [3, 2, 1, 0]
                    return vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(
                        &source, &y, &cb, &cr, &conversion, fromBGRA, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard status == kvImageNoError else { throw FormatError.encoderFailure("YUV conversion \(status)") }
        let picture = YUVFrame(width: width, height: height, luma: luma, blueDifference: blue, redDifference: red)
        guard withAlpha else { return (picture, nil) }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        var gray = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let opacity = Int(pixels[row * rowBytes + column * 4 + 3])
                gray[row * width + column] = UInt8(16 + opacity * 219 / 255)
            }
        }
        return (picture, YUVFrame(gray: gray, width: width, height: height))
    }
}
