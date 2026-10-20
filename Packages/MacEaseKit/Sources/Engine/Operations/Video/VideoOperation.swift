import Formats
import Foundation
import MenuCatalog

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
    case still(VideoStill)
    case gif(AnimationRendering)
    case apng(AnimationRendering)
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
        case .videoThumbnail:
            return ["first": VideoStill.first, "middle": .middle][preset].map(VideoOperation.still)
        case .videoToGIF:
            return animation(preset, settings: settings).map(VideoOperation.gif)
        case .videoToAPNG:
            return animation(preset, settings: settings).map(VideoOperation.apng)
        default:
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
        let lane: Lane = operation.reencodes ? .hardwareVideo : .cpu
        let items = inputs.map { url in
            OperationPlanner.validated(url, kind: .video, lane: lane) { context in
                switch operation {
                case .still(let still): try await VideoStills.run(still, url: url, context: context)
                case .gif(let rendering): try await VideoAnimations.gif(rendering, url: url, context: context)
                case .apng(let rendering): try await VideoAnimations.apng(rendering, url: url, context: context)
                default: try await VideoEdits.run(operation, url: url, context: context)
                }
            }
        }
        return Batch(operation: op, items: items)
    }
}

extension VideoOperation {
    var reencodes: Bool {
        switch self {
        case .removeAudio, .convert, .still, .gif, .apng: false
        case .trim(_, _, let mode): mode == .exact
        case .resize, .rotate, .flip, .frameRate: true
        }
    }
}
