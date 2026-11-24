import CoreGraphics
import Formats
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoStills {
    private static let sampledFrames: Int64 = 2
    private static let millisecondsPerSecond = 1_000.0
    private static let millisecondsPerMinute = 60_000
    private static let millisecondsPerWholeSecond = 1_000

    static func run(
        _ still: VideoStill, url: URL, context: ItemContext, omissions: [URL: StreamOmission] = [:]
    ) async throws -> ItemResult {
        if case .edited(let edit, let outputSeconds) = still {
            return try await edited(
                edit, outputSeconds: outputSeconds, url: url, context: context, omissions: omissions)
        }
        let input = try await MediaInput.openWithFallback(url, context: context, enforceStreamConsent: false)
        let metadata = try await VideoMetadata.load(from: input)
        let losses = metadata.losses(for: nil, includingAudio: false)
        if !losses.isEmpty { context.warn(.videoMetadataDropped(losses)) }
        let toneMapToSDR = try await VideoProperties.toneMapsExport(input, context: context)
        let time: Int64 =
            switch still {
            case .first: 0
            case .middle: input.duration / 2
            case .at(let seconds): min(max(try Nanoseconds.from(seconds: seconds), 0), input.duration)
            case .edited: 0
            }
        let (frameSpan, spanOverflow) = input.frameDuration.multipliedReportingOverflow(by: sampledFrames)
        let (end, endOverflow) = time.addingReportingOverflow(frameSpan)
        guard !spanOverflow, !endOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        var stillEdit = FrameEdit(displayOrientation: try input.displayOrientation)
        stillEdit.preservesOddDimensions = true
        let sampler = try await FrameSampler(
            input: input, frameDuration: input.frameDuration,
            edit: stillEdit,
            start: time, end: end, toneMapToSDR: toneMapToSDR)
        guard let frame = try await sampler.next() else { throw EngineError.decodeFailed("no frame at that time") }
        let format = context.settings.video.thumbnailFormat
        let type: UTType = format == .png ? .png : .jpeg
        let name = url.deletingPathExtension().lastPathComponent + "." + format.rawValue
        let output = try context.stagingURL(for: url, name: name)
        try ImageFiles.write([try CGImage.make(from: frame.image)], type: type, to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    private static func edited(
        _ edit: VideoEdit, outputSeconds: Double, url: URL, context: ItemContext, omissions: [URL: StreamOmission]
    ) async throws -> ItemResult {
        try edit.sourceStamp?.validate(url)
        try edit.geometry.validate()
        guard outputSeconds.isFinite, outputSeconds >= 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let resolved = try await edit.openedSources(
            primaryURL: url, omittedStreams: context.omittedStreams, omissions: omissions, context: context)
        let inputs = resolved.inputs
        let first = inputs[0]
        let sourceDuration = Double(first.duration) / Double(Nanoseconds.perSecond)
        let timeline = try VideoTimeline(edit: resolved.edit, sourceDuration: sourceDuration)
        guard outputSeconds <= timeline.duration else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let duration = try Nanoseconds.from(seconds: timeline.duration)
        let rawTimestamp = min(try Nanoseconds.from(seconds: outputSeconds), duration - 1)
        let timestamp = (rawTimestamp / first.frameDuration) * first.frameDuration
        var toneMapToSDR = false
        for input in inputs {
            let metadata = try await VideoMetadata.load(from: input)
            let losses = metadata.losses(for: nil, includingAudio: false)
            if !losses.isEmpty {
                let warning = ItemWarning.videoMetadataDropped(losses)
                if !context.warnings.contains(warning) { context.warn(warning) }
            }
            if try await VideoProperties.toneMapsExport(input, context: context) { toneMapToSDR = true }
        }
        let cropped = edit.geometry.outputSize(
            CGSize(width: first.displaySize.width, height: first.displaySize.height))
        let natural = PixelSize(width: Int(cropped.width), height: Int(cropped.height))
        let size = try edit.resize?.outputSize(natural)
        let changesSize = size.map { $0 != natural } ?? false
        var frameEdit = FrameEdit(displayOrientation: try first.displayOrientation)
        if !edit.geometry.isIdentity { frameEdit.editorGeometry = edit.geometry }
        if changesSize { frameEdit.size = size }
        frameEdit.hasOverlays = !timeline.overlays.isEmpty
        frameEdit.fill = context.settings.video.rotationFill
        let format = context.settings.video.thumbnailFormat
        if inputs.count > 1 {
            frameEdit.fitCanvas = first.displaySize
            frameEdit.flattensAlpha = true
        } else if first.video?.hasAlpha == true, format == .jpeg {
            frameEdit.flattensAlpha = true
        }
        let source = try TimelineFrameSource(
            inputs: inputs, frameDuration: first.frameDuration, edit: frameEdit, timeline: timeline,
            toneMapToSDR: toneMapToSDR)
        let buffer = try await source.frame(at: timestamp)
        try edit.sourceStamp?.validate(url)
        if let sources = edit.sources {
            for source in sources { try source.stamp.validate(source.url) }
        }
        let type: UTType = format == .png ? .png : .jpeg
        let stem = url.deletingPathExtension().lastPathComponent
        let name = "\(stem)_frame_\(frameTimestamp(outputSeconds)).\(format.rawValue)"
        let output = try context.stagingURL(for: url, name: name)
        try ImageFiles.write([try CGImage.make(from: buffer)], type: type, to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    private static func frameTimestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((seconds * millisecondsPerSecond).rounded())
        let minutes = totalMilliseconds / millisecondsPerMinute
        let wholeSeconds = (totalMilliseconds % millisecondsPerMinute) / millisecondsPerWholeSecond
        let milliseconds = totalMilliseconds % millisecondsPerWholeSecond
        return String(
            format: "%d-%02d.%03d", locale: Locale(identifier: "en_US_POSIX"),
            minutes, wholeSeconds, milliseconds)
    }
}

enum VideoAnimations {
    private static let maximumEncodedWebPBytes = 100_000_000
    private static let maximumFrameBytes = 32_000_000
    private static let rgbaBytesPerPixel = 4
    private static let millisecondsPerSecond = 1_000.0
    static func gif(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws -> ItemResult {
        let sampling = try await Sampling(rendering, url: url, context: context)
        let name = url.deletingPathExtension().lastPathComponent + ".gif"
        let output = try context.stagingURL(for: url, name: name)
        try await encodeGIF(rendering, sampling: sampling, to: output, context: context)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    static func apng(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws -> ItemResult {
        let sampling = try await Sampling(rendering, url: url, context: context)
        let name = url.deletingPathExtension().lastPathComponent + ".png"
        let output = try context.stagingURL(for: url, name: name)
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.png.identifier as CFString, sampling.frameCount, nil)
        else { throw EngineError.encodeFailed("cannot create APNG") }
        let loop = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: rendering.loops ? 0 : 1]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        // Millisecond rounding prevents ImageIO timing drift.
        var frameIndex = 0
        var emittedMilliseconds = 0
        try await sampling.consume(context: context) { image in
            frameIndex += 1
            let target = Int((Double(frameIndex) * sampling.duration * millisecondsPerSecond).rounded())
            let delay = Double(target - emittedMilliseconds) / millisecondsPerSecond
            emittedMilliseconds = target
            let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed("APNG write failed") }
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    static func webP(_ rendering: AnimationRendering, url: URL, context: ItemContext) async throws -> ItemResult {
        let sampling = try await Sampling(rendering, url: url, context: context)
        let encoder = try WebPAnimationEncoder.Stream(
            width: sampling.size.width, height: sampling.size.height,
            quality: Double(context.settings.image.webpQuality), loops: rendering.loops,
            maximumEncodedBytes: maximumEncodedWebPBytes)
        let name = url.deletingPathExtension().lastPathComponent + ".webp"
        let output = try context.stagingURL(for: url, name: name)
        do {
            try await sampling.consume(context: context) { image in
                try encoder.add(image, duration: sampling.duration)
            }
            try encoder.finish(to: output)
        } catch WebPAnimationEncoder.Stream.Error.encodedSizeExceeded {
            throw EngineError.invalidInput(.frameMemoryExceeded)
        }
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    static func gifX(url: URL, context: ItemContext) async throws -> ItemResult {
        guard let limits = context.settings.platformPresets.first(where: { $0.id == "x" })?.gif,
            let maxBytes = limits.targetBytes, let maxWidth = limits.maxWidth,
            let maxHeight = limits.maxHeight, let maxFrames = limits.maxFrames
        else { throw EngineError.invalidInput(.malformed("X GIF limits are missing")) }
        guard maxFrames > 0, maxWidth > 0, maxHeight > 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }

        let input = try await MediaInput.openWithFallback(url, context: context, enforceStreamConsent: false)
        let seconds = Double(input.duration) / Double(Nanoseconds.perSecond)
        guard seconds > 0 else { throw EngineError.invalidInput(.emptyInput) }
        var rendering = AnimationRendering(width: min(maxWidth, input.displaySize.width), framesPerSecond: 15)
        rendering.colors = min(max(context.settings.video.gifColors, 2), 256)
        rendering.dithering = context.settings.image.gifDithering
        rendering.loops = context.settings.video.gifLoops
        let limitedRate = min(Double(rendering.framesPerSecond), (Double(maxFrames) / seconds).rounded(.down))
        rendering.framesPerSecond = max(1, Int(limitedRate))
        let frameLimit = Int64(maxFrames)
        let minimumFrameDuration = input.duration / frameLimit + (input.duration % frameLimit == 0 ? 0 : 1)

        let name = url.deletingPathExtension().lastPathComponent + ".gif"
        let output = try context.stagingURL(for: url, name: name)
        func attempt() async throws -> Int64 {
            let sampling = try await Sampling(
                rendering, maxHeight: maxHeight, minimumFrameDuration: minimumFrameDuration, url: url,
                openedInput: input, context: context)
            guard sampling.frameCount <= maxFrames else {
                throw EngineError.invalidInput(.malformed("X GIF exceeds its frame limit"))
            }
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try await encodeGIF(rendering, sampling: sampling, to: output, context: context)
            // URL caches survive file replacement.
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            guard let byteCount = attributes[.size] as? Int64 else {
                throw EngineError.encodeFailed("GIF size is unavailable")
            }
            return byteCount
        }
        var byteCount = try await attempt()
        var smallestBytes = byteCount
        while byteCount > maxBytes, rendering.framesPerSecond > 1 {
            rendering.framesPerSecond -= 1
            byteCount = try await attempt()
            smallestBytes = min(smallestBytes, byteCount)
        }
        while byteCount > maxBytes, rendering.width > 1 {
            rendering.width = max(1, Int((Double(rendering.width) * 0.9).rounded(.down)))
            byteCount = try await attempt()
            smallestBytes = min(smallestBytes, byteCount)
        }
        while byteCount > maxBytes, rendering.colors > 2 {
            rendering.colors = max(2, rendering.colors / 2)
            byteCount = try await attempt()
            smallestBytes = min(smallestBytes, byteCount)
        }
        guard byteCount <= maxBytes else {
            throw EngineError.targetUnreachable(smallestBytes: smallestBytes)
        }
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .image)])
    }

    private static func encodeGIF(
        _ rendering: AnimationRendering, sampling: Sampling, to output: URL, context: ItemContext
    ) async throws {
        let options = GIFOptions(
            colors: rendering.colors, dithering: rendering.dithering, loops: rendering.loops, paletteScope: .perFrame)
        let encoder = try GIFEncoder.Stream(
            width: sampling.size.width, height: sampling.size.height, options: options, to: output)
        try await sampling.consume(context: context) { image in
            try encoder.add(GIFFrame(pixels: PixelBuffer(cgImage: image), duration: sampling.duration))
        }
        try encoder.finish()
    }

    private struct Sampling {
        let input: MediaInput
        let size: PixelSize
        let start: Int64
        let end: Int64
        let interval: Int64
        let frameCount: Int
        let toneMapToSDR: Bool
        var duration: Double { Double(interval) / Double(Nanoseconds.perSecond) }

        init(
            _ rendering: AnimationRendering, maxHeight: Int? = nil, minimumFrameDuration: Int64 = 0, url: URL,
            openedInput: MediaInput? = nil, context: ItemContext
        ) async throws {
            guard rendering.width > 0, rendering.framesPerSecond > 0 else {
                throw EngineError.invalidInput(.invalidAnimationRange)
            }
            if let openedInput {
                input = openedInput
            } else {
                input = try await MediaInput.openWithFallback(url, context: context, enforceStreamConsent: false)
            }
            let metadata = try await VideoMetadata.load(from: input)
            let losses = metadata.losses(for: nil, includingAudio: false)
            if !losses.isEmpty { context.warn(.videoMetadataDropped(losses)) }
            toneMapToSDR = try await VideoProperties.toneMapsExport(input, context: context)
            let display = input.displaySize
            let scale = min(
                1,
                min(
                    Double(rendering.width) / Double(display.width),
                    Double(maxHeight ?? Int.max) / Double(display.height)))
            size = PixelSize(
                width: max(1, Int((Double(display.width) * scale).rounded())),
                height: max(1, Int((Double(display.height) * scale).rounded()))
            ).evened()
            let sourceSeconds = Double(input.duration) / Double(Nanoseconds.perSecond)
            guard
                [rendering.start, rendering.end].compactMap({ $0 }).allSatisfy({
                    $0.isFinite && $0 >= 0 && $0 <= sourceSeconds
                })
            else { throw EngineError.invalidInput(.invalidAnimationRange) }
            start = try rendering.start.map { try Nanoseconds.from(seconds: $0) } ?? 0
            end = try rendering.end.map { try Nanoseconds.from(seconds: $0) } ?? input.duration
            interval = max(Nanoseconds.perSecond / Int64(rendering.framesPerSecond), minimumFrameDuration)
            guard interval > 0, start >= 0, start < end, end <= input.duration else {
                throw EngineError.invalidInput(.invalidAnimationRange)
            }
            let centeredSpan = end - start - interval / 2
            guard centeredSpan > 0 else { throw EngineError.invalidInput(.emptyInput) }
            frameCount = Int((centeredSpan - 1) / interval + 1)
            guard size.width <= maximumFrameBytes / rgbaBytesPerPixel / size.height else {
                throw EngineError.invalidInput(.frameMemoryExceeded)
            }
            var workingBudget = FrameMemoryBudget()
            try workingBudget.reserve(width: size.width, height: size.height)
        }

        func consume(context: ItemContext, frameBody: (CGImage) throws -> Void) async throws {
            let edit = FrameEdit(displayOrientation: try input.displayOrientation, size: size)
            let sampler = try await FrameSampler(
                input: input, frameDuration: interval, edit: edit, start: start, end: end,
                toneMapToSDR: toneMapToSDR)
            var sampledCount = 0
            while let frame = try await sampler.next() {
                try autoreleasepool {
                    try frameBody(CGImage.make(from: frame.image))
                }
                sampledCount += 1
                context.progress(Double(frame.timestamp - start) / Double(end - start))
            }
            guard sampledCount > 0 else { throw EngineError.invalidInput(.emptyInput) }
            guard sampledCount == frameCount else { throw EngineError.decodeFailed("animation ended before its range") }
        }
    }
}

enum ImageFiles {
    static func write(_ images: [CGImage], type: UTType, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, images.count, nil)
        else { throw EngineError.encodeFailed("cannot create \(type.identifier)") }
        for image in images { CGImageDestinationAddImage(destination, image, nil) }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.encodeFailed("image write failed") }
    }
}
