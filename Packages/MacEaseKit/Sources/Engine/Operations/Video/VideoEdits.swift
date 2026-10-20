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
        let plan: TranscodePlan
        do {
            plan = try self.plan(
                operation, input: input, source: source, settings: context.settings.video,
                audioSettings: context.settings.audio)
        } catch let skip as SkipError {
            return .skipped(skip.reason)
        }
        let name = url.deletingPathExtension().lastPathComponent + "." + plan.container.fileExtension
        let output = try context.stagingURL(for: url, name: name)
        try await Transcoder.run(input, plan: plan, to: output) { context.progress($0) }
        return .replace(original: url, output: StagedFile(url: output, name: name, check: .media))
    }

    static func plan(
        _ operation: VideoOperation, input: MediaInput, source: MediaTrack, settings: VideoSettings,
        audioSettings: AudioSettings = AudioSettings()
    ) throws -> TranscodePlan {
        let container = input.container
        switch operation {
        case .removeAudio:
            guard input.audio != nil else { throw SkipError(.nothingToRemove) }
            return TranscodePlan(container: container, video: .copy, audio: nil)
        case .convert(let target):
            guard target != container else { throw SkipError(.alreadyDone) }
            return conversion(
                to: target, input: input, source: source, settings: settings, audioSettings: audioSettings)
        case .trim(let start, let end, let mode):
            let range = try Nanoseconds.from(seconds: start)..<(try Nanoseconds.from(seconds: end))
            guard !range.isEmpty, range.lowerBound < input.duration else {
                throw EngineError.invalidInput(.malformed("empty trim range"))
            }
            let video: TranscodePlan.Video =
                mode == .keyframe ? .copy : .encode(encoding(input, source: source, settings: settings), baked(input))
            var plan = TranscodePlan(container: container, video: video, audio: .copy)
            plan.range = range
            plan.startsAtKeyframe = mode == .keyframe
            return plan
        case .rotate(let degrees, let fill):
            if degrees.truncatingRemainder(dividingBy: 90) == 0, container == .mp4 || container == .mov {
                var plan = TranscodePlan(container: container, video: .copy, audio: .copy)
                plan.transform = rotated(input.transform, by: degrees, source: source)
                return plan
            }
            var edit = baked(input)
            edit.rotation += degrees
            edit.fill = fill
            return reencoded(input, source: source, edit: edit, settings: settings)
        case .flip(let horizontally):
            var edit = baked(input)
            edit.flipsHorizontally = horizontally
            edit.flipsVertically = !horizontally
            return reencoded(input, source: source, edit: edit, settings: settings)
        case .frameRate(let framesPerSecond):
            var plan = reencoded(input, source: source, edit: baked(input), settings: settings)
            if case .encode(var encoding, let edit) = plan.video {
                encoding.frameDuration = Nanoseconds.perSecond / Int64(framesPerSecond)
                plan.video = .encode(encoding, edit)
            }
            return plan
        case .resize(let resize):
            var edit = baked(input)
            edit.size = try resized(input.displaySize, resize)
            return reencoded(input, source: source, edit: edit, settings: settings)
        case .still, .gif, .apng, .webP, .gifX, .extractAudio, .compress, .subtitles, .background:
            throw EngineError.unexpected("not an in-place edit")
        }
    }

    /// Re-encodes bake the stored rotation into pixels.
    private static func baked(_ input: MediaInput) -> FrameEdit {
        FrameEdit(rotation: input.displayRotation)
    }

    private static func reencoded(
        _ input: MediaInput, source: MediaTrack, edit: FrameEdit, settings: VideoSettings
    ) -> TranscodePlan {
        var encoding = encoding(input, source: source, settings: settings)
        let size = FrameProcessor.outputSize(source: input.codedSize, edit: edit)
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
    ) -> TranscodePlan {
        let audioFits =
            input.audio.map { track in
                target.holds(track.codec)
                    && (target != .avi || track.codec == .pcm(bits: 16, float: false, bigEndian: false))
            } ?? true
        let videoFits = target.holds(source.codec) && (input.transform == .identity || target.fileType != nil)
        if videoFits && audioFits {
            return TranscodePlan(container: target, video: .copy, audio: input.audio == nil ? nil : .copy)
        }
        let audio: TranscodePlan.Audio? = input.audio.map { _ in
            switch target {
            case .webm: return .encode(.opus, kilobits: audioSettings.opusBitrate)
            case .avi: return .encode(.pcm(bits: 16, float: false, bigEndian: false), kilobits: 0)
            default: return .encode(.aac, kilobits: audioSettings.aacBitrate)
            }
        }
        var encoding = encoding(input, source: source, settings: settings)
        encoding.codec = target == .mkv ? .h264 : codec(for: target, source: source.codec, settings: settings)
        return TranscodePlan(container: target, video: .encode(encoding, baked(input)), audio: audio)
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
        guard scale < 1 else { throw SkipError(.noUpscale) }
        return PixelSize(
            width: Int((Double(display.width) * scale).rounded()),
            height: Int((Double(display.height) * scale).rounded())
        ).evened()
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
