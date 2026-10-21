import AVFoundation
import CoreMedia
import Formats
import Foundation

enum AssetTracks {
    static func describe(_ track: AVAssetTrack, number: Int) async throws -> MediaTrack {
        guard let format = try await track.load(.formatDescriptions).first else {
            throw EngineError.decodeFailed("track without a format")
        }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            var described = MediaTrack(
                number: number, kind: .video(width: Int(size.width), height: Int(size.height)),
                codec: videoCodec(subtype), codecPrivate: VideoFormat.decoderConfiguration(of: format))
            let rate = try await track.load(.nominalFrameRate)
            guard rate.isFinite, rate >= 0 else { throw EngineError.decodeFailed("video frame rate out of range") }
            if rate > 0 {
                let duration = (Double(Nanoseconds.perSecond) / Double(rate)).rounded()
                guard duration.isFinite, duration < Double(Int64.max) else {
                    throw EngineError.decodeFailed("video frame duration out of range")
                }
                described.defaultDuration = Int64(duration)
            }
            described.hasAlpha = VideoFormat.containsAlpha(format)
            return described
        }
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw EngineError.decodeFailed("audio track without a stream description")
        }
        var described = MediaTrack(
            number: number, kind: .audio(sampleRate: basic.mSampleRate, channels: Int(basic.mChannelsPerFrame)),
            codec: audioCodec(basic))
        if described.codec == .aac {
            var size = 0
            if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), size > 0 {
                described.codecPrivate = ElementaryStream.decoderSpecificInfo(in: Data(bytes: cookie, count: size))
            }
        }
        return described
    }

    static func videoCodec(_ subtype: FourCharCode) -> MediaCodec {
        switch subtype {
        case kCMVideoCodecType_H264: .h264
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, FourCharCode("hev1"): .hevc
        case kCMVideoCodecType_MPEG4Video: .mpeg4Part2
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: .mjpeg
        case kCMVideoCodecType_AV1: .av1
        case kCMVideoCodecType_VP9: .vp9
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
            kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444,
            kCMVideoCodecType_AppleProRes4444XQ:
            .prores
        default: .unsupported(FourCharCode.string(subtype))
        }
    }

    static func audioCodec(_ basic: AudioStreamBasicDescription) -> MediaCodec {
        switch basic.mFormatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: .aac
        case kAudioFormatAppleLossless: .alac
        case kAudioFormatMPEGLayer3: .mp3
        case kAudioFormatAC3: .ac3
        case kAudioFormatOpus: .opus
        case kAudioFormatFLAC: .flac
        case kAudioFormatLinearPCM:
            .pcm(
                bits: Int(basic.mBitsPerChannel), float: basic.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                bigEndian: basic.mFormatFlags & kAudioFormatFlagIsBigEndian != 0)
        default: .unsupported(FourCharCode.string(basic.mFormatID))
        }
    }
}

extension FourCharCode {
    fileprivate init(_ code: String) {
        self = code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    fileprivate static func string(_ code: FourCharCode) -> String {
        String(decoding: (0..<4).map { UInt8(code >> (24 - 8 * $0) & 0xFF) }, as: UTF8.self)
    }
}

/// Blocking reads would starve the cooperative pool.
final class AssetTrackReader: @unchecked Sendable {
    enum Mode {
        case packets
        case frames
        case sdrFrames
        /// Interleaved 32-bit float.
        case pcm
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let number: Int
    private let queue = DispatchQueue(label: "MacEase.AssetTrackReader")

    init(asset: AVAsset, track: AVAssetTrack, number: Int, mode: Mode, range: CMTimeRange? = nil) throws {
        reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        self.number = number
        let settings: [String: Any]? =
            switch mode {
            case .packets: nil
            case .frames:
                [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ]
            case .sdrFrames:
                [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                    ],
                ]
            case .pcm:
                [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                ]
            }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.decodeFailed("track cannot be read") }
        reader.add(output)
        guard reader.startReading() else {
            throw EngineError.decodeFailed(reader.error.map { "\($0)" } ?? "reader did not start")
        }
    }

    deinit {
        reader.cancelReading()
    }

    func nextSample() async throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let sample = self.output.copyNextSampleBuffer() {
                    continuation.resume(returning: sample)
                } else if self.reader.status == .failed {
                    let reason = self.reader.error.map { "\($0)" } ?? "asset read failed"
                    continuation.resume(throwing: EngineError.decodeFailed(reason))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func nextPackets() async throws -> [MediaPacket]? {
        guard let sample = try await nextSample() else { return nil }
        guard CMSampleBufferGetNumSamples(sample) > 0 else { return [] }
        return try SampleBuffers.packets(from: sample, track: number)
    }

    func nextFrame() async throws -> DecodedFrame? {
        while let sample = try await nextSample() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            return DecodedFrame(image: image, timestamp: SampleBuffers.nanoseconds(sample.presentationTimeStamp))
        }
        return nil
    }
}
