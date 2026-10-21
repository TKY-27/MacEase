import Accelerate
import CDav1d
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// BGRA at presentation time.
public struct DecodedFrame {
    public let image: CVPixelBuffer
    public let timestamp: Int64

    public init(image: CVPixelBuffer, timestamp: Int64) {
        self.image = image
        self.timestamp = timestamp
    }
}

public protocol VideoFrameDecoder {
    /// Frames come out in presentation order.
    mutating func decode(_ packet: MediaPacket) throws -> [DecodedFrame]
    mutating func finish() throws -> [DecodedFrame]
}

public enum VideoDecoders {
    static let maximumDimension = 16_384
    static let bgraBytesPerPixel = 4

    static func checkedFrameBytes(width: Int, height: Int) throws -> Int {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw FormatError.corrupt("video dimensions out of range")
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bgraBytesPerPixel)
        guard !pixelOverflow, !byteOverflow else { throw FormatError.corrupt("video frame size overflow") }
        return bytes
    }

    public static func make(for track: MediaTrack) throws -> any VideoFrameDecoder {
        switch track.codec {
        case .vp8, .vp9: try LibVPXFrameDecoder(track: track)
        case .av1 where !ToolboxFrameDecoder.opensSession(for: track): try Dav1dFrameDecoder()
        case .mjpeg: JPEGFrameDecoder()
        case .h264, .hevc, .mpeg4Part2, .av1: try ToolboxFrameDecoder(track: track)
        default: throw FormatError.unsupported(track.codec.displayName)
        }
    }

    static let pixelFormat = kCVPixelFormatType_32BGRA
    static let maximumThreads = 8

    static func makeImage(width: Int, height: Int) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        let status = CVPixelBufferCreate(nil, width, height, pixelFormat, attributes as CFDictionary, &image)
        guard status == kCVReturnSuccess, let image else { throw FormatError.decoderFailure("pixel buffer \(status)") }
        return image
    }
}

/// VideoToolbox, reordered by `ReorderBuffer`.
final class ToolboxFrameDecoder: VideoFrameDecoder {
    private var track: MediaTrack
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private let output = CallbackResults<DecodedFrame> { .decoderFailure("VideoToolbox frame (\($0))") }
    private var annexB = false
    private var reorder: ReorderBuffer

    init(track: MediaTrack) throws {
        self.track = track
        guard case .video(let width, let height) = track.kind else { throw FormatError.unsupported("not video") }
        reorder = try ReorderBuffer(width: width, height: height)
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Virtual Macs claim AV1 hardware falsely.
    static func opensSession(for track: MediaTrack) -> Bool {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            let format = try? VideoFormat.description(for: track)
        else { return false }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
            outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }

    private func prepare(with packet: MediaPacket) throws -> (VTDecompressionSession, CMVideoFormatDescription) {
        if let session, let format { return (session, format) }
        if track.codec == .h264, track.codecPrivate == nil, VideoFormat.isAnnexB(packet.payload) {
            track.codecPrivate = try VideoFormat.avcConfiguration(annexB: packet.payload)
            annexB = true
        }
        if track.codec == .mpeg4Part2, track.codecPrivate == nil {
            track.codecPrivate = VideoFormat.mpeg4Header(inKeyframe: packet.payload)
        }
        let format = try VideoFormat.description(for: track)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: VideoDecoders.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw FormatError.unsupported("\(track.codec.displayName) decoding (\(status))")
        }
        self.session = session
        self.format = format
        return (session, format)
    }

    func decode(_ packet: MediaPacket) throws -> [DecodedFrame] {
        let (session, format) = try prepare(with: packet)
        let payload = try annexB ? VideoFormat.lengthPrefixed(annexB: packet.payload) : packet.payload
        let sample = try SampleBuffers.make(payload, packet: packet, format: format)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [output] status, _, image, presentation, _ in
            guard status == noErr else {
                output.fail(status)
                return
            }
            guard let image else { return }
            output.append(DecodedFrame(image: image, timestamp: SampleBuffers.nanoseconds(presentation)))
        }
        guard status == noErr else { throw FormatError.decoderFailure("VideoToolbox decode (\(status))") }
        try reorder.add(try output.take())
        return reorder.ready()
    }

    func finish() throws -> [DecodedFrame] {
        guard let session else { return [] }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        try reorder.add(try output.take())
        return reorder.remaining()
    }
}

/// VideoToolbox emits frames in decode order.
struct ReorderBuffer {
    /// About 256 MB of BGRA frames.
    private static let memoryBudget = 256 << 20
    private static let depthRange = 4...16

    private let depth: Int
    private var pending: [DecodedFrame] = []
    private var lastEmitted: Int64?

    init(width: Int, height: Int) throws {
        let frameBytes = try VideoDecoders.checkedFrameBytes(width: width, height: height)
        depth = min(max(Self.memoryBudget / frameBytes, Self.depthRange.lowerBound), Self.depthRange.upperBound)
    }

    mutating func add(_ frames: [DecodedFrame]) throws {
        for frame in frames {
            if let lastEmitted, frame.timestamp < lastEmitted {
                throw FormatError.unsupported("frame reordering deeper than \(depth) frames")
            }
            let index = pending.firstIndex { $0.timestamp > frame.timestamp } ?? pending.count
            pending.insert(frame, at: index)
        }
    }

    mutating func ready() -> [DecodedFrame] {
        guard pending.count > depth else { return [] }
        let ready = Array(pending.prefix(pending.count - depth))
        pending.removeFirst(ready.count)
        lastEmitted = ready.last?.timestamp
        return ready
    }

    mutating func remaining() -> [DecodedFrame] {
        defer { pending = [] }
        lastEmitted = pending.last?.timestamp ?? lastEmitted
        return pending
    }
}

public enum SampleBuffers {
    public static let nanosecondScale = CMTimeScale(Nanoseconds.perSecond)

    public static func make(_ payload: Data, packet: MediaPacket, format: CMFormatDescription) throws
        -> CMSampleBuffer
    {
        guard payload.count <= Int(UInt32.max) else {
            throw FormatError.corrupt(String(localized: "Media packet too large", comment: "Invalid sample payload"))
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block
        )
        guard status == noErr, let block else { throw FormatError.decoderFailure("block buffer (\(status))") }
        status = payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return noErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw FormatError.decoderFailure("block copy (\(status))") }
        let timeScale: CMTimeScale
        if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio {
            guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                let rate = CMTimeScale(exactly: basic.mSampleRate), rate > 0
            else { throw FormatError.decoderFailure("audio sample rate") }
            timeScale = rate
        } else {
            timeScale = nanosecondScale
        }
        func sampleTime(_ nanoseconds: Int64) -> CMTime {
            CMTime(value: nanoseconds, timescale: nanosecondScale).convertScale(
                timeScale, method: .roundHalfAwayFromZero)
        }
        let presentation = sampleTime(packet.timestamp)
        var sample: CMSampleBuffer?
        if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio {
            var description = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                presentationTimeStamp: presentation, packetDescriptions: &description, sampleBufferOut: &sample)
        } else {
            var timing = CMSampleTimingInfo(
                duration: packet.duration.map { CMTime(value: $0, timescale: nanosecondScale) } ?? .invalid,
                presentationTimeStamp: presentation,
                decodeTimeStamp: packet.decodeTimestamp.map { CMTime(value: $0, timescale: nanosecondScale) }
                    ?? .invalid
            )
            var size = payload.count
            status = CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample
            )
        }
        guard status == noErr, let sample else { throw FormatError.decoderFailure("sample buffer (\(status))") }
        packet.audioAttachments?.apply(to: sample)
        for (key, duration) in [
            (kCMSampleBufferAttachmentKey_TrimDurationAtStart, packet.trimDurationAtStart),
            (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, packet.discardPadding),
        ] {
            if let duration {
                CMSetAttachment(
                    sample, key: key,
                    value: CMTimeCopyAsDictionary(sampleTime(duration), allocator: nil),
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            } else {
                CMRemoveAttachment(sample, key: key)
            }
        }
        if let timestamp = packet.outputTimestamp {
            let status = CMSampleBufferSetOutputPresentationTimeStamp(
                sample, newValue: sampleTime(timestamp))
            guard status == noErr else { throw FormatError.decoderFailure("sample output timing (\(status))") }
        }
        if !packet.isKeyframe {
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
                    as NSArray?,
                let first = attachments.firstObject as? NSMutableDictionary
            else { throw FormatError.decoderFailure("sample attachments") }
            first[kCMSampleAttachmentKey_NotSync] = true
        }
        return sample
    }
}

/// VideoToolbox rejects ffmpeg's AVI Motion JPEG.
final class JPEGFrameDecoder: VideoFrameDecoder {
    func decode(_ packet: MediaPacket) throws -> [DecodedFrame] {
        guard let source = CGImageSourceCreateWithData(packet.payload as CFData, nil),
            let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FormatError.decoderFailure("Motion JPEG frame does not decode") }
        let image = try VideoDecoders.makeImage(width: picture.width, height: picture.height)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(image), width: picture.width, height: picture.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(image),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        else { throw FormatError.decoderFailure("Motion JPEG drawing context") }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        return [DecodedFrame(image: image, timestamp: packet.timestamp)]
    }

    func finish() throws -> [DecodedFrame] { [] }
}

/// libvpx, with VP9 alpha from BlockAdditions.
final class LibVPXFrameDecoder: VideoFrameDecoder {
    private let color: VPXDecoder
    private let alpha: VPXDecoder?
    private var converter: YUVConverter?

    init(track: MediaTrack) throws {
        let vp9 = track.codec == .vp9
        color = try VPXDecoder(vp9: vp9)
        alpha = track.hasAlpha ? try VPXDecoder(vp9: vp9) : nil
    }

    func decode(_ packet: MediaPacket) throws -> [DecodedFrame] {
        let pictures = try color.decode(packet.payload)
        var masks: [YUVFrame] = []
        if let alpha, let additional = packet.additional { masks = try alpha.decode(additional) }
        let hasAlphaPacket = alpha != nil && packet.additional != nil
        guard !hasAlphaPacket || masks.count == pictures.count else {
            throw FormatError.decoderFailure("VP9 alpha frame count differs from color")
        }
        return try pictures.enumerated().map { index, picture in
            let mask: [UInt8]?
            if hasAlphaPacket {
                let alphaFrame = masks[index]
                let pixelCount =
                    try VideoDecoders.checkedFrameBytes(width: picture.width, height: picture.height)
                    / VideoDecoders.bgraBytesPerPixel
                guard alphaFrame.width == picture.width, alphaFrame.height == picture.height,
                    alphaFrame.luma.count == pixelCount
                else { throw FormatError.decoderFailure("VP9 alpha dimensions differ from color") }
                mask = alphaFrame.luma
            } else {
                mask = nil
            }
            let converter = try converter(for: picture)
            return DecodedFrame(image: try converter.image(from: picture, alpha: mask), timestamp: packet.timestamp)
        }
    }

    private func converter(for picture: YUVFrame) throws -> YUVConverter {
        if let converter, converter.matrix == picture.matrix, converter.isFullRange == picture.isFullRange {
            return converter
        }
        let created = try YUVConverter(matrix: picture.matrix, fullRange: picture.isFullRange)
        converter = created
        return created
    }

    func finish() throws -> [DecodedFrame] { [] }
}

/// For AV1 without hardware decoding.
final class Dav1dFrameDecoder: VideoFrameDecoder {
    private var context: OpaquePointer?
    private var converter: YUVConverter?

    init() throws {
        var settings = Dav1dSettings()
        dav1d_default_settings(&settings)
        settings.n_threads = Int32(min(VideoDecoders.maximumThreads, ProcessInfo.processInfo.activeProcessorCount))
        guard dav1d_open(&context, &settings) == 0, context != nil else {
            throw FormatError.decoderFailure("dav1d_open")
        }
    }

    deinit {
        dav1d_close(&context)
    }

    func decode(_ packet: MediaPacket) throws -> [DecodedFrame] {
        var data = Dav1dData()
        let bytes = [UInt8](packet.payload)
        guard let buffer = dav1d_data_create(&data, bytes.count) else { throw FormatError.decoderFailure("dav1d data") }
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.update(from: base, count: source.count) }
        }
        data.m.timestamp = packet.timestamp
        var frames: [DecodedFrame] = []
        while data.sz > 0 {
            let status = dav1d_send_data(context, &data)
            guard status == 0 || status == -EAGAIN else {
                dav1d_data_unref(&data)
                throw FormatError.decoderFailure("dav1d_send_data \(status)")
            }
            frames += try pictures()
        }
        return frames
    }

    func finish() throws -> [DecodedFrame] {
        try pictures()
    }

    private func pictures() throws -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        while true {
            var picture = Dav1dPicture()
            let status = dav1d_get_picture(context, &picture)
            if status == -EAGAIN { return frames }
            guard status == 0 else { throw FormatError.decoderFailure("dav1d_get_picture \(status)") }
            defer { dav1d_picture_unref(&picture) }
            frames.append(DecodedFrame(image: try image(of: picture), timestamp: picture.m.timestamp))
        }
    }

    private func image(of picture: Dav1dPicture) throws -> CVPixelBuffer {
        guard picture.p.layout == DAV1D_PIXEL_LAYOUT_I420 else {
            throw FormatError.unsupported("AV1 chroma other than 4:2:0 without hardware decoding")
        }
        let width = Int(picture.p.w)
        let height = Int(picture.p.h)
        let depth = Int(picture.p.bpc)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let frame = YUVFrame(
            width: width, height: height,
            luma: try YUVConverter.copyPlane(
                picture.data.0, stride: Int(picture.stride.0), columns: width, rows: height, bitDepth: depth),
            blueDifference: try YUVConverter.copyPlane(
                picture.data.1, stride: Int(picture.stride.1), columns: chromaWidth, rows: chromaHeight,
                bitDepth: depth),
            redDifference: try YUVConverter.copyPlane(
                picture.data.2, stride: Int(picture.stride.1), columns: chromaWidth, rows: chromaHeight,
                bitDepth: depth)
        )
        let header = picture.seq_hdr?.pointee
        let matrix: YUVMatrix = header?.mtrx == DAV1D_MC_BT709 ? .bt709 : .bt601
        let fullRange = header?.color_range == 1
        if converter?.matrix != matrix || converter?.isFullRange != fullRange {
            converter = try YUVConverter(matrix: matrix, fullRange: fullRange)
        }
        guard let converter else { throw FormatError.decoderFailure("YUV converter") }
        return try converter.image(from: frame, alpha: nil)
    }
}
