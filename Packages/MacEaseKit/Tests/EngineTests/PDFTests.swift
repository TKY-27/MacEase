import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MenuCatalog
import PDFKit
import Testing

@testable import Engine

private let pageBox = CGRect(x: 0, y: 0, width: 200, height: 100)

private func runPDF(
    _ operation: PDFOperation,
    op: OperationID,
    on inputs: [URL],
    settings: Settings = Settings()
) async throws -> BatchOutcome {
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEasePDFSupport-\(UUID().uuidString)")
    let engine = try JobEngine(supportDirectory: support, concurrency: 2)
    let request = OperationRequest(op: op, options: .pdf(operation), inputs: inputs)
    return await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) { _ in }
}

private func font(size: CGFloat) -> CTFont {
    CTFontCreateWithName("Helvetica" as CFString, size, nil)
}

private func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(size: size)]))
    context.textPosition = point
    CTLineDraw(line, context)
}

/// Pixels only, so no text layer.
private func scannedImage(of text: String) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    draw(text, in: context, at: CGPoint(x: 40, y: 160), size: 96)
    return try #require(context.makeImage())
}

/// Noise shrinks only when recoded.
private func noiseImage() throws -> CGImage {
    let side = 1200
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    var seed: UInt32 = 1
    for index in 0..<(context.bytesPerRow * side) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    return try #require(context.makeImage())
}

private enum PageContent {
    case text(String)
    case scan(String)
    case noise
}

private func makePDF(_ name: String, pages: [PageContent], in folder: URL? = nil) throws -> URL {
    let url = try (folder ?? TestVolume.makeFolder()).appending(path: name)
    var box = pageBox
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for page in pages {
        context.beginPDFPage(nil)
        switch page {
        case .text(let text): draw(text, in: context, at: CGPoint(x: 20, y: 40), size: 24)
        case .scan(let text): context.draw(try scannedImage(of: text), in: pageBox)
        case .noise: context.draw(try noiseImage(), in: pageBox)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func texts(of url: URL) throws -> [String] {
    let document = try #require(PDFDocument(url: url))
    return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
}

private func size(of url: URL) throws -> Int {
    try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
}

private func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return (image.width, image.height)
}

@Suite(.serialized) struct PDFTests {
    @Test func presetsMapToOperations() {
        let settings = Settings()
        #expect(OperationPlanner.options(for: .pdfMerge, preset: nil, settings: settings) == .pdf(.merge(pages: nil)))
        #expect(
            OperationPlanner.options(for: .pdfToImages, preset: "jpeg", settings: settings)
                == .pdf(.toImages(.jpeg, dpi: 144)))
        #expect(OperationPlanner.options(for: .pdfToImages, preset: nil, settings: settings) == nil)
        #expect(
            OperationPlanner.options(for: .pdfRotate, preset: "left-90", settings: settings)
                == .pdf(.rotate(degrees: 270)))
        #expect(OperationPlanner.options(for: .pdfExtractPages, preset: nil, settings: settings) == nil)
        #expect(OperationPlanner.options(for: .pdfSplit, preset: nil, settings: settings) == .pdf(.split))
        #expect(OperationPlanner.options(for: .pdfAIRename, preset: nil, settings: settings) == nil)
    }

    @Test func mergeKeepsFinderOrder() async throws {
        let folder = try TestVolume.makeFolder()
        let second = try makePDF("b.pdf", pages: [.text("B1")], in: folder)
        let first = try makePDF("a.pdf", pages: [.text("A1"), .text("A2")], in: folder)

        let outcome = try await runPDF(.merge(pages: nil), op: .pdfMerge, on: [second, first])

        let merged = folder.appending(path: "b (merged).pdf")
        #expect(outcome.outcomes == [.succeeded(outputs: [merged], warnings: [])])
        #expect(try texts(of: merged) == ["B1", "A1", "A2"])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func mergeFollowsThePanelPageOrder() async throws {
        let folder = try TestVolume.makeFolder()
        let first = try makePDF("a.pdf", pages: [.text("A1"), .text("A2")], in: folder)
        let second = try makePDF("b.pdf", pages: [.text("B1")], in: folder)
        let order = [PDFPageReference(file: second, pageIndex: 0), PDFPageReference(file: first, pageIndex: 1)]

        let outcome = try await runPDF(.merge(pages: order), op: .pdfMerge, on: [first, second])

        let merged = folder.appending(path: "a (merged).pdf")
        #expect(outcome.outcomes == [.succeeded(outputs: [merged], warnings: [])])
        #expect(try texts(of: merged) == ["B1", "A2"])
    }

    @Test func mergeNeedsTwoFiles() async throws {
        let only = try makePDF("only.pdf", pages: [.text("x")])

        let outcome = try await runPDF(.merge(pages: nil), op: .pdfMerge, on: [only])

        #expect(outcome.outcomes == [.failed(.invalidInput(.tooFewFiles(minimum: 2)))])
    }

    @Test func toImagesRendersEveryPageAtTheRequestedDPI() async throws {
        let url = try makePDF("deck.pdf", pages: [.text("one"), .text("two")])
        let rotated = try #require(PDFDocument(url: url))
        rotated.page(at: 1)?.rotation = 90
        #expect(rotated.write(to: url))

        let png = try await runPDF(.toImages(.png, dpi: 144), op: .pdfToImages, on: [url])
        let folder = url.deletingPathExtension()
        #expect(png.outcomes == [.succeeded(outputs: [folder], warnings: [])])
        let pngSizes = try ["deck 1.png", "deck 2.png"].map { try pixelSize(of: folder.appending(path: $0)) }
        let jpeg = try await runPDF(.toImages(.jpeg, dpi: 72), op: .pdfToImages, on: [url])
        let jpegFolder = url.deletingLastPathComponent().appending(path: "deck (2)")

        #expect(pngSizes.map(\.width) == [400, 200])
        #expect(pngSizes.map(\.height) == [200, 400])
        #expect(jpeg.outcomes == [.succeeded(outputs: [jpegFolder], warnings: [])])
        #expect(try pixelSize(of: jpegFolder.appending(path: "deck 1.jpg")) == (200, 100))
    }

    @Test(.requires(.textRecognition) { await TextRecognition.isAvailable })
    func toTextSeparatesPagesWithFormFeedsAndRecognizesScans() async throws {
        let url = try makePDF("mixed.pdf", pages: [.text("Alpha"), .scan("HELLO 42"), .text("Gamma")])

        let outcome = try await runPDF(.toText, op: .pdfToText, on: [url])

        let output = url.deletingPathExtension().appendingPathExtension("txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        let pages = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\u{0C}")
        #expect(pages.count == 3)
        #expect(pages.first == "Alpha")
        #expect(pages.last == "Gamma")
        #expect(pages[1].contains("HELLO 42"))
    }

    @Test(.requires(.textRecognition) { await TextRecognition.isAvailable })
    func toTextFailsWhenNoPageHasText() async throws {
        let url = try makePDF("blank.pdf", pages: [.text(""), .text("")])

        let outcome = try await runPDF(.toText, op: .pdfToText, on: [url])

        #expect(outcome.outcomes == [.failed(.invalidInput(.emptyInput))])
    }

    @Test func compressKeepsTheResultOnlyWhenSmaller() async throws {
        let heavy = try makePDF("photo.pdf", pages: [.noise])
        let light = try makePDF("plain.pdf", pages: [.text("tiny")])
        let heavySize = try size(of: heavy)
        let lightBytes = try Data(contentsOf: light)

        let outcome = try await runPDF(.compress, op: .pdfCompress, on: [heavy, light])

        #expect(outcome.outcomes == [.succeeded(outputs: [heavy], warnings: []), .skipped(.outputNotSmaller)])
        #expect(try size(of: heavy) < heavySize / 2)
        #expect(PDFDocument(url: heavy)?.pageCount == 1)
        #expect(try Data(contentsOf: light) == lightBytes)
    }

    @Test func rotateTurnsEveryPage() async throws {
        let url = try makePDF("turn.pdf", pages: [.text("1"), .text("2"), .text("3")])

        let outcome = try await runPDF(.rotate(degrees: 270), op: .pdfRotate, on: [url])

        #expect(outcome.outcomes == [.succeeded(outputs: [url], warnings: [])])
        let document = try #require(PDFDocument(url: url))
        #expect((0..<document.pageCount).map { document.page(at: $0)?.rotation } == [270, 270, 270])
    }

    @Test func extractPagesKeepsTheChosenPages() async throws {
        let url = try makePDF("long.pdf", pages: [.text("P1"), .text("P2"), .text("P3")])

        let outcome = try await runPDF(.extractPages(IndexSet([0, 2])), op: .pdfExtractPages, on: [url])
        let none = try await runPDF(.extractPages(IndexSet()), op: .pdfExtractPages, on: [url])
        let missing = try await runPDF(.extractPages(IndexSet([5])), op: .pdfExtractPages, on: [url])

        let output = url.deletingLastPathComponent().appending(path: "long (extracted).pdf")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try texts(of: output) == ["P1", "P3"])
        #expect(none.outcomes == [.failed(.invalidInput(.noPages))])
        #expect(missing.outcomes == [.failed(.unexpected("page index out of range"))])
    }

    @Test func splitWritesOnePDFPerPage() async throws {
        let pages = (1...10).map { PageContent.text("S\($0)") }
        let url = try makePDF("book.pdf", pages: pages)

        let outcome = try await runPDF(.split, op: .pdfSplit, on: [url])

        let folder = url.deletingPathExtension()
        #expect(outcome.outcomes == [.succeeded(outputs: [folder], warnings: [])])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.count == 10)
        #expect(files.first == "book 01.pdf")
        #expect(try texts(of: folder.appending(path: "book 10.pdf")) == ["S10"])
    }

    @Test func encryptedPDFsFailClearly() async throws {
        let url = try makePDF("locked.pdf", pages: [.text("secret")])
        let document = try #require(PDFDocument(url: url))
        #expect(document.write(to: url, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "user"]))
        let ownerOnly = try makePDF("restricted.pdf", pages: [.text("restricted")])
        #expect(
            try #require(PDFDocument(url: ownerOnly)).write(to: ownerOnly, withOptions: [.ownerPasswordOption: "owner"])
        )
        let lockedBytes = try Data(contentsOf: url)

        let outcome = try await runPDF(.rotate(degrees: 90), op: .pdfRotate, on: [url, ownerOnly])

        #expect(outcome.outcomes == [.failed(.invalidInput(.encrypted)), .failed(.invalidInput(.encrypted))])
        #expect(try Data(contentsOf: url) == lockedBytes)
    }
}
