import AVFoundation
import CoreGraphics
import Formats
import Foundation
import ImageIO
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct VideoAnimationTests {
    private func fixture() throws -> URL {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func run(_ operation: OperationID, preset: String, input: URL) async throws -> URL {
        let settings = Settings()
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
}
