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
        guard let frame = try await sampler.next() else { throw EngineError.decodeFailed("no frame at that time") }
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

    static func webP(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws -> ItemResult {
        let frames = try await sample(rendering, url: url, context: context)
        guard let firstImage = frames.first else { throw EngineError.invalidInput(.emptyInput) }
        let first = try PixelBuffer(cgImage: firstImage)
        let encoder = try WebPAnimationEncoder(
            width: first.width, height: first.height,
            quality: Double(context.settings.image.webpQuality), loops: rendering.loops)
        for frame in frames { try encoder.add(frame, duration: 1 / Double(rendering.framesPerSecond)) }
        let data = try encoder.finish()
        let name = url.deletingPathExtension().lastPathComponent + ".webp"
        let output = try context.stagingURL(for: url, name: name)
        try data.write(to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    static func gifX(url: URL, context: ItemContext) async throws -> ItemResult {
        guard let limits = context.settings.platformPresets.first(where: { $0.id == "x" })?.gif,
            let maxBytes = limits.targetBytes, let maxWidth = limits.maxWidth,
            let maxHeight = limits.maxHeight, let maxFrames = limits.maxFrames
        else { throw EngineError.invalidInput(.malformed("X GIF limits are missing")) }

        let input = try await MediaInput.open(url)
        let seconds = Double(input.duration) / Double(Nanoseconds.perSecond)
        guard seconds > 0 else { throw EngineError.invalidInput(.emptyInput) }
        var rendering = AnimationRendering(width: min(maxWidth, input.displaySize.width), framesPerSecond: 15)
        rendering.colors = min(max(context.settings.video.gifColors, 2), 256)
        rendering.dithering = context.settings.image.gifDithering
        rendering.loops = context.settings.video.gifLoops
        rendering.framesPerSecond = min(
            rendering.framesPerSecond, max(1, Int((Double(maxFrames) / seconds).rounded(.down))))
        let frameLimit = Int64(maxFrames)
        let minimumFrameDuration = input.duration / frameLimit + (input.duration % frameLimit == 0 ? 0 : 1)

        var data = try await encodeGIF(
            rendering, maxHeight: maxHeight, maxFrames: maxFrames, minimumFrameDuration: minimumFrameDuration, url: url,
            context: context)
        var smallestBytes = Int64(data.count)
        while Int64(data.count) > maxBytes, rendering.framesPerSecond > 1 {
            rendering.framesPerSecond -= 1
            data = try await encodeGIF(
                rendering, maxHeight: maxHeight, maxFrames: maxFrames, minimumFrameDuration: minimumFrameDuration,
                url: url, context: context)
            smallestBytes = min(smallestBytes, Int64(data.count))
        }
        while Int64(data.count) > maxBytes, rendering.width > 1 {
            rendering.width = max(1, Int((Double(rendering.width) * 0.9).rounded(.down)))
            data = try await encodeGIF(
                rendering, maxHeight: maxHeight, maxFrames: maxFrames, minimumFrameDuration: minimumFrameDuration,
                url: url, context: context)
            smallestBytes = min(smallestBytes, Int64(data.count))
        }
        while Int64(data.count) > maxBytes, rendering.colors > 2 {
            rendering.colors = max(2, rendering.colors / 2)
            data = try await encodeGIF(
                rendering, maxHeight: maxHeight, maxFrames: maxFrames, minimumFrameDuration: minimumFrameDuration,
                url: url, context: context)
            smallestBytes = min(smallestBytes, Int64(data.count))
        }
        guard Int64(data.count) <= maxBytes else {
            throw EngineError.targetUnreachable(smallestBytes: smallestBytes)
        }

        let name = url.deletingPathExtension().lastPathComponent + ".gif"
        let output = try context.stagingURL(for: url, name: name)
        try data.write(to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    private static func encodeGIF(
        _ rendering: AnimationRendering, maxHeight: Int, maxFrames: Int, minimumFrameDuration: Int64,
        url: URL, context: ItemContext
    ) async throws -> Data {
        let frames = try await sample(
            rendering, maxHeight: maxHeight, minimumFrameDuration: minimumFrameDuration, url: url, context: context)
        guard frames.count <= maxFrames else {
            throw EngineError.invalidInput(.malformed("X GIF exceeds its frame limit"))
        }
        let interval = max(Nanoseconds.perSecond / Int64(rendering.framesPerSecond), minimumFrameDuration)
        let duration = Double(interval) / Double(Nanoseconds.perSecond)
        let options = GIFOptions(colors: rendering.colors, dithering: rendering.dithering, loops: rendering.loops)
        return try GIFEncoder.encode(
            frames.map { GIFFrame(pixels: try PixelBuffer(cgImage: $0), duration: duration) }, options: options)
    }

    private static func sample(
        _ rendering: AnimationRendering, maxHeight: Int? = nil, minimumFrameDuration: Int64 = 0,
        url: URL, context: ItemContext
    ) async throws
        -> [CGImage]
    {
        guard rendering.width > 0, rendering.framesPerSecond > 0 else {
            throw EngineError.invalidInput(.malformed("animation width and frame rate must be positive"))
        }
        let input = try await MediaInput.open(url)
        let display = input.displaySize
        let scale = min(
            1,
            min(
                Double(rendering.width) / Double(display.width),
                Double(maxHeight ?? Int.max) / Double(display.height)))
        let width = max(1, Int((Double(display.width) * scale).rounded()))
        let height = max(1, Int((Double(display.height) * scale).rounded()))
        let start = try rendering.start.map { try Nanoseconds.from(seconds: $0) } ?? 0
        let end = try rendering.end.map { try Nanoseconds.from(seconds: $0) } ?? input.duration
        let frameDuration = max(Nanoseconds.perSecond / Int64(rendering.framesPerSecond), minimumFrameDuration)
        guard frameDuration > 0, start >= 0, start < end, end <= input.duration else {
            throw EngineError.invalidInput(
                .malformed(
                    String(
                        localized: "Choose an animation range within the video and a supported frame rate.",
                        comment: "Invalid animation range")))
        }
        let span = end - start
        let frameCount = span / frameDuration + (span % frameDuration == 0 ? 0 : 1)
        var predictedBudget = FrameMemoryBudget()
        try predictedBudget.reserve(width: width, height: height, frameCount: frameCount)
        let edit = FrameEdit(rotation: input.displayRotation, size: PixelSize(width: width, height: height))
        let sampler = try await FrameSampler(
            input: input,
            frameDuration: frameDuration,
            edit: edit,
            start: start, end: end)
        var frames: [CGImage] = []
        var retainedBudget = FrameMemoryBudget()
        while let frame = try await sampler.next() {
            try retainedBudget.reserve(frame.image)
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
