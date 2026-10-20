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
    case resize(VideoResize)
    case trim(start: Double, end: Double, mode: TrimMode)
    /// Clockwise degrees.
    case rotate(degrees: Double, fill: RGBColor)
    case flip(horizontally: Bool)
    case frameRate(Int)
    case removeAudio
    case convert(OutputContainer)
    case compress(VideoCompression)
    case extractAudio(AudioFormat)
    case still(VideoStill)
    case gif(AnimationRendering)
    case apng(AnimationRendering)
    case webP(AnimationRendering)
    case gifX
}

enum VideoPlanner {
    private static let animationPresets: [String: (width: Int, framesPerSecond: Int)] = [
        "480-10": (480, 10), "480-15": (480, 15), "720-15": (720, 15), "720-24": (720, 24),
    ]

    static func options(for op: OperationID, preset: String?, settings: Settings) -> VideoOperation? {
        if op == .videoRemoveAudio { return .removeAudio }
        guard let preset else { return nil }
        switch op {
        case .videoResize:
            if preset == "percent-50" { return .resize(.percent(50)) }
            return Int(preset.dropLast()).map { .resize(.lines($0)) }
        case .videoRotate:
            let degrees: [String: Double] = ["right-90": 90, "left-90": 270, "180": 180]
            return degrees[preset].map { .rotate(degrees: $0, fill: settings.video.rotationFill) }
        case .videoFlip:
            return preset == "horizontal" || preset == "vertical" ? .flip(horizontally: preset == "horizontal") : nil
        case .videoFPS:
            return Int(preset).map(VideoOperation.frameRate)
        case .videoConvert:
            return OutputContainer(rawValue: preset).map(VideoOperation.convert)
        case .videoCompress:
            return compression(preset, settings: settings).map(VideoOperation.compress)
        case .videoExtractAudio:
            if preset == "m4a" { return .extractAudio(.m4aAAC) }
            return AudioFormat(rawValue: preset).map(VideoOperation.extractAudio)
        case .videoThumbnail:
            return ["first": VideoStill.first, "middle": .middle][preset].map(VideoOperation.still)
        case .videoToGIF:
            if preset == "x" { return .gifX }
            return animation(preset, settings: settings).map(VideoOperation.gif)
        case .videoToAnimatedWebP:
            return animation(preset, settings: settings).map(VideoOperation.webP)
        case .videoToAPNG:
            return animation(preset, settings: settings).map(VideoOperation.apng)
        default:
            return nil
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
        let megabytes: [String: Int64] = ["mb-10": 10, "mb-25": 25, "mb-50": 50, "mb-100": 100]
        if let size = megabytes[preset] {
            let target = Int64((Double(size * 1_000_000) * MediaLimits.targetShare).rounded(.down))
            return VideoCompression(
                goal: .bytes(target), allowsDownscale: settings.video.allowDownscale,
                allowsFrameRateReduction: settings.video.allowFrameRateReduction)
        }
        do {
            let bundled = try PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory).bundled
            return bundled.first { $0.id == preset && $0.video != nil }.map { compression(for: $0, settings: settings) }
        } catch {
            Logger(category: "video").error(
                "Bundled presets unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func animation(_ preset: String, settings: Settings) -> AnimationRendering? {
        guard let sizes = animationPresets[preset] else { return nil }
        var rendering = AnimationRendering(width: sizes.width, framesPerSecond: sizes.framesPerSecond)
        rendering.colors = settings.video.gifColors
        rendering.dithering = settings.image.gifDithering
        rendering.loops = settings.video.gifLoops
        return rendering
    }

    static func batch(_ operation: VideoOperation, op: OperationID, inputs: [URL]) -> Batch {
        let lane: Lane = operation.usesHardwareVideo ? .hardwareVideo : .cpu
        let items = inputs.map { url in
            OperationPlanner.validated(url, kind: .video, lane: lane) { context in
                switch operation {
                case .compress(let compression): try await VideoCompressor.run(compression, url: url, context: context)
                case .extractAudio(let format): try await VideoAudio.extract(format, url: url, context: context)
                case .still(let still): try await VideoStills.run(still, url: url, context: context)
                case .gif(let rendering): try await VideoAnimations.gif(rendering, url: url, context: context)
                case .apng(let rendering): try await VideoAnimations.apng(rendering, url: url, context: context)
                case .webP(let rendering): try await VideoAnimations.webP(rendering, url: url, context: context)
                case .gifX: try await VideoAnimations.gifX(url: url, context: context)
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
        case .removeAudio, .still, .gif, .apng, .webP, .gifX, .extractAudio: false
        case .trim(_, _, let mode): mode == .exact
        case .convert(let container): container != .webm && container != .avi
        case .resize, .rotate, .flip, .frameRate, .compress: true
        }
    }
}
