import AVFoundation
import CoreMedia
import CoreVideo
import Formats
import Foundation

enum VideoSDR {
    private static let quality = 0.9
    private static let supportedCodecs: Set<MediaCodec> = [.hevc, .h264, .prores]
    private static let hdrTransfers: Set<String> = [
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
    ]
    private static var hdrMetadataKeys: [CFString] {
        [
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
            kCMFormatDescriptionExtension_ContentLightLevelInfo,
            kCMFormatDescriptionExtension_AlternativeTransferCharacteristics,
        ]
    }

    static func classification(_ url: URL) async throws -> HDRClassification {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        for track in tracks {
            for format in try await track.load(.formatDescriptions) {
                if try classification(format) != .sdr { return .unknownHDR }
            }
            if try await track.load(.mediaCharacteristics).contains(.containsHDRVideo) { return .unknownHDR }
        }
        return .sdr
    }

    static func classification(_ format: CMFormatDescription) throws -> HDRClassification {
        let transfer =
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            as? String
        let hasMetadata = hdrMetadataKeys.contains { CMFormatDescriptionGetExtension(format, extensionKey: $0) != nil }
        let hasDolbyVision = try DolbyVisionConfiguration.isProfile84(format)
        return transfer.map(hdrTransfers.contains) == true || hasMetadata || hasDolbyVision ? .unknownHDR : .sdr
    }

    static func run(url: URL, context: ItemContext) async throws -> ItemResult {
        try Task.checkCancellation()
        guard try await classification(url) != .sdr else { return .skipped(.alreadySDR) }
        let input = try await MediaInput.open(url)
        try input.requireSingleTracksForReplacement()
        guard case .asset(_, let track?, _) = input.backend, let source = input.video,
            supportedCodecs.contains(source.codec), input.container.fileType != nil
        else { throw EngineError.hdrConversionUnsupported }
        guard !source.hasAlpha else { throw EngineError.videoAlphaUnsupported }
        let formats = try await track.load(.formatDescriptions)
        guard !formats.isEmpty else { throw EngineError.hdrConversionUnsupported }
        var dolbyVision = false
        for format in formats {
            try validateSourceFormat(format)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard Int(dimensions.width) == input.codedSize.width, Int(dimensions.height) == input.codedSize.height
            else { throw EngineError.hdrConversionUnsupported }
            if try DolbyVisionConfiguration.isProfile84(format) { dolbyVision = true }
        }
        let size = input.codedSize
        guard size == size.evened() else { throw EngineError.hdrConversionUnsupported }
        var budget = FrameMemoryBudget()
        try budget.reserve(
            width: size.width, height: size.height, bytesPerPixel: 8,
            frameCount: Int64(SDRFrameEncodeStage.maximumPendingFrames + 2))
        var encoding = VideoEncoding(
            codec: source.codec == .h264 ? .h264 : .hevc, width: size.width, height: size.height,
            frameDuration: input.frameDuration, bitrate: nil)
        encoding.quality = quality
        encoding.allowsFrameReordering = false
        let plan = TranscodePlan(container: input.container, video: .toneMapToSDR(encoding), audio: .copy)
        let name = url.lastPathComponent
        let output = try context.stagingURL(for: url, name: name)
        try await Transcoder.run(input, plan: plan, to: output) { context.progress($0) }
        context.warn(.hdrProvenanceUnknown)
        if dolbyVision { context.warn(.dolbyVisionRemoved) }
        return .replace(original: url, output: StagedFile(url: output, name: name, check: .sdrVideo))
    }

    static func validateSourceFormat(_ format: CMFormatDescription) throws {
        guard
            let transfer = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
            hdrTransfers.contains(transfer),
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) != nil,
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) != nil
        else { throw EngineError.hdrConversionUnsupported }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let coded = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
            format, usePixelAspectRatio: true, useCleanAperture: false)
        let clean = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
        guard presentation == coded, clean == CGRect(origin: .zero, size: coded) else {
            throw EngineError.hdrConversionUnsupported
        }
        if let aperture = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_CleanAperture)
        {
            guard let aperture = aperture as? [CFString: Any] else {
                throw EngineError.hdrConversionUnsupported
            }
            for key in [
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset,
                kCMFormatDescriptionKey_CleanApertureVerticalOffset,
            ] {
                if let value = aperture[key] {
                    guard let offset = value as? NSNumber, offset.doubleValue == 0 else {
                        throw EngineError.hdrConversionUnsupported
                    }
                }
            }
            for key in [
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational,
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational,
            ] {
                if let value = aperture[key] {
                    guard let ratio = value as? [NSNumber], ratio.count == 2,
                        ratio[0].doubleValue == 0, ratio[1].doubleValue != 0
                    else { throw EngineError.hdrConversionUnsupported }
                }
            }
        }
    }

    static func verify(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw EngineError.sdrVerificationFailed }
        let formats = try await track.load(.formatDescriptions)
        guard !formats.isEmpty else { throw EngineError.sdrVerificationFailed }
        let expected: [(CFString, CFString)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for format in formats {
            guard try classification(format) == .sdr,
                expected.allSatisfy({
                    CMFormatDescriptionGetExtension(format, extensionKey: $0.0) as? String == $0.1 as String
                })
            else { throw EngineError.sdrVerificationFailed }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            var budget = FrameMemoryBudget()
            try budget.reserve(width: Int(size.width), height: Int(size.height))
        }
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .frames)
        guard let frame = try await reader.nextFrame() else { throw EngineError.sdrVerificationFailed }
        var actualBudget = FrameMemoryBudget()
        try actualBudget.reserve(frame.image)
    }
}

final class SDRFrameEncodeStage: StreamStage {
    static let maximumPendingFrames = 8
    private let reader: AssetTrackReader
    private let timing: AssetTrackReader
    private let timingOffset: CMTime
    private var sourceDurations: [Int64: Int64] = [:]
    private var encoder: any VideoFrameEncoder
    private var durations: [Int64: Int64] = [:]
    private let size: PixelSize
    private var lastTimestamp: Int64?
    private(set) var nextTime: Int64? = 0

    init(input: MediaInput, encoding: VideoEncoding) async throws {
        guard case .asset(let asset, let track?, _) = input.backend else {
            throw EngineError.hdrConversionUnsupported
        }
        timingOffset = try await Self.editOffset(of: track)
        reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .sdrFrames)
        timing = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .packets)
        encoder = try VideoEncoders.make(encoding, track: 1)
        size = PixelSize(width: encoding.width, height: encoding.height)
    }

    var output: OutputTrack? {
        guard let format = encoder.formatDescription else { return nil }
        return OutputTrack(track: encoder.track, format: format)
    }

    func pull() async throws -> [MediaPacket] {
        try Task.checkCancellation()
        guard nextTime != nil else { return [] }
        if durations.count == Self.maximumPendingFrames { return try drained() }
        guard let sample = try await reader.nextSample() else {
            nextTime = nil
            return try drained()
        }
        guard let image = CMSampleBufferGetImageBuffer(sample), sample.presentationTimeStamp.isNumeric,
            CVPixelBufferGetWidth(image) == size.width, CVPixelBufferGetHeight(image) == size.height
        else { throw EngineError.hdrConversionUnsupported }
        let timestamp = SampleBuffers.nanoseconds(sample.presentationTimeStamp)
        let duration = try await sourceDuration(at: timestamp)
        guard duration > 0, lastTimestamp.map({ timestamp > $0 }) ?? true,
            durations.updateValue(duration, forKey: timestamp) == nil
        else {
            throw EngineError.hdrConversionUnsupported
        }
        lastTimestamp = timestamp
        nextTime = timestamp
        return try timed(encoder.encode(image, timestamp: timestamp))
    }

    /// Packets use media time; frames use edits.
    private static func editOffset(of track: AVAssetTrack) async throws -> CMTime {
        let mappings = try await track.load(.segments).map(\.timeMapping)
        guard let first = mappings.first else { throw EngineError.hdrConversionUnsupported }
        let offset = CMTimeSubtract(first.target.start, first.source.start)
        for mapping in mappings {
            guard mapping.source.start.isNumeric, mapping.target.start.isNumeric,
                CMTimeCompare(mapping.source.duration, mapping.target.duration) == 0,
                CMTimeCompare(CMTimeSubtract(mapping.target.start, mapping.source.start), offset) == 0
            else { throw EngineError.hdrConversionUnsupported }
        }
        return offset
    }

    // Decoded frames lack durations; packets carry them.
    private func sourceDuration(at timestamp: Int64) async throws -> Int64 {
        while sourceDurations[timestamp] == nil {
            guard let sample = try await timing.nextSample() else { throw EngineError.hdrConversionUnsupported }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            for info in try sample.sampleTimingInfos() {
                let edited = CMTimeAdd(info.presentationTimeStamp, timingOffset)
                guard edited.isNumeric, info.duration.isNumeric else { throw EngineError.hdrConversionUnsupported }
                let presentation = SampleBuffers.nanoseconds(edited)
                if presentation >= timestamp {
                    sourceDurations[presentation] = SampleBuffers.nanoseconds(info.duration)
                }
            }
        }
        let duration = sourceDurations[timestamp]
        sourceDurations = sourceDurations.filter { $0.key > timestamp }
        guard let duration else { throw EngineError.hdrConversionUnsupported }
        return duration
    }

    private func drained() throws -> [MediaPacket] {
        let packets = try timed(encoder.finish())
        guard durations.isEmpty else { throw EngineError.encodeFailed("SDR encoder dropped frames") }
        return packets
    }

    private func timed(_ packets: [MediaPacket]) throws -> [MediaPacket] {
        try packets.map { packet in
            guard let duration = durations.removeValue(forKey: packet.timestamp) else {
                throw EngineError.encodeFailed("SDR encoder returned an unknown frame")
            }
            var timedPacket = packet
            timedPacket.duration = duration
            return timedPacket
        }
    }
}
