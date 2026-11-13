import CoreGraphics
import Formats
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite(.serialized) struct ImageEnhancementTests {
    private static var modelURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Vendor/build/upscaler/Swin2SR.mlmodelc")
    }

    private func execute(_ source: URL) async throws -> BatchOutcome {
        try #require(FileManager.default.fileExists(atPath: Self.modelURL.path))
        let batch = try ImageEnhancement(modelURL: Self.modelURL).makeBatch(source: source)
        return try await ImageFixtures.engine().run(batch, settings: Settings()) { _ in }
    }

    private func pattern(width: Int, height: Int) throws -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                rgba[index] = UInt8((x * 7) % 256)
                rgba[index + 1] = UInt8(y * 11)
                rgba[index + 2] = (x / 4 + y / 4).isMultiple(of: 2) ? 40 : 210
            }
        }
        return try PixelBuffer(width: width, height: height, rgba: rgba).makeCGImage()
    }

    @Test func missingModelFailsBeforeScheduling() throws {
        let absent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mlmodelc")
        #expect(throws: EngineError.unsupportedCodec("Install the local image upscaler model")) {
            try ImageEnhancement(modelURL: absent).makeBatch(source: absent)
        }
    }

    @Test func realModelMatchesPinnedReferenceAndKeepsSource() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "pattern.png")
        let width = 17
        let height = 19
        try ImageFixtures.write([pattern(width: width, height: height)], as: .png, to: source)
        let original = try Data(contentsOf: source)

        let result = try await execute(source)

        let output = try ImageFixtures.output(of: result)
        #expect(output.lastPathComponent == "pattern-2x.png")
        let image = try ImageFixtures.image(output)
        #expect(image.width == 34 && image.height == 38)
        let sample = try ImageFixtures.pixel(image, x: 16, y: 18)
        #expect(abs(Int(sample[0]) - 51) <= 2)
        #expect(abs(Int(sample[1]) - 94) <= 2)
        #expect(abs(Int(sample[2]) - 19) <= 2)
        #expect(sample[3] == 255)
        #expect(try Data(contentsOf: source) == original)
        #expect(result.record != nil)
    }

    @Test func overlappingTilesMatchPinnedReferenceAtBoundary() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [pattern(width: 65, height: 19)], as: .png, to: folder.appending(path: "seam.png"))
        let result = try await execute(source)
        let image = try ImageFixtures.image(ImageFixtures.output(of: result))
        #expect(image.width == 130 && image.height == 38)
        let left = try ImageFixtures.pixel(image, x: 95, y: 18)
        let right = try ImageFixtures.pixel(image, x: 96, y: 18)
        for (actual, expected) in zip(left.prefix(3), [75, 97, 222]) {
            #expect(abs(Int(actual) - expected) <= 2)
        }
        for (actual, expected) in zip(right.prefix(3), [74, 92, 17]) {
            #expect(abs(Int(actual) - expected) <= 2)
        }
    }

    @Test func transparentAndHDRSourcesFailWithoutOutputs() async throws {
        let folder = try TestVolume.makeFolder()
        let transparent = try ImageFixtures.write(
            [ImageFixtures.disc(size: 24, background: nil)], as: .png,
            to: folder.appending(path: "transparent.png"))
        let hdr = folder.appending(path: "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(hdr, variant: .isoMono, heic: false)
        let transparentBytes = try Data(contentsOf: transparent)
        let hdrBytes = try Data(contentsOf: hdr)

        let alphaResult = try await execute(transparent)
        let hdrResult = try await execute(hdr)

        #expect(alphaResult.outcomes == [.failed(.imageTransparencyUnsupported)])
        #expect(hdrResult.outcomes == [.failed(.imageHDRUnsupported)])
        #expect(try Data(contentsOf: transparent) == transparentBytes)
        #expect(try Data(contentsOf: hdr) == hdrBytes)
        #expect(alphaResult.record == nil && hdrResult.record == nil)
    }

    @Test func animatedSourceFailsBeforeInference() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [ImageFixtures.photo(width: 20, height: 20), ImageFixtures.photo(width: 20, height: 20, seed: 2)],
            as: .gif, to: folder.appending(path: "animated.gif"))
        let original = try Data(contentsOf: source)
        let result = try await execute(source)
        #expect(result.outcomes == [.failed(.imageSequenceUnsupported)])
        #expect(result.record == nil)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func oversizedInputFailsBeforeInference() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [ImageFixtures.photo(width: 1001, height: 1000)], as: .png,
            to: folder.appending(path: "large.png"))
        let result = try await execute(source)
        #expect(result.outcomes == [.failed(.invalidInput(.frameMemoryExceeded))])
        #expect(result.record == nil)
    }

    @Test func cancellationAfterFirstTileLeavesNoOutput() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [ImageFixtures.photo(width: 80, height: 80)], as: .png,
            to: folder.appending(path: "cancel.png"))
        let original = try Data(contentsOf: source)
        let engine = try ImageFixtures.engine()
        let batch = try ImageEnhancement(modelURL: Self.modelURL).makeBatch(source: source)
        let running = Mutex<Task<BatchOutcome, Never>?>(nil)
        let reachedTile = Mutex(false)
        let task = Task {
            await engine.run(batch, settings: Settings()) { progress in
                if let fraction = progress.currentFileFraction, fraction > 0, fraction < 1 {
                    reachedTile.withLock { $0 = true }
                    running.withLock { $0?.cancel() }
                }
            }
        }
        running.withLock { $0 = task }
        let result = await task.value
        #expect(reachedTile.withLock { $0 })
        #expect(result.wasCancelled)
        #expect(result.record == nil)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "cancel-2x.png").path))
    }
}
