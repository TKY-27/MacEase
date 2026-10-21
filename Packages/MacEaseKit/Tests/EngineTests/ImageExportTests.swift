import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MenuCatalog
import PDFKit
import Testing

@testable import Engine

private typealias Fixture = ImageFixtures

@Suite(.serialized) struct ImageExportTests {
    @Test(.requires(.textRecognition) { await TextRecognition.isAvailable })
    func ocrCopiesSavesAndShowsText() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.text("MacEase reads text")], as: .png, to: folder.appending(path: "sign.png"))

        let copied = try await Fixture.run(.imageOCR, preset: "copy", inputs: [input])
        #expect(copied.clipboardText?.contains("MacEase reads text") == true)
        let shown = try await Fixture.run(.imageOCR, preset: "show", inputs: [input])
        #expect(shown.reportText?.contains("MacEase") == true)
        let saved = try await Fixture.run(.imageOCR, preset: "save", inputs: [input])
        let file = try Fixture.output(of: saved)
        #expect(file.lastPathComponent == "sign.txt")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("reads text"))
        #expect(FileManager.default.fileExists(atPath: input.path))

        let blank = try Fixture.write(
            [try Fixture.photo(width: 64, height: 64)], as: .png, to: folder.appending(path: "blank.png"))
        let none = try await Fixture.run(.imageOCR, preset: "copy", inputs: [blank])
        #expect(none.outcomes == [.skipped(.noTextFound)])
    }

    @Test func toPDFMakesOnePageperImageInTheGivenOrder() async throws {
        let folder = try TestVolume.makeFolder()
        let widths = [300, 100, 200]
        let inputs = try widths.enumerated().map { index, width in
            try Fixture.write(
                [try Fixture.photo(width: width, height: 80, seed: index)], as: .png,
                to: folder.appending(path: "page\(index).png"))
        }
        let outcome = try await Fixture.run(.imageToPDF, preset: nil, inputs: inputs)
        #expect(outcome.outcomes.count == 1)
        let output = try Fixture.output(of: outcome)
        #expect(output.lastPathComponent == "page0.pdf")
        let document = try #require(PDFDocument(url: output))
        let pageWidths = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).width }
        #expect(pageWidths == widths.map { CGFloat($0) })
        #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func toPDFRejectsCombinedDecodedPages() async throws {
        let folder = try TestVolume.makeFolder()
        let edge = 3_600
        var inputs: [URL] = []
        for index in 0..<5 {
            let image = try Fixture.canvas(width: edge, height: edge) { canvas in
                canvas.setFillColor(CGColor(gray: 1, alpha: 1))
                canvas.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
            }
            let url = folder.appending(path: "large-page\(index).png")
            inputs.append(try Fixture.write([image], as: .png, to: url))
        }
        let originals = try inputs.map { try Data(contentsOf: $0) }

        let outcome = try await Fixture.run(.imageToPDF, preset: nil, inputs: inputs)

        #expect(outcome.outcomes == [.failed(.invalidInput(.frameMemoryExceeded))])
        #expect(try inputs.map { try Data(contentsOf: $0) } == originals)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "large-page0.pdf").path))
    }

    @Test func orientedPageChecksRotatedRowsBeforeRendering() async throws {
        let folder = try TestVolume.makeFolder()
        let width = 1_000
        let height = 65
        let image = try Fixture.canvas(width: width, height: height) { canvas in
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let source = try Fixture.write(
            [image], as: .tiff, to: folder.appending(path: "rotated.tiff"),
            frameProperties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        #expect(try Fixture.properties(source)[kCGImagePropertyOrientation] as? UInt32 == 6)
        var budget = FrameMemoryBudget()
        let reserveForRotatedRows: Int64 = 290_000
        let rowAlignment: Int64 = 64
        let frameOverhead: Int64 = 1_024
        let fillerHeight = Int((FrameMemoryBudget.maximumBytes - reserveForRotatedRows - frameOverhead) / rowAlignment)
        try budget.reserve(width: 1, height: fillerHeight)
        var rawProbe = budget
        try rawProbe.reserve(width: width, height: height)
        var rotatedProbe = budget
        #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            try rotatedProbe.reserve(width: height, height: width)
        }

        await #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            _ = try await ImageDocument.load(source, budget: &budget)
        }
    }

    @Test func iconSetsPadToSquareAndHoldEverySize() async throws {
        let folder = try TestVolume.makeFolder()
        let wide = try Fixture.photo(width: 300, height: 200)

        let icns = try await Fixture.run(
            .imageIconSet, preset: "icns",
            inputs: [try Fixture.write([wide], as: .png, to: folder.appending(path: "a.png"))])
        let icnsImage = try #require(NSImage(contentsOf: try Fixture.output(of: icns)))
        #expect(Set(icnsImage.representations.map(\.pixelsWide)).isSuperset(of: [32, 128, 256, 512, 1024]))

        let ico = try await Fixture.run(
            .imageIconSet, preset: "ico",
            inputs: [try Fixture.write([wide], as: .png, to: folder.appending(path: "b.png"))])
        let icoSource = try Fixture.source(try Fixture.output(of: ico))
        #expect(CGImageSourceGetCount(icoSource) == 7)
        let entries = (0..<CGImageSourceGetCount(icoSource)).compactMap {
            CGImageSourceCreateImageAtIndex(icoSource, $0, nil)
        }
        let largest = try #require(entries.max { $0.width < $1.width })
        #expect(largest.width == 256)
        #expect(largest.width == largest.height)
        #expect(try Fixture.pixel(largest, x: largest.width / 2, y: 2)[3] == 0)

        let set = try await Fixture.run(
            .imageIconSet, preset: "appiconset",
            inputs: [try Fixture.write([wide], as: .png, to: folder.appending(path: "c.png"))])
        let catalog = try Fixture.output(of: set)
        #expect(catalog.lastPathComponent == "c.appiconset")
        let icon = try Fixture.image(catalog.appending(path: "AppIcon.png"))
        #expect(icon.width == 1024 && icon.height == 1024)
        let contents = try JSONSerialization.jsonObject(
            with: Data(contentsOf: catalog.appending(path: "Contents.json")))
        let images = (contents as? [String: Any])?["images"] as? [[String: String]]
        #expect(images?.first?["size"] == "1024x1024")
        #expect(images?.first?["platform"] == "ios")
    }

    @Test func base64UsesTheContentMIMETypeAndRefusesLargeFiles() async throws {
        let folder = try TestVolume.makeFolder()
        let png = try Fixture.write([try Fixture.disc(size: 8)], as: .png, to: folder.appending(path: "tiny.png"))
        let outcome = try await Fixture.run(.imageCopyBase64, preset: nil, inputs: [png])
        let text = try #require(outcome.clipboardText)
        #expect(text.hasPrefix("data:image/png;base64,"))
        #expect(
            Data(base64Encoded: String(text.dropFirst("data:image/png;base64,".count))) == (try Data(contentsOf: png)))

        let large = folder.appending(path: "large.png")
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bytes.append(Data(count: Int(ImageExports.base64Limit)))
        try bytes.write(to: large)
        let refused = try await Fixture.run(.imageCopyBase64, preset: nil, inputs: [large])
        #expect(refused.outcomes == [.failed(.invalidInput(.tooLarge(limitBytes: ImageExports.base64Limit)))])
    }

    @Test func svgInputsRenderWithoutNetworkAccess() async throws {
        let folder = try TestVolume.makeFolder()
        let svg = folder.appending(path: "badge.svg")
        try Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="120" height="80">
            <image xlink:href="https://example.invalid/tracker.png" width="10" height="10"/>
            <rect x="20" y="20" width="80" height="40" fill="#0000ff"/></svg>
            """.utf8
        ).write(to: svg)
        let outcome = try await Fixture.run(.imageConvert, preset: "png", inputs: [svg])
        let output = try Fixture.output(of: outcome)
        #expect(output.lastPathComponent == "badge.png")
        let image = try Fixture.image(output)
        #expect(image.width == 120 && image.height == 80)
        #expect(try Fixture.pixel(image, x: 2, y: 2)[3] == 0)
        #expect(try Fixture.pixel(image, x: 60, y: 40) == [0, 0, 255, 255])
    }

    @Test func svgPixelEditsDeriveAPNGAndKeepTheVector() async throws {
        let folder = try TestVolume.makeFolder()
        let svg = folder.appending(path: "shape.svg")
        try Data(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><circle cx="50" cy="50" r="40"/></svg>"#
                .utf8
        )
        .write(to: svg)
        let outcome = try await Fixture.run(.imageResize, preset: "percent-50", inputs: [svg])
        let output = try Fixture.output(of: outcome)
        #expect(output.lastPathComponent == "shape.png")
        #expect(try Fixture.image(output).width == 100)
        #expect(FileManager.default.fileExists(atPath: svg.path))
    }

    @Test func svgBase64UsesTheSVGMIMEType() async throws {
        let folder = try TestVolume.makeFolder()
        let svg = folder.appending(path: "dot.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#.utf8).write(to: svg)
        let outcome = try await Fixture.run(.imageCopyBase64, preset: nil, inputs: [svg])
        #expect(outcome.clipboardText?.hasPrefix("data:image/svg+xml;base64,") == true)
    }
}
