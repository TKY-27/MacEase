import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

private let canWriteAnimatedHEIC: Bool = {
    let encoded = NSMutableData()
    guard let image = try? ImageFixtures.disc(size: 16),
        let destination = CGImageDestinationCreateWithData(encoded, UTType.heics.identifier as CFString, 2, nil)
    else { return false }
    let frameProperties: [CFString: Any] = [
        kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: 0.2]
    ]
    CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
    CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination),
        let source = CGImageSourceCreateWithData(encoded, nil),
        let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
    else { return false }
    return type.conforms(to: .heics) && CGImageSourceGetCount(source) == 2
}()

private func stagedOutput(_ result: ItemResult, replacing original: URL) throws -> URL {
    guard case .replace(let source, let output) = result else {
        Issue.record("expected a replacement output")
        throw CocoaError(.fileNoSuchFile)
    }
    #expect(source == original)
    return output.url
}

@Suite(.serialized) struct ImageReviewTests {
    @Test func encoderRejectsMultipleHEICFrames() throws {
        let image = try ImageFixtures.disc(size: 16)
        let frames = [ImageFrame(image: image, duration: 0.2), ImageFrame(image: image, duration: 0.2)]
        #expect(throws: EngineError.unsupportedCodec("HEICS")) {
            try ImageEncoder.encode(frames, as: .heic, options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        }
    }

    @Test func trimKeepsContentFromEveryAnimationFrame() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let first = try ImageFixtures.canvas(width: 12, height: 8) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 2, y: 2, width: 2, height: 4))
        }
        let second = try ImageFixtures.canvas(width: 12, height: 8) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 8, y: 2, width: 2, height: 4))
        }
        let input = try ImageFixtures.write(
            [first, second], as: .png, to: folder.appending(path: "moving.png"),
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]],
            frameProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]])

        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let output = try stagedOutput(try await ImageEdits.trimBorders(input, context: context), replacing: input)

        #expect(CGImageSourceGetCount(try ImageFixtures.source(output)) == 2)
        for index in 0..<2 {
            let image = try ImageFixtures.image(output, index: index)
            #expect(image.width == 8 && image.height == 4)
        }
        let laterPixel = try ImageFixtures.pixel(ImageFixtures.image(output, index: 1), x: 7, y: 1)
        #expect(laterPixel[2] > 245)
    }

    @Test(.enabled(if: canWriteAnimatedHEIC)) func editsNeverReplaceAnimatedHEICWithAStill() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let frames = try [ImageFixtures.disc(size: 32), ImageFixtures.photo(width: 32, height: 32)]
        let input = try ImageFixtures.write(
            frames, as: .heics, to: folder.appending(path: "sequence.heics"),
            properties: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]],
            frameProperties: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: 0.2]])
        let original = try Data(contentsOf: input)
        #expect(CGImageSourceGetCount(try ImageFixtures.source(input)) == 2)

        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.unsupportedCodec("HEICS")) {
            try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func animatedPNGPreservesExifAndTiming() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let frames = try [ImageFixtures.disc(size: 32), ImageFixtures.photo(width: 32, height: 32)]
        let input = try ImageFixtures.write(
            frames, as: .png, to: folder.appending(path: "tagged.png"),
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]],
            frameProperties: [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Review Lens"],
            ])
        let sourceExif = try ImageFixtures.properties(input)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(sourceExif?[kCGImagePropertyExifLensModel] as? String == "Review Lens")

        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let document = try await ImageDocument.load(input)
        let output = try stagedOutput(
            try await ImageOutput.transformed(
                document, as: document.writableFormat, context: context, geometry: GainMapGeometry.resize
            ) {
                image in
                try ImagePixels.draw(width: 16, height: 16, like: image, fill: nil) { graphics in
                    graphics.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
                }
            }, replacing: input)

        #expect(CGImageSourceGetCount(try ImageFixtures.source(output)) == 2)
        let outputExif = try ImageFixtures.properties(output)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(outputExif?[kCGImagePropertyExifLensModel] as? String == "Review Lens")
        let png = try ImageFixtures.properties(output, index: 1)[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(abs((png?[kCGImagePropertyAPNGDelayTime] as? Double ?? 0) - 0.2) < 0.011)
    }
}
