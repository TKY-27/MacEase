import AVFoundation
import CoreGraphics
import Formats
import Foundation
import ImageIO
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct VideoAnimationTests {
    private static let clipWidth = 480
    private static let clipHeight = 270
    private static let clipFPS: Int32 = 15
    private static let clipSeconds = 30
    private static let clipBitrate = 150_000

    @Test func animationRangesReportTypedInvalidInput() async throws {
        let input = try fixture()
        let folder = input.deletingLastPathComponent()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        for (start, end) in [(-1.0, 1.0), (0, .nan), (.infinity, 1), (1, 0), (0, 100)] {
            var rendering = AnimationRendering(width: Self.clipWidth, framesPerSecond: Int(Self.clipFPS))
            rendering.start = start
            rendering.end = end
            await #expect(throws: EngineError.invalidInput(.invalidAnimationRange)) {
                try await VideoAnimations.gif(rendering, url: input, context: context)
            }
        }
    }

    @Test(arguments: [OperationID.videoToGIF, .videoToAnimatedWebP, .videoToAPNG])
    func thirtySecondClipConvertsWithoutRetainingEveryFrame(_ operation: OperationID) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "screen.mp4")
        try await writeScreenRecording(to: input)
        let original = try Data(contentsOf: input)
        let output = try await run(operation, preset: "480-15", input: input)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        #expect(count == Self.clipSeconds * Int(Self.clipFPS))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let last = try #require(CGImageSourceCreateImageAtIndex(source, count - 1, nil))
        #expect(first.width == Self.clipWidth)
        #expect(first.height == Self.clipHeight)
        #expect(try PixelBuffer(cgImage: first).rgba != PixelBuffer(cgImage: last).rgba)
        let timingKeys: (CFString, CFString) =
            switch operation {
            case .videoToGIF: (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime)
            case .videoToAnimatedWebP: (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime)
            default: (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime)
            }
        var duration = 0.0
        for index in 0..<count {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let timing = try #require(properties[timingKeys.0] as? [CFString: Any])
            duration += try #require(timing[timingKeys.1] as? Double)
        }
        #expect(abs(duration - Double(Self.clipSeconds)) < 1 / Double(Self.clipFPS))
        #expect(try Data(contentsOf: input) == original)
    }

    private func writeScreenRecording(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Self.clipWidth,
                AVVideoHeightKey: Self.clipHeight,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Self.clipBitrate],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.clipWidth, kCVPixelBufferHeightKey as String: Self.clipHeight,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EngineError.encodeFailed("fixture writer start") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<(Self.clipSeconds * Int(Self.clipFPS)) {
            while !input.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(2))
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess)
            let frame = try #require(created)
            try #require(CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess)
            do {
                defer { CVPixelBufferUnlockBaseAddress(frame, []) }
                let base = try #require(CVPixelBufferGetBaseAddress(frame))
                let rowBytes = CVPixelBufferGetBytesPerRow(frame)
                for y in 0..<Self.clipHeight {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<Self.clipWidth {
                        let movingEdge = index % Self.clipWidth
                        row[x] = x <= movingEdge ? 0xFFFF_0000 : 0xFF00_00FF
                    }
                }
            }
            guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: Self.clipFPS))
            else { throw writer.error ?? EngineError.encodeFailed("fixture append") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        try #require(writer.status == .completed)
    }

    private func fixture() throws -> URL {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func run(
        _ operation: OperationID, preset: String, input: URL, settings: Settings = Settings()
    ) async throws -> URL {
        let options = try #require(OperationPlanner.options(for: operation, preset: preset, settings: settings))
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let request = OperationRequest(op: operation, options: options, inputs: [input])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first), let output = outputs.first else {
            Issue.record("expected derived animation, got \(String(describing: outcome.outcomes.first))")
            throw CancellationError()
        }
        return output
    }

    @Test func animatedWebPPresetsPreserveDurationAndMotion() async throws {
        let input = try fixture()
        let sourceDuration = try await AVURLAsset(url: input).load(.duration).seconds
        for (preset, framesPerSecond) in [("480-15", 15), ("720-24", 24)] {
            let output = try await run(.videoToAnimatedWebP, preset: preset, input: input)
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let count = CGImageSourceGetCount(source)
            var durations: [Double] = []
            var framePixels: [[UInt8]] = []
            for index in 0..<count {
                let properties = try #require(
                    CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
                let webp = try #require(properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
                durations.append(
                    (webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                        ?? (webp[kCGImagePropertyWebPDelayTime] as? Double)
                        ?? 0)
                let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
                framePixels.append(try PixelBuffer(cgImage: image).rgba)
            }

            #expect(output.pathExtension == "webp")
            #expect(count == Int((sourceDuration * Double(framesPerSecond)).rounded()))
            #expect(abs(durations.reduce(0, +) - sourceDuration) <= 1 / Double(framesPerSecond))
            #expect(Set(framePixels).count > 1)
            #expect(FileManager.default.fileExists(atPath: input.path))
        }
    }

    @Test func frameSamplerKeepsEvery24FPSSample() async throws {
        let inputURL = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let input = try await MediaInput.open(inputURL)
        let frameDuration = Nanoseconds.perSecond / 24
        let sampler = try await FrameSampler(
            input: input, frameDuration: frameDuration,
            edit: FrameEdit(rotation: input.displayRotation, size: input.displaySize),
            start: 0, end: input.duration)
        var frames: [DecodedFrame] = []
        while let frame = try await sampler.next() { frames.append(frame) }
        let pixels = try frames.map { frame in
            try PixelBuffer(cgImage: CGImage.make(from: frame.image)).rgba
        }
        let first = try #require(pixels.first)
        let second = try #require(pixels.dropFirst().first)
        let lastFrame = try #require(frames.last)
        #expect(frames.count == 48)
        #expect(first.elementsEqual(second) == false)
        #expect(abs(Double(lastFrame.timestamp) / Double(Nanoseconds.perSecond) - 47.0 / 24) < 0.000001)
    }

    @Test func xGIFStaysWithinPresetLimits() async throws {
        let input = try fixture()
        let output = try await run(.videoToGIF, preset: "x", input: input)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        let byteCount = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let sourceDuration = try await AVURLAsset(url: input).load(.duration).seconds
        let preset = try #require(
            PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory).bundled.first { $0.id == "x" }?.gif)
        var durations: [Double] = []
        var framePixels: [[UInt8]] = []
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            durations.append(
                (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
                    ?? 0)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            framePixels.append(try PixelBuffer(cgImage: image).rgba)
        }

        #expect(width <= preset.maxWidth ?? .max)
        #expect(height <= preset.maxHeight ?? .max)
        #expect(CGImageSourceGetCount(source) <= preset.maxFrames ?? .max)
        #expect(Int64(byteCount) <= preset.targetBytes ?? .max)
        #expect(abs(durations.reduce(0, +) - sourceDuration) < 0.2)
        #expect(Set(framePixels).count > 1)
        #expect(FileManager.default.fileExists(atPath: input.path))
    }

    @Test func xGIFReencodesUntilItMeetsTheByteLimit() async throws {
        let input = try fixture()
        let folder = input.deletingLastPathComponent()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        var settings = Settings()
        let presetIndex = try #require(settings.platformPresets.firstIndex { $0.id == "x" })
        var limits = try #require(settings.platformPresets[presetIndex].gif)
        limits.maxBytes = 500
        settings.platformPresets[presetIndex].gif = limits
        let output = try await run(.videoToGIF, preset: "x", input: input, settings: settings)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let byteCount = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let target = try #require(limits.targetBytes)
        #expect(Int64(byteCount) <= target)
        let sourceDuration = try await AVURLAsset(url: input).load(.duration).seconds
        #expect(CGImageSourceGetCount(source) < Int(sourceDuration * Double(Self.clipFPS)))
        var elapsed = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let timing = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            elapsed += try #require(timing[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
        #expect(abs(elapsed - sourceDuration) < 1 / Double(Self.clipFPS))
        #expect(FileManager.default.fileExists(atPath: input.path))
    }
}
