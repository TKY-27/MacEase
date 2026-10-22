import CoreGraphics
import Formats
import Foundation

/// Operations that rewrite the clip in place.
enum VideoEdits {
    private static let defaultQuality = 0.75

    static func run(_ operation: VideoOperation, url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        try input.requireSingleTracksForReplacement()
        guard let source = input.video else { throw EngineError.invalidInput(.malformed("no video track")) }
        var plan: TranscodePlan
        do {
            plan = try self.plan(
                operation, input: input, source: source, settings: context.settings.video,
                audioSettings: context.settings.audio)
        } catch let skip as SkipError {
            return .skipped(skip.reason)
        }
        plan = try await VideoProperties.prepare(plan, input: input, context: context)
        let name = url.deletingPathExtension().lastPathComponent + "." + plan.container.fileExtension
        let output = try context.stagingURL(for: url, name: name)
        try await Transcoder.run(input, plan: plan, to: output) { context.progress($0) }
        try await VideoProperties.verify(plan, output: output, context: context)
        return .replace(original: url, output: StagedFile(url: output, name: name, check: .media))
    }

    static func plan(
        _ operation: VideoOperation, input: MediaInput, source: MediaTrack, settings: VideoSettings,
        audioSettings: AudioSettings = AudioSettings()
    ) throws -> TranscodePlan {
        _ = try input.displayOrientation
        let container = input.container
        switch operation {
        case .removeAudio:
            guard input.audio != nil else { throw SkipError(.nothingToRemove) }
            return TranscodePlan(container: container, video: .copy, audio: nil)
        case .convert(let target):
            guard target != container else { throw SkipError(.alreadyDone) }
            return try conversion(
                to: target, input: input, source: source, settings: settings, audioSettings: audioSettings)
        case .trim(let start, let end, let mode):
            let range = try Nanoseconds.from(seconds: start)..<(try Nanoseconds.from(seconds: end))
            guard !range.isEmpty, range.lowerBound < input.duration else {
                throw EngineError.invalidInput(.malformed("empty trim range"))
            }
            let video: TranscodePlan.Video =
                mode == .keyframe
                ? .copy : .encode(try alphaEncoding(input, source: source, settings: settings), try baked(input))
            var plan = TranscodePlan(container: container, video: video, audio: .copy)
            plan.range = range
            plan.startsAtKeyframe = mode == .keyframe
            return plan
        case .rotate(let degrees, let fill):
            guard degrees.isFinite else { throw EngineError.invalidInput(.invalidNumericParameter) }
            if degrees.truncatingRemainder(dividingBy: 90) == 0, container == .mp4 || container == .mov {
                var plan = TranscodePlan(container: container, video: .copy, audio: .copy)
                plan.transform = rotated(input.transform, by: degrees, source: source)
                return plan
            }
            var edit = try baked(input)
            edit.rotation += degrees
            edit.fill = fill
            return try reencoded(input, source: source, edit: edit, settings: settings)
        case .flip(let horizontally):
            var edit = try baked(input)
            edit.flipsHorizontally = horizontally
            edit.flipsVertically = !horizontally
            return try reencoded(input, source: source, edit: edit, settings: settings)
        case .frameRate(let framesPerSecond):
            guard framesPerSecond > 0, framesPerSecond <= Int(Nanoseconds.perSecond) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            var plan = try reencoded(input, source: source, edit: baked(input), settings: settings)
            if case .encode(var encoding, let edit) = plan.video {
                encoding.frameDuration = Nanoseconds.perSecond / Int64(framesPerSecond)
                plan.video = .encode(encoding, edit)
            }
            return plan
        case .resize(let resize):
            var edit = try baked(input)
            edit.size = try resized(input.displaySize, resize)
            return try reencoded(input, source: source, edit: edit, settings: settings)
        case .still, .gif, .apng, .webP, .gifX, .extractAudio, .compress, .subtitles, .background, .hdrToSDR:
            throw EngineError.unexpected("not an in-place edit")
        }
    }

    private static func baked(_ input: MediaInput) throws -> FrameEdit {
        FrameEdit(displayOrientation: try input.displayOrientation)
    }

    private static func reencoded(
        _ input: MediaInput, source: MediaTrack, edit: FrameEdit, settings: VideoSettings
    ) throws -> TranscodePlan {
        var encoding = try alphaEncoding(input, source: source, settings: settings)
        let size = try FrameProcessor.outputSize(source: input.codedSize, edit: edit, display: source.displayGeometry)
        encoding.width = size.width
        encoding.height = size.height
        return TranscodePlan(container: input.container, video: .encode(encoding, edit), audio: .copy)
    }

    static func encoding(_ input: MediaInput, source: MediaTrack, settings: VideoSettings) -> VideoEncoding {
        let codec = codec(for: input.container, source: source.codec, settings: settings)
        let size = input.displaySize.evened()
        var encoding = VideoEncoding(
            codec: codec, width: size.width, height: size.height, frameDuration: input.frameDuration, bitrate: nil)
        encoding.quality = defaultQuality
        return encoding
    }

    private static func alphaEncoding(
        _ input: MediaInput, source: MediaTrack, settings: VideoSettings, container: OutputContainer? = nil
    )
        throws -> VideoEncoding
    {
        var selected = encoding(input, source: source, settings: settings)
        guard source.hasAlpha else { return selected }
        if source.codec != .vp9 {
            guard case .asset = input.backend else { throw EngineError.videoAlphaUnsupported }
        }
        switch container ?? input.container {
        case .mov: selected.codec = source.codec == .prores ? .prores4444 : .hevc
        case .webm: selected.codec = .vp9
        case .mp4, .m4v, .mkv, .avi, .flv: return selected
        }
        selected.alpha = true
        return selected
    }

    static func codec(for container: OutputContainer, source: MediaCodec, settings: VideoSettings)
        -> VideoEncoding.Codec
    {
        switch container {
        case .webm: .vp9
        case .avi: .mjpeg
        case .flv: .h264
        case .mp4, .mov, .m4v, .mkv:
            switch source {
            case .h264: .h264
            case .hevc: .hevc
            default: settings.codec == .hevc ? .hevc : .h264
            }
        }
    }

    private static func conversion(
        to target: OutputContainer, input: MediaInput, source: MediaTrack, settings: VideoSettings,
        audioSettings: AudioSettings
    ) throws -> TranscodePlan {
        let audioFits =
            input.audio.map { track in
                target.holds(track.codec)
                    && (target != .avi || track.codec == .pcm(bits: 16, float: false, bigEndian: false))
            } ?? true
        let videoFits = target.holds(source.codec) && (input.transform == .identity || target.fileType != nil)
        let hasAssetFormat = if case .asset = input.backend { true } else { false }
        let alphaCopyFits =
            !source.hasAlpha
            || (target == .mov && hasAssetFormat && (source.codec == .hevc || source.codec == .prores))
            || ((target == .webm || target == .mkv) && source.codec == .vp9)
        if videoFits && audioFits && alphaCopyFits {
            return TranscodePlan(container: target, video: .copy, audio: input.audio == nil ? nil : .copy)
        }
        let audio: TranscodePlan.Audio? = input.audio.map { _ in
            switch target {
            case .webm: return .encode(.opus, kilobits: audioSettings.opusBitrate)
            case .avi: return .encode(.pcm(bits: 16, float: false, bigEndian: false), kilobits: 0)
            default: return .encode(.aac, kilobits: audioSettings.aacBitrate)
            }
        }
        var encoding = try alphaEncoding(input, source: source, settings: settings, container: target)
        if !encoding.alpha {
            encoding.codec = target == .mkv ? .h264 : codec(for: target, source: source.codec, settings: settings)
        }
        return TranscodePlan(container: target, video: .encode(encoding, try baked(input)), audio: audio)
    }

    private static func resized(_ display: PixelSize, _ resize: VideoResize) throws -> PixelSize {
        let shortSide = min(display.width, display.height)
        let scale: Double =
            switch resize {
            case .percent(let percent): Double(percent) / 100
            case .lines(let lines): Double(lines) / Double(shortSide)
            case .size(let width, let height):
                min(Double(width) / Double(display.width), Double(height) / Double(display.height))
            }
        guard scale.isFinite, scale > 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
        guard scale < 1 else { throw SkipError(.noUpscale) }
        guard let width = Int(exactly: (Double(display.width) * scale).rounded()),
            let height = Int(exactly: (Double(display.height) * scale).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        return PixelSize(width: width, height: height).evened()
    }

    /// Maps coded pixels to the display.
    private static func rotated(_ transform: CGAffineTransform, by degrees: Double, source: MediaTrack)
        -> CGAffineTransform
    {
        guard case .video(let width, let height) = source.kind else { return transform }
        let rotation = transform.concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(rotation)
        return rotation.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }
}

/// Ends an item as skipped.
struct SkipError: Error {
    let reason: SkipReason

    init(_ reason: SkipReason) {
        self.reason = reason
    }
}
