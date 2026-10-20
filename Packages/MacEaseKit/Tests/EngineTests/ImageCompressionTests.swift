import CoreGraphics
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine

private typealias Fixture = ImageFixtures

/// SPEC 8.10 lower bound.
private let acceptedShare = 0.92

private func compression(_ goal: CompressionGoal, downscale: Bool = true) -> ImageOperation {
    .compress(
        ImageCompression(goal: goal, allowsDownscale: downscale, allowsFrameRateReduction: true, stripsGPS: false))
}

private func expectTargetHit(for format: ImageFormat, minimumShare: Double = acceptedShare) async throws {
    let folder = try TestVolume.makeFolder()
    let source = try Fixture.write(
        [try Fixture.photo(width: 800, height: 600)], as: .png, to: folder.appending(path: "source.png"))
    let input = try Fixture.output(of: try await Fixture.run(.imageConvert, preset: format.rawValue, inputs: [source]))
    let target = try Fixture.fileSize(input) / 2

    let outcome = try await Fixture.run(.imageCompress, compression(.bytes(target)), inputs: [input])

    let output = try Fixture.output(of: outcome)
    #expect(output.pathExtension == input.pathExtension)
    let size = try Fixture.fileSize(output)
    #expect(size <= target, "\(format) \(size) > \(target)")
    #expect(Double(size) >= Double(target) * minimumShare, "\(format) \(size) under share of \(target)")
    #expect(try Fixture.image(output).width == 800)
}

@Suite(.serialized) struct ImageCompressionTests {
    @Test(arguments: [ImageFormat.jpeg, .webp, .jxl])
    func qualityFormatsLandJustUnderTheTarget(format: ImageFormat) async throws {
        try await expectTargetHit(for: format)
    }

    /// libaom exposes only 64 quantizer steps.
    @Test func avifStaysUnderTheTarget() async throws {
        try await expectTargetHit(for: .avif, minimumShare: 0)
    }

    /// ImageIO quantizes HEIC quality into coarse steps.
    @Test(.enabled(if: ImageFixtures.canEncodeHEIC)) func heicStaysUnderTheTarget() async throws {
        try await expectTargetHit(for: .heic, minimumShare: 0)
    }

    @Test func pngQuantizesUnderTheTarget() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 400, height: 300)], as: .png, to: folder.appending(path: "shot.png"))
        let target = try Fixture.fileSize(input) / 2
        let outcome = try await Fixture.run(.imageCompress, compression(.bytes(target)), inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(try Fixture.fileSize(output) <= target)
        #expect(try Fixture.properties(output)[kCGImagePropertyColorModel] as? String == "RGB")
        #expect(try Fixture.image(output).width == 400)
    }

    @Test func animatedGIFsShrinkUnderTheTarget() async throws {
        let folder = try TestVolume.makeFolder()
        let frames = try (0..<6).map { try Fixture.photo(width: 160, height: 120, seed: $0) }
        let delay: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
        let input = try Fixture.write(frames, as: .gif, to: folder.appending(path: "clip.gif"), frameProperties: delay)
        let target = try Fixture.fileSize(input) / 2
        let outcome = try await Fixture.run(.imageCompress, compression(.bytes(target)), inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(try Fixture.fileSize(output) <= target)
        #expect(CGImageSourceGetCount(try Fixture.source(output)) > 1)
    }

    @Test func instagramCropsToItsAspectAndWritesJPEG() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 1000, height: 1500)], as: .png, to: folder.appending(path: "tall.png"))
        let outcome = try await Fixture.run(.imageCompress, preset: "instagram", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(output.lastPathComponent == "tall.jpg")
        let image = try Fixture.image(output)
        #expect(image.width == 1000 && image.height == 1250)
        #expect(!FileManager.default.fileExists(atPath: input.path))
    }

    @Test func webPresetConvertsAndLimitsTheLongEdge() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 2400, height: 1200)], as: .jpeg, to: folder.appending(path: "wide.jpg"))
        let outcome = try await Fixture.run(.imageCompress, preset: "web", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(output.pathExtension == "webp")
        #expect(try Fixture.image(output).width == 1920)
    }

    @Test func qualityPresetsShrinkAndKeepTheFormat() async throws {
        let folder = try TestVolume.makeFolder()
        let jpeg = try Fixture.write(
            [try Fixture.photo()], as: .jpeg, to: folder.appending(path: "q.jpg"), quality: 0.98)
        let before = try Fixture.fileSize(jpeg)
        let low = try await Fixture.run(.imageCompress, preset: "quality-low", inputs: [jpeg])
        let output = try Fixture.output(of: low)
        #expect(output == jpeg)
        #expect(try Fixture.fileSize(output) < before)
        let again = try await Fixture.run(.imageCompress, preset: "quality-high", inputs: [output])
        #expect(again.outcomes == [.skipped(.outputNotSmaller)])

        let png = try Fixture.write([try Fixture.photo()], as: .png, to: folder.appending(path: "q.png"))
        let pngBefore = try Fixture.fileSize(png)
        let quantized = try await Fixture.run(.imageCompress, preset: "quality-medium", inputs: [png])
        #expect(try Fixture.fileSize(try Fixture.output(of: quantized)) < pngBefore / 2)
    }

    @Test func unreachableTargetsFailWithTheSmallestSizeAndKeepTheOriginal() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write([try Fixture.photo()], as: .jpeg, to: folder.appending(path: "big.jpg"))
        let original = try Data(contentsOf: input)
        let outcome = try await Fixture.run(.imageCompress, compression(.bytes(500), downscale: false), inputs: [input])
        guard case .failed(.targetUnreachable(let smallest)) = try #require(outcome.outcomes.first) else {
            Issue.record("expected targetUnreachable, got \(outcome.outcomes)")
            return
        }
        #expect(smallest > 500)
        #expect(try Data(contentsOf: input) == original)

        let roomy = try await Fixture.run(.imageCompress, compression(.bytes(100_000_000)), inputs: [input])
        #expect(roomy.outcomes == [.skipped(.alreadyDone)])
    }

    @Test func platformPresetsOnlyDropGPSFromFilesAlreadyUnderTheLimit() async throws {
        let folder = try TestVolume.makeFolder()
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ]
        let input = try Fixture.write(
            [try Fixture.photo(width: 1200, height: 900)], as: .jpeg, to: folder.appending(path: "trip.jpg"),
            frameProperties: gps, quality: 0.9)
        let pixels = try Fixture.rawBytes(input)
        let outcome = try await Fixture.run(.imageCompress, preset: "discord", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(try Fixture.properties(output)[kCGImagePropertyGPSDictionary] == nil)
        #expect(try Fixture.rawBytes(output) == pixels)

        let again = try await Fixture.run(.imageCompress, preset: "discord", inputs: [output])
        #expect(again.outcomes == [.skipped(.alreadyDone)])
    }

    @Test func instagramCropsSmallPortraitJPEGs() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 1080, height: 1920)], as: .jpeg, to: folder.appending(path: "story.jpg"))
        let outcome = try await Fixture.run(.imageCompress, preset: "instagram", inputs: [input])
        let image = try Fixture.image(try Fixture.output(of: outcome))
        #expect(image.width == 1080 && image.height == 1350)
    }
}
