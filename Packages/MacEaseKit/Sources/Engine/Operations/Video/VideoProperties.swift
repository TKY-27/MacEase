import AVFoundation
import Formats
import Foundation

enum VideoProperties {
    struct HDRSource {
        let configuration: VideoHDRConfiguration
        let dolbyVision: Bool
    }

    static func prepare(
        _ plan: TranscodePlan, input: MediaInput, context: ItemContext, allowsCodecChange: Bool = true
    ) async throws -> TranscodePlan {
        guard input.video?.hasContainerHDR != true else { throw EngineError.hdrConversionUnsupported }
        var prepared = plan
        let keepsOriginal = plan.derived || context.settings.outputMode == .newFile
        let hdr = plan.video == nil ? nil : try await hdrConfiguration(input)
        if hdr?.dolbyVision == true {
            guard keepsOriginal else { throw EngineError.videoDolbyVisionUnsupported }
            warn(.dolbyVisionRemoved, context: context)
            if case .copy = prepared.video {
                prepared = try await reencoded(prepared, input: input, settings: context.settings.video)
            }
        }
        if case .encode(var encoding, var edit) = prepared.video {
            if input.video?.hasAlpha == true {
                if input.video?.codec != .vp9 {
                    guard case .asset = input.backend else { throw EngineError.videoAlphaUnsupported }
                }
                if prepared.container == .mov, encoding.codec == .hevc || encoding.codec == .prores4444 {
                    encoding.alpha = true
                } else if prepared.container == .webm, encoding.codec == .vp9 {
                    encoding.alpha = true
                } else {
                    guard keepsOriginal else { throw EngineError.videoAlphaUnsupported }
                    edit.flattensAlpha = true
                    edit.fill = context.settings.video.rotationFill
                    warn(.videoTransparencyFlattened, context: context)
                }
            }
            if let hdr {
                if allowsCodecChange, prepared.container.holds(.hevc), !encoding.alpha {
                    encoding.codec = .hevc
                }
                if encoding.codec == .hevc, !encoding.alpha, !edit.flattensAlpha, prepared.matte == nil {
                    encoding.hdr = hdr.configuration
                } else {
                    guard keepsOriginal else { throw EngineError.videoHDRUnsupported }
                    try await validateToneMapping(input)
                    prepared.toneMapToSDR = true
                    warn(.videoToneMappedToSDR, context: context)
                }
            }
            prepared.video = .encode(encoding, edit)
        }
        let metadata = try await VideoMetadata.load(from: input)
        let losses = metadata.losses(for: prepared.container, includingAudio: prepared.audio != nil)
        if !losses.isEmpty {
            guard keepsOriginal else {
                throw EngineError.videoMetadataUnsupported(losses)
            }
            warn(.videoMetadataDropped(losses), context: context)
        }
        prepared.metadata = metadata
        return prepared
    }

    static func verify(_ plan: TranscodePlan, output: URL, context: ItemContext) async throws {
        if case .encode(let encoding, _) = plan.video, let expected = encoding.hdr {
            let written = try await MediaInput.open(output)
            let hdr = try await hdrConfiguration(written)
            guard hdr?.configuration == expected, hdr?.dolbyVision == false else {
                throw EngineError.encodeFailed("HDR output format differs from source")
            }
        }
        guard let metadata = plan.metadata else { return }
        let losses = try await metadata.losses(
            in: output, container: plan.container, includingAudio: plan.audio != nil)
        guard !losses.isEmpty else { return }
        guard plan.derived || context.settings.outputMode == .newFile else {
            throw EngineError.videoMetadataUnsupported(losses)
        }
        warn(.videoMetadataDropped(losses), context: context)
    }

    static func hdrConfiguration(_ input: MediaInput) async throws -> HDRSource? {
        guard input.video?.hasContainerHDR != true else { throw EngineError.hdrConversionUnsupported }
        let formats: [CMFormatDescription]
        if case .asset(_, let track?, _) = input.backend {
            formats = try await track.load(.formatDescriptions)
        } else if let track = input.video, [.h264, .hevc, .prores, .av1].contains(track.codec) {
            formats = [try VideoFormat.description(for: track)]
        } else {
            return nil
        }
        let hdr = try hdrConfiguration(formats)
        if hdr == nil, case .asset(_, let track?, _) = input.backend,
            try await track.load(.mediaCharacteristics).contains(.containsHDRVideo)
        {
            throw EngineError.hdrConversionUnsupported
        }
        return hdr
    }

    static func hdrConfiguration(_ formats: [CMFormatDescription]) throws -> HDRSource? {
        var source: HDRSource?
        var foundSDR = false
        for format in formats {
            guard try VideoSDR.classification(format) != .sdr else {
                foundSDR = true
                continue
            }
            try VideoSDR.validateSourceFormat(format)
            let dolbyVision = try DolbyVisionConfiguration.isProfile84(format)
            guard let hdr = VideoHDRConfiguration(format: format),
                source.map({ $0.configuration == hdr && $0.dolbyVision == dolbyVision }) ?? true,
                !foundSDR
            else { throw EngineError.hdrConversionUnsupported }
            source = HDRSource(configuration: hdr, dolbyVision: dolbyVision)
        }
        guard source == nil || !foundSDR else { throw EngineError.hdrConversionUnsupported }
        return source
    }

    static func toneMapsExport(_ input: MediaInput, context: ItemContext) async throws -> Bool {
        guard let hdr = try await hdrConfiguration(input) else { return false }
        try await validateToneMapping(input)
        if hdr.dolbyVision { warn(.dolbyVisionRemoved, context: context) }
        warn(.videoToneMappedToSDR, context: context)
        return true
    }

    private static func validateToneMapping(_ input: MediaInput) async throws {
        guard case .asset(_, let track?, _) = input.backend, input.video?.hasAlpha != true else {
            throw EngineError.hdrConversionUnsupported
        }
        for format in try await track.load(.formatDescriptions) { try VideoSDR.validateSourceFormat(format) }
    }

    private static func reencoded(_ plan: TranscodePlan, input: MediaInput, settings: VideoSettings) async throws
        -> TranscodePlan
    {
        guard let source = input.video else { throw EngineError.hdrConversionUnsupported }
        var prepared = plan
        let edit = FrameEdit(displayOrientation: try VideoDisplayOrientation(plan.transform ?? input.transform))
        let size = try FrameProcessor.outputSize(source: input.codedSize, edit: edit)
        var encoding = VideoEdits.encoding(input, source: source, settings: settings)
        encoding.codec = VideoEdits.codec(for: plan.container, source: source.codec, settings: settings)
        encoding.width = size.width
        encoding.height = size.height
        if plan.startsAtKeyframe, let range = plan.range {
            prepared.range = try await Transcoder.keyframe(atOrBefore: range.lowerBound, in: input)..<range.upperBound
        }
        prepared.transform = nil
        prepared.video = .encode(encoding, edit)
        return prepared
    }

    private static func warn(_ warning: ItemWarning, context: ItemContext) {
        if !context.warnings.contains(warning) { context.warn(warning) }
    }
}
