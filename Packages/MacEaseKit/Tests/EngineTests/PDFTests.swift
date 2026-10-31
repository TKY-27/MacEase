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
    var settings = settings
    settings.outputMode = .replace
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEasePDFSupport-\(UUID().uuidString)")
    TestTemporaryFolders.register(support)
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

extension OutputModeTests {
    @Test(arguments: [
        (PDFOperation.rotate(degrees: 90), OperationID.pdfRotate, "paper_rotated.pdf"),
        (.compress, .pdfCompress, "paper_compressed.pdf"),
    ])
    func pdfEditsKeepOriginal(operation: PDFOperation, op: OperationID, name: String) async throws {
        let source = try makePDF("paper.pdf", pages: [.noise])
        let request = OperationRequest(op: op, options: .pdf(operation), inputs: [source])
        try await verifyNewFile(request, named: name) { output in
            let document = try #require(PDFDocument(url: output))
            #expect(document.pageCount == 1)
            if op == .pdfRotate {
                #expect(document.page(at: 0)?.rotation == 90)
            } else {
                #expect(try size(of: output) < size(of: source))
            }
        }
    }
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

    @Test func toImagesStreamsA3AndA2PagesAt300DPI() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "paper.pdf")
        let boxes =
            Array(repeating: CGRect(x: 0, y: 0, width: 842, height: 1_191), count: 4)
            + [CGRect(x: 0, y: 0, width: 1_191, height: 1_684)]
        let writer = try #require(CGContext(source as CFURL, mediaBox: nil, nil))
        for var box in boxes {
            writer.beginPage(mediaBox: &box)
            writer.endPage()
        }
        writer.closePDF()
        let original = try Data(contentsOf: source)
        let outcome = try await runPDF(.toImages(.png, dpi: 300), op: .pdfToImages, on: [source])
        let output = source.deletingPathExtension()
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        for index in boxes.indices {
            let page = output.appending(path: "paper \(index + 1).png")
            let properties = try ImageFixtures.properties(page)
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == (index < 4 ? 3_508 : 4_963))
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == (index < 4 ? 4_963 : 7_017))
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func toImagesRejectsAnOversizedPageBeforeRendering() async throws {
        let folder = try TestVolume.makeFolder()
        let url = folder.appending(path: "large-pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let writer = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            writer.beginPDFPage(nil)
            writer.endPDFPage()
        }
        writer.closePDF()
        let original = try Data(contentsOf: url)

        let outcome = try await runPDF(.toImages(.png, dpi: 144), op: .pdfToImages, on: [url])

        #expect(outcome.outcomes == [.failed(.invalidInput(.frameMemoryExceeded))])
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "large-pages").path))
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

    @Test func ownerPasswordOnlyPDFAllowsDerivedOperations() async throws {
        let folder = try TestVolume.makeFolder()
        let url = try makePDF("owner.pdf", pages: [.text("First"), .text("Second")], in: folder)
        let companion = try makePDF("companion.pdf", pages: [.text("Third")], in: folder)
        #expect(try #require(PDFDocument(url: url)).write(to: url, withOptions: [.ownerPasswordOption: "owner"]))
        let source = try #require(PDFDocument(url: url))
        #expect(source.isEncrypted && !source.isLocked && source.allowsCopying && source.allowsPrinting)
        let original = try Data(contentsOf: url)

        let merged = try await runPDF(.merge(pages: nil), op: .pdfMerge, on: [url, companion])
        let images = try await runPDF(.toImages(.png, dpi: 72), op: .pdfToImages, on: [url])
        let text = try await runPDF(.toText, op: .pdfToText, on: [url])
        let extracted = try await runPDF(.extractPages(IndexSet([1])), op: .pdfExtractPages, on: [url])
        let split = try await runPDF(.split, op: .pdfSplit, on: [url])

        let mergedURL = folder.appending(path: "owner (merged).pdf")
        let imageFolder = folder.appending(path: "owner")
        let textURL = folder.appending(path: "owner.txt")
        let extractedURL = folder.appending(path: "owner (extracted).pdf")
        let splitFolder = folder.appending(path: "owner (2)")
        #expect(merged.outcomes == [.succeeded(outputs: [mergedURL], warnings: [])])
        #expect(images.outcomes == [.succeeded(outputs: [imageFolder], warnings: [])])
        #expect(text.outcomes == [.succeeded(outputs: [textURL], warnings: [])])
        #expect(extracted.outcomes == [.succeeded(outputs: [extractedURL], warnings: [])])
        #expect(split.outcomes == [.succeeded(outputs: [splitFolder], warnings: [])])
        #expect(try texts(of: mergedURL) == ["First", "Second", "Third"])
        #expect(try pixelSize(of: imageFolder.appending(path: "owner 1.png")) == (200, 100))
        #expect(try String(contentsOf: textURL, encoding: .utf8) == "First\u{0C}Second")
        #expect(try texts(of: extractedURL) == ["Second"])
        #expect(try texts(of: splitFolder.appending(path: "owner 2.pdf")) == ["Second"])
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func derivedOperationsHonorPDFPermissions() async throws {
        let folder = try TestVolume.makeFolder()
        let printOnly = try makePDF("print.pdf", pages: [.text("Printable")], in: folder)
        let copyOnly = try makePDF("copy.pdf", pages: [.text("Copyable")], in: folder)
        #expect(
            try #require(PDFDocument(url: printOnly)).write(
                to: printOnly,
                withOptions: [
                    .ownerPasswordOption: "owner",
                    .accessPermissionsOption: PDFAccessPermissions.allowsLowQualityPrinting.rawValue,
                ]))
        #expect(
            try #require(PDFDocument(url: copyOnly)).write(
                to: copyOnly,
                withOptions: [
                    .ownerPasswordOption: "owner",
                    .accessPermissionsOption: PDFAccessPermissions.allowsContentCopying.rawValue,
                ]))
        let printable = try #require(PDFDocument(url: printOnly))
        let copyable = try #require(PDFDocument(url: copyOnly))
        #expect(!printable.isLocked && !printable.allowsCopying && printable.allowsPrinting)
        #expect(!copyable.isLocked && copyable.allowsCopying && !copyable.allowsPrinting)

        let imagesAllowed = try await runPDF(.toImages(.png, dpi: 72), op: .pdfToImages, on: [printOnly])
        let imagesDenied = try await runPDF(.toImages(.png, dpi: 72), op: .pdfToImages, on: [copyOnly])
        let textDenied = try await runPDF(.toText, op: .pdfToText, on: [printOnly])
        let textAllowed = try await runPDF(.toText, op: .pdfToText, on: [copyOnly])
        let mergeDenied = try await runPDF(.merge(pages: nil), op: .pdfMerge, on: [copyOnly, printOnly])
        let extractDenied = try await runPDF(.extractPages(IndexSet([0])), op: .pdfExtractPages, on: [printOnly])
        let splitDenied = try await runPDF(.split, op: .pdfSplit, on: [printOnly])

        #expect(imagesAllowed.outcomes == [.succeeded(outputs: [folder.appending(path: "print")], warnings: [])])
        #expect(imagesDenied.outcomes == [.failed(.invalidInput(.pdfPrintingNotAllowed))])
        #expect(textDenied.outcomes == [.failed(.invalidInput(.pdfCopyingNotAllowed))])
        #expect(textAllowed.outcomes == [.succeeded(outputs: [folder.appending(path: "copy.txt")], warnings: [])])
        #expect(mergeDenied.outcomes == [.failed(.invalidInput(.pdfCopyingNotAllowed))])
        #expect(extractDenied.outcomes == [.failed(.invalidInput(.pdfCopyingNotAllowed))])
        #expect(splitDenied.outcomes == [.failed(.invalidInput(.pdfCopyingNotAllowed))])
        #expect(try String(contentsOf: folder.appending(path: "copy.txt"), encoding: .utf8) == "Copyable")
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
        let derived = try await runPDF(.split, op: .pdfSplit, on: [url])

        #expect(outcome.outcomes == [.failed(.invalidInput(.encrypted)), .failed(.invalidInput(.encrypted))])
        #expect(derived.outcomes == [.failed(.invalidInput(.encrypted))])
        #expect(try Data(contentsOf: url) == lockedBytes)
    }
}

@Suite(.serialized) struct PDFPageEditTests {
    private func request(_ source: URL, order: [Int], stamp: FileStamp) -> OperationRequest {
        OperationRequest(
            op: .pdfEditPages, options: .pdf(.editPages(order: order, sourceStamp: stamp)), inputs: [source])
    }

    private func navigationFixture() throws -> URL {
        let source = try TestVolume.makeFolder().appending(path: "editable.pdf")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 12 0 R /AcroForm 15 0 R >>",
            "<< /Type /Pages /Count 3 /Kids [3 0 R 5 0 R 7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 9 0 R >> >> /Contents 4 0 R >>",
            "<< /Length 36 >>\nstream\nBT /F1 24 Tf 20 40 Td (Alpha) Tj ET\nendstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 9 0 R >> >> /Contents 6 0 R >>",
            "<< /Length 38 >>\nstream\nBT /F1 24 Tf 20 40 Td (Deleted) Tj ET\nendstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 9 0 R >> >> /Contents 8 0 R /Annots [10 0 R 11 0 R 13 0 R] >>",
            "<< /Length 36 >>\nstream\nBT /F1 24 Tf 20 40 Td (Gamma) Tj ET\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Keep this note) /P 7 0 R >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Customer) /V (Ada) /Rect [30 10 110 30] /P 7 0 R /DA (/F1 12 Tf 0 g) >>",
            "<< /Type /Outlines /First 14 0 R /Last 14 0 R /Count 1 >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 40 90 60] /A << /S /GoTo /D [3 0 R /XYZ 20 40 0] >> >>",
            "<< /Title (Alpha chapter) /Parent 12 0 R /Dest [3 0 R /XYZ 20 40 0] >>",
            "<< /Fields [11 0 R] /DR << /Font << /F1 9 0 R >> >> /DA (/F1 12 Tf 0 g) >>",
        ]
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xrefOffset = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try bytes.write(to: source)
        return source
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func preservesPageContentAnnotationsFormsAndNavigation(mode: Settings.OutputMode) async throws {
        let source = try navigationFixture()
        let savedFixture = try #require(PDFDocument(url: source))
        #expect(savedFixture.outlineRoot?.child(at: 0)?.label == "Alpha chapter")
        #expect(savedFixture.page(at: 2)?.annotations.count == 3)
        #expect(
            savedFixture.page(at: 2)?.annotations.first(where: { $0.fieldName == "Customer" })?.widgetStringValue
                == "Ada")
        let original = try Data(contentsOf: source)
        let session = try PDFPageEditSession.open(source)
        let engine = try ImageFixtures.engine()
        var settings = Settings()
        settings.outputMode = mode
        let outcome = await engine.run(
            OperationPlanner.batch(
                for: request(source, order: [2, 0], stamp: session.sourceStamp), settings: settings),
            settings: settings
        ) { _ in }
        let output = try ImageFixtures.output(of: outcome)
        #expect(
            output
                == (mode == .replace
                    ? source : source.deletingLastPathComponent().appending(path: "editable_edited.pdf")))
        #expect(try texts(of: output) == ["Gamma", "Alpha"])
        let exported = try #require(PDFDocument(url: output))
        let editedFirst = try #require(exported.page(at: 0))
        #expect(editedFirst.annotations.first(where: { $0.type == "Text" })?.contents == "Keep this note")
        #expect(editedFirst.annotations.first(where: { $0.fieldName == "Customer" })?.widgetStringValue == "Ada")
        let target = try #require(
            (editedFirst.annotations.first(where: { $0.type == "Link" })?.action as? PDFActionGoTo)?.destination.page)
        #expect(exported.index(for: target) == 1)
        let outlineTarget = try #require(exported.outlineRoot?.child(at: 0)?.destination?.page)
        #expect(exported.index(for: outlineTarget) == 1)
        #expect(exported.outlineRoot?.child(at: 0)?.label == "Alpha chapter")
        if mode == .newFile { #expect(try Data(contentsOf: source) == original) }
        #expect(try await engine.undo(outcome.batchID) == [.restored])
        #expect(try Data(contentsOf: source) == original)
        if mode == .newFile { #expect(!FileManager.default.fileExists(atPath: output.path)) }
    }

    @Test func removingNavigationTargetKeepsSurvivingPageAndOutlineLabel() async throws {
        let source = try navigationFixture()
        let session = try PDFPageEditSession.open(source)
        let engine = try ImageFixtures.engine()
        let settings = Settings()
        let outcome = await engine.run(
            OperationPlanner.batch(for: request(source, order: [2], stamp: session.sourceStamp), settings: settings),
            settings: settings
        ) { _ in }
        let output = try ImageFixtures.output(of: outcome)
        let document = try #require(PDFDocument(url: output))
        #expect(try texts(of: output) == ["Gamma"])
        #expect(document.outlineRoot?.child(at: 0)?.label == "Alpha chapter")
        #expect(document.outlineRoot?.child(at: 0)?.destination == nil)
        let link = try #require(document.page(at: 0)?.annotations.first(where: { $0.type == "Link" }))
        #expect(link.destination == nil)
        #expect(link.action == nil)
    }

    @Test func refusesReplacedSourceWithMatchingSizeAndModificationTime() async throws {
        let source = try makePDF("identity.pdf", pages: [.text("One"), .text("Two")])
        let session = try PDFPageEditSession.open(source)
        let original = try Data(contentsOf: source)
        let modified = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let replacement = source.deletingLastPathComponent().appending(path: "replacement.pdf")
        try original.write(to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: try #require(modified)], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: replacement, to: source)
        let engine = try ImageFixtures.engine()
        let settings = Settings()
        let outcome = await engine.run(
            OperationPlanner.batch(
                for: request(source, order: [1, 0], stamp: session.sourceStamp), settings: settings),
            settings: settings
        ) { _ in }
        #expect(outcome.outcomes == [.failed(.invalidInput(.malformed("The PDF changed. Reopen the page editor.")))])
        #expect(try Data(contentsOf: source) == original)
        #expect(
            !FileManager.default.fileExists(
                atPath: source.deletingLastPathComponent().appending(path: "identity_edited.pdf").path))
    }

    @Test(arguments: [[], [0, 0], [5]])
    func refusesInvalidOrders(order: [Int]) async throws {
        let source = try makePDF("invalid.pdf", pages: [.text("One"), .text("Two")])
        let session = try PDFPageEditSession.open(source)
        let original = try Data(contentsOf: source)
        let outcome = try await runPDF(
            .editPages(order: order, sourceStamp: session.sourceStamp), op: .pdfEditPages, on: [source])
        let expected: EngineError =
            order.isEmpty ? .invalidInput(.noPages) : .invalidInput(.malformed("Invalid PDF page order."))
        #expect(outcome.outcomes == [.failed(expected)])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func unchangedOrderDoesNotWrite() async throws {
        let source = try makePDF("unchanged.pdf", pages: [.text("One"), .text("Two")])
        let session = try PDFPageEditSession.open(source)
        let original = try Data(contentsOf: source)
        let outcome = try await runPDF(
            .editPages(order: [0, 1], sourceStamp: session.sourceStamp), op: .pdfEditPages, on: [source])
        #expect(outcome.outcomes == [.skipped(.alreadyDone)])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func refusesProtectedPDFsAtEditorOpening() throws {
        let source = try makePDF("protected.pdf", pages: [.text("One"), .text("Two")])
        let document = try #require(PDFDocument(url: source))
        #expect(document.write(to: source, withOptions: [.ownerPasswordOption: "owner"]))
        #expect(throws: EngineError.invalidInput(.encrypted)) { try PDFPageEditSession.open(source) }
        #expect(
            document.write(to: source, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
        #expect(throws: EngineError.invalidInput(.encrypted)) { try PDFPageEditSession.open(source) }
    }
}
