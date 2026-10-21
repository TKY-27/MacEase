import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine
@testable import Formats

@Suite(.serialized) struct StillImageMemoryTests {
    @Test(arguments: ["percent-50", "jpeg", "png", "compress"])
    func ordinaryCameraImageWorks(_ preset: String) async throws {
        let folder = try TestVolume.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let inputType: UTType = preset == "png" ? .jpeg : .png
        let source = folder.appending(path: preset == "png" ? "camera.jpg" : "camera.png")
        let width = 8_064
        let height = 6_048
        try autoreleasepool {
            let image = try ImageFixtures.canvas(width: width, height: height) { canvas in
                canvas.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            try ImageFixtures.write([image], as: inputType, to: source)
        }
        let encodedSize = try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(encodedSize < 1_000_000)
        let resize = preset == "percent-50"
        let outcome: BatchOutcome
        if preset == "compress" {
            let compression = ImageCompression(
                goal: .bytes(Int64(encodedSize / 2)), allowsDownscale: false,
                allowsFrameRateReduction: false, stripsGPS: false)
            outcome = try await ImageFixtures.run(.imageCompress, .compress(compression), inputs: [source])
        } else {
            outcome = try await ImageFixtures.run(
                resize ? .imageResize : .imageConvert, preset: preset, inputs: [source])
        }
        let output = try ImageFixtures.output(of: outcome)
        let properties = try ImageFixtures.properties(output)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == (resize ? 4_032 : width))
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == (resize ? 3_024 : height))
        #expect(output.pathExtension == (preset == "jpeg" ? "jpg" : "png"))
        let warnings: [ItemWarning] = ["png", "compress"].contains(preset) ? [.pngOptimizationSkipped] : []
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: warnings)])
        if preset == "compress" { #expect(try ImageFixtures.fileSize(output) <= Int64(encodedSize / 2)) }
    }

    @Test func firstPageConversionAccountsForOtherRetainedPages() async throws {
        let folder = try TestVolume.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "pages.tiff")
        try autoreleasepool {
            let pages = try [5_900, 5_000].map { edge in
                try ImageFixtures.canvas(width: edge, height: edge) { canvas in
                    canvas.setFillColor(CGColor(gray: 1, alpha: 1))
                    canvas.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
                }
            }
            let lzwCompression = 5
            try ImageFixtures.write(
                pages, as: .tiff, to: source,
                frameProperties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: lzwCompression]])
        }
        let outcome = try await ImageFixtures.run(.imageConvert, preset: "png", inputs: [source])
        let output = try ImageFixtures.output(of: outcome)
        #expect(
            outcome.outcomes == [.succeeded(outputs: [output], warnings: [.firstPageOnly, .pngOptimizationSkipped])])
        let properties = try ImageFixtures.properties(output)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 5_900)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 5_900)
    }

    @Test func rejectsFourHundredMegapixelsBeforeDecode() async throws {
        let folder = try TestVolume.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let edge = 20_000
        let bitsPerByte = 8
        let raster = PNGRaster(
            width: edge, height: edge, colorType: .gray, bitDepth: 1,
            samples: [UInt8](repeating: 0, count: edge / bitsPerByte * edge))
        let encoded = try PNGFile.encode(raster, strategy: .none, level: PNGFile.trialLevel)
        let source = folder.appending(path: "oversized.png")
        try encoded.write(to: source)
        let properties = try ImageFixtures.properties(source)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == edge)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == edge)
        await #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            _ = try await ImageDocument.load(source)
        }
        #expect(try Data(contentsOf: source) == encoded)
    }

    @Test func individualFrameBudgetAcceptsTwoHundredMegapixels() throws {
        var budget = FrameMemoryBudget()
        try budget.reserve(width: 20_000, height: 10_000)
        #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            try budget.reserve(width: 20_000, height: 10_000)
        }
    }

    @Test func tracingBudgetAccountsForGrayscaleExpansion() throws {
        let width = 10_000
        let height = 5_000
        let bitsPerByte = 8
        let rowBytes = width / bitsPerByte
        let provider = try #require(CGDataProvider(data: Data(count: rowBytes * height) as CFData))
        let image = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
        #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            _ = try ImageEncoder.encode(
                [ImageFrame(image: image, duration: 0)], as: .svg,
                options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        }
    }

    @Test func geometryRejectsCombinedWorkspaceBeforeRendering() throws {
        let image = try ImageFixtures.disc(size: 16)
        #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            _ = try ImagePixels.scaled(image, width: 20_000, height: 20_000)
        }
    }
}
