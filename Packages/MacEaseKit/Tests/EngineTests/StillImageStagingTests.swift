import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite(.serialized) struct StillImageStagingTests {
    @Test(arguments: ["percent-50", "jpeg", "png", "compress"])
    func cameraImageEditsStageAtFullResolution(_ preset: String) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let inputType: UTType = preset == "png" ? .jpeg : .png
        let input = folder.appending(path: preset == "png" ? "camera.jpg" : "camera.png")
        let width = 8_064
        let height = 6_048
        try autoreleasepool {
            let image = try ImageFixtures.canvas(width: width, height: height) { canvas in
                canvas.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            try ImageFixtures.write([image], as: inputType, to: input)
        }
        let original = try Data(contentsOf: input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result: ItemResult
        switch preset {
        case "percent-50":
            result = try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
        case "compress":
            result = try await ImageCompressor.compress(
                input,
                ImageCompression(
                    goal: .bytes(Int64(original.count / 2)), allowsDownscale: false,
                    allowsFrameRateReduction: false, stripsGPS: false), context: context)
        default:
            result = try await ImageEdits.convert(
                input, ImageConversion(format: preset == "jpeg" ? .jpeg : .png), context: context)
        }
        guard case .replace(let source, let output) = result else {
            Issue.record("Expected a staged camera image, received \(result)")
            return
        }
        #expect(source == input)
        let properties = try ImageFixtures.properties(output.url)
        let resized = preset == "percent-50"
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == (resized ? width / 2 : width))
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == (resized ? height / 2 : height))
        if preset == "compress" { #expect(try ImageFixtures.fileSize(output.url) <= Int64(original.count / 2)) }
        #expect(context.warnings == (["png", "compress"].contains(preset) ? [.pngOptimizationSkipped] : []))
        #expect(try Data(contentsOf: input) == original)
    }
}
