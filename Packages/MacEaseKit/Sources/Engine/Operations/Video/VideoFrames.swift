import CoreGraphics
import Formats
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoStills {
    static func run(_ still: VideoStill, url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        let time: Int64 =
            switch still {
            case .first: 0
            case .middle: input.duration / 2
            case .at(let seconds): min(max(try Nanoseconds.from(seconds: seconds), 0), input.duration)
            }
        let sampler = try await FrameSampler(
            input: input, frameDuration: input.frameDuration, edit: FrameEdit(rotation: input.displayRotation),
            start: time, end: time + 2 * input.frameDuration)
        guard let frame = try sampler.next() else { throw EngineError.decodeFailed("no frame at that time") }
        let format = context.settings.video.thumbnailFormat
        let type: UTType = format == .png ? .png : .jpeg
        let name = url.deletingPathExtension().lastPathComponent + "." + format.rawValue
        let output = try context.stagingURL(for: url, name: name)
        try ImageFiles.write([try CGImage.make(from: frame.image)], type: type, to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }
}

enum VideoAnimations {
    static func gif(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws -> ItemResult {
        let frames = try await sample(rendering, url: url, context: context)
        let duration = 1 / Double(rendering.framesPerSecond)
        let options = GIFOptions(colors: rendering.colors, dithering: rendering.dithering, loops: rendering.loops)
        let data = try GIFEncoder.encode(
            try frames.map { GIFFrame(pixels: try PixelBuffer(cgImage: $0), duration: duration) }, options: options)
        let name = url.deletingPathExtension().lastPathComponent + ".gif"
        let output = try context.stagingURL(for: url, name: name)
        try data.write(to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    static func apng(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws -> ItemResult {
        let frames = try await sample(rendering, url: url, context: context)
        let name = url.deletingPathExtension().lastPathComponent + ".png"
        let output = try context.stagingURL(for: url, name: name)
        try ImageFiles.write(
            frames, type: .png, to: output,
            animation: ImageFiles.Animation(delay: 1 / Double(rendering.framesPerSecond), loops: rendering.loops))
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    private static func sample(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws
        -> [CGImage]
    {
        let input = try await MediaInput.open(url)
        let display = input.displaySize
        let width = min(rendering.width, display.width)
        let height = Int((Double(display.height) * Double(width) / Double(display.width)).rounded())
        let start = try rendering.start.map { try Nanoseconds.from(seconds: $0) } ?? 0
        let end = try rendering.end.map { try Nanoseconds.from(seconds: $0) } ?? input.duration
        let edit = FrameEdit(rotation: input.displayRotation, size: PixelSize(width: width, height: height))
        let sampler = try await FrameSampler(
            input: input, frameDuration: Nanoseconds.perSecond / Int64(rendering.framesPerSecond), edit: edit,
            start: start, end: end)
        var frames: [CGImage] = []
        while let frame = try sampler.next() {
            frames.append(try CGImage.make(from: frame.image))
            context.progress(Double(frame.timestamp - start) / Double(max(end - start, 1)))
        }
        guard !frames.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        return frames
    }
}

/// ImageIO writing shared by stills and APNG.
enum ImageFiles {
    struct Animation {
        let delay: Double
        let loops: Bool
    }

    static func write(_ images: [CGImage], type: UTType, to url: URL, animation: Animation? = nil) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, images.count, nil)
        else { throw EngineError.encodeFailed("cannot create \(type.identifier)") }
        if let animation {
            let loop = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: animation.loops ? 0 : 1]]
            CGImageDestinationSetProperties(destination, loop as CFDictionary)
        }
        let frame: [CFString: Any] =
            animation.map { [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: $0.delay]] } ?? [:]
        for image in images { CGImageDestinationAddImage(destination, image, frame as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed("image write failed") }
    }
}
