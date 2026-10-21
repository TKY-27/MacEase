import Formats
import Foundation
import MenuCatalog
import os

public struct VideoCompression: Codable, Hashable, Sendable {
    public enum Goal: Codable, Hashable, Sendable {
        case bytes(Int64)
        case quality(Double)
        case platform(PlatformPreset)
    }

    public var goal: Goal
    public var allowsDownscale: Bool
    public var allowsFrameRateReduction: Bool

    public init(goal: Goal, allowsDownscale: Bool = true, allowsFrameRateReduction: Bool = true) {
        self.goal = goal
        self.allowsDownscale = allowsDownscale
        self.allowsFrameRateReduction = allowsFrameRateReduction
    }
}

public enum VideoResize: Codable, Hashable, Sendable {
    case percent(Int)
    /// Short side, so portrait clips work too.
    case lines(Int)
    case size(width: Int, height: Int)
}

public enum VideoStill: Codable, Hashable, Sendable {
    case first
    case middle
    case at(seconds: Double)
}

public struct AnimationRendering: Codable, Hashable, Sendable {
    public var width: Int
    public var framesPerSecond: Int
    public var colors = 256
    public var dithering = Dithering.ordered
    public var loops = true
    public var start: Double?
    public var end: Double?

    public init(width: Int, framesPerSecond: Int) {
        self.width = width
        self.framesPerSecond = framesPerSecond
    }
}

public enum VideoOperation: Codable, Hashable, Sendable {
    case hdrToSDR
    case resize(VideoResize)
    case trim(start: Double, end: Double, mode: TrimMode)
    /// Clockwise degrees.
    case rotate(degrees: Double, fill: RGBColor)
    case flip(horizontally: Bool)
    case frameRate(Int)
    case removeAudio
    case convert(OutputContainer)
    case compress(VideoCompression)
    /// `nil` kilobits copies when possible.
    case extractAudio(AudioFormat, kilobits: Int? = nil)
    case still(VideoStill)
    case gif(AnimationRendering)
    case apng(AnimationRendering)
    case webP(AnimationRendering)
    case gifX
    case subtitles(SubtitleRequest)
    case background(VideoBackgroundRequest)
}

enum VideoPlanner {
    private static let degreesPerTurn = 360.0
    private static let legacyAnimationPresets: [String: (width: Int, framesPerSecond: Int)] = [
        "480-10": (480, 10), "480-15": (480, 15), "720-15": (720, 15), "720-24": (720, 24),
    ]

    static func options(for op: OperationID, preset: String?, settings: Settings) -> VideoOperation? {
        if op == .videoHDRToSDR { return preset == nil ? .hdrToSDR : nil }
        if op == .videoRemoveAudio { return .removeAudio }
        guard let preset else { return nil }
        switch op {
        case .videoResize:
            let slotID = "video.resize/\(preset)"
            guard let slot = MenuValues.slots.first(where: { $0.id == slotID }),
                let value = settings.menuValues.value(for: slotID)
            else { return nil }
            switch slot.unit {
            case .percent: return .resize(.percent(value))
            case .pixels: return .resize(.lines(value))
            case .megabytes: return nil
            }
        case .videoRotate:
            let degrees: [String: Double] = ["right-90": 90, "left-90": 270, "180": 180]
            guard let angle = preset == "extra-angle" ? settings.extraRotationDegrees : degrees[preset], angle.isFinite,
                preset != "extra-angle" || Settings.extraRotationRange.contains(angle)
            else { return nil }
            let normalized = (angle.truncatingRemainder(dividingBy: degreesPerTurn) + degreesPerTurn)
                .truncatingRemainder(dividingBy: degreesPerTurn)
            return .rotate(degrees: normalized, fill: settings.video.rotationFill)
        case .videoFlip:
            return preset == "horizontal" || preset == "vertical" ? .flip(horizontally: preset == "horizontal") : nil
        case .videoFPS:
            let frameRate: Int
            switch preset {
            case "24": frameRate = settings.video.frameRateFilm
            case "30": frameRate = settings.video.frameRateStandard
            case "60": frameRate = settings.video.frameRateSmooth
            default: return nil
            }
            guard VideoSettings.frameRateRange.contains(frameRate) else { return nil }
            return .frameRate(frameRate)
        case .videoConvert:
            return OutputContainer(rawValue: preset).map(VideoOperation.convert)
        case .videoCompress:
            return compression(preset, settings: settings).map(VideoOperation.compress)
        case .videoExtractAudio:
            if preset == "m4a" { return .extractAudio(.m4aAAC, kilobits: settings.audio.extractedAudioBitrate) }
            return AudioFormat(rawValue: preset).map {
                .extractAudio($0, kilobits: settings.audio.extractedAudioBitrate)
            }
        case .videoThumbnail:
            return ["first": VideoStill.first, "middle": .middle][preset].map(VideoOperation.still)
        case .videoToGIF:
            if preset == "x" { return .gifX }
            return animation(preset, settings: settings).map(VideoOperation.gif)
        case .videoToAnimatedWebP:
            return animation(preset, settings: settings).map(VideoOperation.webP)
        case .videoToAPNG:
            return animation(preset, settings: settings).map(VideoOperation.apng)
        case .videoSubtitles:
            return SubtitleRequest.preset(preset, settings: settings.intelligence).map(VideoOperation.subtitles)
        case .videoBackground:
            return background(preset, settings: settings).map(VideoOperation.background)
        default:
            return nil
        }
    }

    private static func background(_ preset: String, settings: Settings) -> VideoBackgroundRequest? {
        let fills: [String: BackgroundFill] = [
            "remove": .transparent, "green": .color(settings.image.greenBackground),
            "blue": .color(settings.image.blueBackground), "color": .color(settings.image.customBackground),
            "blur": .blur(radius: Double(settings.image.backgroundBlurRadius)),
        ]
        return fills[preset].map {
            VideoBackgroundRequest(
                mask: settings.video.backgroundMask.source, fill: $0,
                transparentFormat: settings.video.transparentFormat)
        }
    }

    static func compression(for preset: PlatformPreset, settings: Settings) -> VideoCompression {
        VideoCompression(
            goal: .platform(preset), allowsDownscale: settings.video.allowDownscale,
            allowsFrameRateReduction: settings.video.allowFrameRateReduction)
    }

    private static func compression(_ preset: String, settings: Settings) -> VideoCompression? {
        let qualities: [String: Double] = ["quality-high": 0.85, "quality-medium": 0.65, "quality-low": 0.4]
        if let quality = qualities[preset] { return VideoCompression(goal: .quality(quality)) }
        let slotID = "video.compress/\(preset)"
        if let slot = MenuValues.slots.first(where: { $0.id == slotID }), slot.unit == .megabytes {
            guard let size = settings.menuValues.value(for: slotID) else { return nil }
            let target = Int64(
                (Double(Int64(size) * MenuValues.bytesPerMegabyte) * MediaLimits.targetShare).rounded(.down))
            return VideoCompression(
                goal: .bytes(target), allowsDownscale: settings.video.allowDownscale,
                allowsFrameRateReduction: settings.video.allowFrameRateReduction)
        }
        return settings.platformPresets.first { $0.id == preset && $0.video != nil }.map {
            compression(for: $0, settings: settings)
        }
    }

    private static func animation(_ preset: String, settings: Settings) -> AnimationRendering? {
        let start = settings.video.gifStartSeconds
        let end = settings.video.gifEndSeconds
        guard start.isFinite, end.isFinite, VideoSettings.animationTimeRange.contains(start),
            VideoSettings.animationTimeRange.contains(end), end == 0 || end > start
        else { return nil }
        let size: (width: Int, framesPerSecond: Int)
        if preset == "settings" {
            size = (settings.video.gifWidth, settings.video.gifFrameRate)
        } else if let legacy = legacyAnimationPresets[preset] {
            size = legacy
        } else {
            return nil
        }
        var rendering = AnimationRendering(width: size.width, framesPerSecond: size.framesPerSecond)
        rendering.colors = settings.video.gifColors
        rendering.dithering = settings.image.gifDithering
        rendering.loops = settings.video.gifLoops
        rendering.start = start > 0 ? start : nil
        rendering.end = end > 0 ? end : nil
        return rendering
    }

    static func batch(_ operation: VideoOperation, op: OperationID, inputs: [URL]) -> Batch {
        let lane: Lane = operation.usesHardwareVideo ? .hardwareVideo : .cpu
        let items = inputs.map { url in
            OperationPlanner.validated(url, kind: .video, lane: lane) { context in
                switch operation {
                case .hdrToSDR: try await VideoSDR.run(url: url, context: context)
                case .compress(let compression): try await VideoCompressor.run(compression, url: url, context: context)
                case .extractAudio(let format, let kilobits):
                    try await VideoAudio.extract(format, kilobits: kilobits, url: url, context: context)
                case .still(let still): try await VideoStills.run(still, url: url, context: context)
                case .gif(let rendering): try await VideoAnimations.gif(rendering, url: url, context: context)
                case .apng(let rendering): try await VideoAnimations.apng(rendering, url: url, context: context)
                case .webP(let rendering): try await VideoAnimations.webP(rendering, url: url, context: context)
                case .gifX: try await VideoAnimations.gifX(url: url, context: context)
                case .subtitles(let request): try await VideoSubtitles.run(request, url: url, context: context)
                case .background(let request):
                    try await VideoBackgroundRemoval.run(request, url: url, context: context)
                default: try await VideoEdits.run(operation, url: url, context: context)
                }
            }
        }
        return Batch(operation: op, items: items)
    }
}

extension VideoOperation {
    var usesHardwareVideo: Bool {
        switch self {
        case .removeAudio, .still, .gif, .apng, .webP, .gifX, .extractAudio, .subtitles: false
        case .trim(_, _, let mode): mode == .exact
        case .convert(let container): container != .webm && container != .avi
        case .resize, .rotate, .flip, .frameRate, .compress, .background, .hdrToSDR: true
        }
    }
}
