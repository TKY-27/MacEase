import CoreGraphics
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite(.serialized) struct ExportModeTests {
    @Test func encodingsHaveExactByteSignaturesAndReplacementPolicies() throws {
        let utf8 = try TextEncoding.encode("Aあ", as: .utf8, unmappable: .fail)
        let utf8BOM = try TextEncoding.encode("Aあ", as: .utf8BOM, unmappable: .fail)
        let utf16 = try TextEncoding.encode("Aあ", as: .utf16, unmappable: .fail)
        let shiftJIS = try TextEncoding.encode("Aあ", as: .shiftJIS, unmappable: .fail)
        #expect(Array(utf8.data) == [0x41, 0xE3, 0x81, 0x82])
        #expect(Array(utf8BOM.data) == [0xEF, 0xBB, 0xBF, 0x41, 0xE3, 0x81, 0x82])
        #expect(Array(utf16.data) == [0xFF, 0xFE, 0x41, 0x00, 0x42, 0x30])
        #expect(Array(shiftJIS.data) == [0x41, 0x82, 0xA0])
        #expect(!shiftJIS.replaced)
        let custom = try TextEncoding.encode("A😀", as: .shiftJIS, unmappable: .custom, substitute: "※")
        #expect(Array(custom.data) == [0x41, 0x81, 0xA6])
        #expect(custom.replaced)
        let reference = try TextEncoding.encode("😀", as: .shiftJIS, unmappable: .numericReference)
        #expect(String(decoding: reference.data, as: UTF8.self) == "&#128512;")
        #expect(reference.replaced)
        #expect(throws: EngineError.invalidInput(.unmappableCharacter(line: 1))) {
            try TextEncoding.encode("😀", as: .shiftJIS, unmappable: .fail)
        }
        for substitute in ["", "ab", "😀", "か\u{3099}"] {
            #expect(
                throws: EngineError.invalidInput(.malformed("Shift_JIS substitute must be one encodable character"))
            ) {
                try TextEncoding.encode("A", as: .shiftJIS, unmappable: .custom, substitute: substitute)
            }
        }
    }

    @Test func embeddedRasterPreservesPNGDimensionsAndPixels() throws {
        let image = try ImageFixtures.photo(width: 37, height: 23)
        var options = EncodeOptions(quality: ImageEncoder.maximumQuality)
        options.svgMode = .embeddedPNG
        let encoded = try ImageEncoder.encode([ImageFrame(image: image, duration: 0)], as: .svg, options: options)
        let svg = String(decoding: encoded, as: UTF8.self)
        let payload = try #require(
            svg.components(separatedBy: "data:image/png;base64,").dropFirst().first?
                .components(separatedBy: "\"").first)
        let raster = try #require(Data(base64Encoded: payload))
        let source = try #require(CGImageSourceCreateWithData(raster as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 37 && decoded.height == 23)
        #expect(svg.contains("<image "))
        #expect(!svg.contains("<path "))
        #expect(try ImageFixtures.pixel(decoded, x: 18, y: 11) == ImageFixtures.pixel(image, x: 18, y: 11))
    }

    @Test(
        .requires(.textRecognition) { await TextRecognition.isAvailable },
        arguments: [
            TextEncodingTarget.utf8, .utf8BOM, .utf16, .shiftJIS,
        ])
    func ocrSaveUsesSelectedEncoding(target: TextEncodingTarget) async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [try ImageFixtures.text("MacEase reads text")], as: .png, to: folder.appending(path: "sign.png"))
        var settings = Settings()
        settings.intelligence.ocrFileEncoding = target

        let outcome = try await ImageFixtures.run(.imageOCR, preset: "save", inputs: [source], settings: settings)

        let output = try ImageFixtures.output(of: outcome)
        let bytes = try Data(contentsOf: output)
        #expect(output.lastPathComponent == "sign_ocr.txt")
        #expect(FileManager.default.fileExists(atPath: source.path))
        switch target {
        case .utf8:
            #expect(!bytes.starts(with: [0xEF, 0xBB, 0xBF]))
            #expect(String(data: bytes, encoding: .utf8)?.contains("MacEase") == true)
        case .utf8BOM:
            #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
            #expect(String(data: bytes.dropFirst(3), encoding: .utf8)?.contains("MacEase") == true)
        case .utf16:
            #expect(bytes.starts(with: [0xFF, 0xFE]))
            #expect(String(data: bytes, encoding: .utf16)?.contains("MacEase") == true)
        case .shiftJIS:
            #expect(String(data: bytes, encoding: TextEncoding.cp932)?.contains("MacEase") == true)
        }
    }

    @Test func customSubstituteWarnsAndRejectsInvalidValues() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "emoji.txt")
        try Data("a😀b".utf8).write(to: source)
        var settings = Settings()
        settings.outputMode = .replace
        settings.text.unmappable = .custom
        settings.text.shiftJISSubstitute = "※"
        let engine = try ImageFixtures.engine()
        let request = OperationRequest(
            op: .textEncoding, options: .text(.encoding(.shiftJIS, source: nil)), inputs: [source])

        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }

        #expect(outcome.outcomes == [.succeeded(outputs: [source], warnings: [.unmappableCharactersReplaced])])
        #expect(try Data(contentsOf: source) == "a※b".data(using: TextEncoding.cp932))

        settings.text.shiftJISSubstitute = "ab"
        let invalidSource = folder.appending(path: "invalid.txt")
        let unmodified = Data("a😀b".utf8)
        try unmodified.write(to: invalidSource)
        let invalidRequest = OperationRequest(
            op: .textEncoding, options: .text(.encoding(.shiftJIS, source: nil)), inputs: [invalidSource])
        let invalid = await engine.run(
            OperationPlanner.batch(for: invalidRequest, settings: settings), settings: settings
        ) { _ in }
        #expect(
            invalid.outcomes == [
                .failed(.invalidInput(.malformed("Shift_JIS substitute must be one encodable character")))
            ])
        #expect(try Data(contentsOf: invalidSource) == unmodified)
    }

    @Test func embeddedSVGContainsOriginalRaster() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 37, height: 23)], as: .png, to: folder.appending(path: "logo.png"))
        var settings = Settings()
        settings.image.svgMode = .embeddedPNG

        let outcome = try await ImageFixtures.run(.imageConvert, preset: "svg", inputs: [source], settings: settings)

        let output = try ImageFixtures.output(of: outcome)
        let svg = try String(contentsOf: output, encoding: .utf8)
        let marker = "data:image/png;base64,"
        let payload = try #require(
            svg.components(separatedBy: marker).dropFirst().first?.components(separatedBy: "\"").first)
        let raster = try #require(Data(base64Encoded: payload))
        let png = try #require(CGImageSourceCreateWithData(raster as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(png, 0, nil))
        #expect(svg.contains("<image "))
        #expect(!svg.contains("<path "))
        #expect(decoded.width == 37 && decoded.height == 23)
        let rendered = try await SVGRenderer.render(Data(svg.utf8))
        #expect(rendered.width == 37 && rendered.height == 23)
        let embeddedPixel = try ImageFixtures.pixel(decoded, x: 18, y: 11)
        let renderedPixel = try ImageFixtures.pixel(rendered, x: 18, y: 11)
        #expect(zip(embeddedPixel, renderedPixel).allSatisfy { pair in abs(Int(pair.0) - Int(pair.1)) <= 16 })
        // The runner uses Replace, trashing the source.
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(output.deletingPathExtension() == source.deletingPathExtension())
    }

    @Test func loosePDFPagesUsePaddedNamesWithoutOverwriting() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "deck.pdf")
        var pageBox = CGRect(x: 0, y: 0, width: 72, height: 36)
        let writer = try #require(CGContext(source as CFURL, mediaBox: &pageBox, nil))
        for _ in 0..<11 {
            writer.beginPDFPage(nil)
            writer.endPDFPage()
        }
        writer.closePDF()
        let occupied = folder.appending(path: "deck_p01.png")
        let original = Data("occupied".utf8)
        try original.write(to: occupied)
        var settings = Settings()
        settings.text.pdfImageLayout = .looseFiles
        settings.text.pdfImageDPI = 72
        let engine = try ImageFixtures.engine()
        let request = OperationRequest(op: .pdfToImages, options: .pdf(.toImages(.png, dpi: 72)), inputs: [source])

        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }

        guard case .succeeded(let outputs, let warnings) = try #require(outcome.outcomes.first) else {
            Issue.record("PDF export failed: \(outcome.outcomes)")
            return
        }
        #expect(warnings.isEmpty)
        #expect(outputs.count == 11)
        #expect(outputs.first?.lastPathComponent == "deck_p01 (2).png")
        #expect(outputs.last?.lastPathComponent == "deck_p11.png")
        #expect(try Data(contentsOf: occupied) == original)
        let firstOutput = try #require(outputs.first)
        let firstImage = try #require(CGImageSourceCreateWithURL(firstOutput as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(firstImage, 0, nil))
        #expect(decoded.width == 72 && decoded.height == 36)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let restored = try await engine.undo(outcome.batchID)
        #expect(restored == Array(repeating: .restored, count: 11))
        #expect(outputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: occupied) == original)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
