import AppKit
import CArchive
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import Engine

@MainActor
struct AttributedDocumentTests {
    @Test func importsRichDocumentsToTextAndPDF() throws {
        try withFolder { folder in
            let sample = NSAttributedString(string: "A distinctive document sentence")
            let formats: [(String, NSAttributedString.DocumentType)] = [
                ("docx", .officeOpenXML), ("odt", .openDocument), ("rtf", .rtf),
            ]
            for (extensionName, documentType) in formats {
                let url = folder.appending(path: "sample.\(extensionName)")
                let bytes = try sample.data(
                    from: NSRange(location: 0, length: sample.length),
                    documentAttributes: [.documentType: documentType])
                try bytes.write(to: url)
                try expectTextAndPDF(url, contains: "A distinctive document sentence")
            }

            let rtfd = folder.appending(path: "sample.rtfd")
            let wrapper = try sample.fileWrapper(
                from: NSRange(location: 0, length: sample.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: rtfd, options: .atomic, originalContentsURL: nil)
            try expectTextAndPDF(rtfd, contains: "A distinctive document sentence")
        }
    }

    @Test func pdfContainsTextFromTheLastPage() throws {
        try withFolder { folder in
            let text =
                String(repeating: "A paragraph with enough words to occupy a line.\n", count: 300)
                + "UNIQUE_FINAL_PAGE_MARKER"
            let source = NSAttributedString(string: text)
            let bytes = try source.data(
                from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let url = folder.appending(path: "long.rtf")
            try bytes.write(to: url)
            let pdf = try AttributedDocument.convert(url, toPDF: true)
            let document = try #require(PDFDocument(data: pdf))
            #expect(document.pageCount > 1)
            let lastPage = try #require(document.page(at: document.pageCount - 1))
            #expect(lastPage.string?.contains("UNIQUE_FINAL_PAGE_MARKER") == true)
        }
    }

    @Test func pdfRetainsRTFDAttachmentImage() throws {
        try withFolder { folder in
            let side = 48
            let context = try #require(
                CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let image = try #require(context.makeImage())
            let png = NSMutableData()
            let encoder = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(encoder, image, nil)
            try #require(CGImageDestinationFinalize(encoder))
            let imageWrapper = FileWrapper(regularFileWithContents: png as Data)
            imageWrapper.preferredFilename = "red.png"
            let attachment = NSTextAttachment(fileWrapper: imageWrapper)
            let source = NSMutableAttributedString(string: "Attachment follows\n")
            source.append(NSAttributedString(attachment: attachment))
            source.append(NSAttributedString(string: "\nAttachment precedes this text"))
            let wrapper = try source.fileWrapper(
                from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            let url = folder.appending(path: "image.rtfd")
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            let pdfBytes = try AttributedDocument.convert(url, toPDF: true)
            let document = try #require(PDFDocument(data: pdfBytes))
            #expect(document.string?.contains("Attachment precedes this text") == true)
            let provider = try #require(CGDataProvider(data: pdfBytes as CFData))
            let rasterDocument = try #require(CGPDFDocument(provider))
            let page = try #require(rasterDocument.page(at: 1))
            let bounds = page.getBoxRect(.mediaBox)
            let width = Int(bounds.width)
            let height = Int(bounds.height)
            let channels = 4
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let raster = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * channels,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            raster.setFillColor(CGColor(gray: 1, alpha: 1))
            raster.fill(bounds)
            raster.drawPDFPage(page)
            let pixels = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
            let componentMaximum = Double(UInt8.max)
            var redPixels = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let offset = (y * width + x) * channels
                    if Double(pixels[offset]) / componentMaximum > 0.7,
                        Double(pixels[offset + 1]) / componentMaximum < 0.3,
                        Double(pixels[offset + 2]) / componentMaximum < 0.3
                    {
                        redPixels += 1
                    }
                }
            }
            #expect(redPixels > 0)
        }
    }

    @Test func rejectsMalformedAndOversizedFiles() throws {
        try withFolder { folder in
            let malformed = folder.appending(path: "broken.docx")
            try Data("not a ZIP archive".utf8).write(to: malformed)
            #expect(throws: EngineError.self) { try AttributedDocument.convert(malformed, toPDF: false) }

            let oversized = folder.appending(path: "large.rtf")
            try Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1).write(to: oversized)
            #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: 8 * 1_024 * 1_024))) {
                try AttributedDocument.convert(oversized, toPDF: false)
            }
        }
    }

    @Test func rejectsUnsafeRTFDPackages() throws {
        try withFolder { folder in
            let package = folder.appending(path: "linked.rtfd")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: package.appending(path: "escape"), withDestinationURL: folder)
            #expect(throws: EngineError.invalidInput(.malformed("Document package contains a link or special file"))) {
                try AttributedDocument.convert(package, toPDF: false)
            }

            let oversized = folder.appending(path: "oversized.rtfd")
            try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: false)
            try Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1)
                .write(to: oversized.appending(path: "payload"))
            #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: 32 * 1_024 * 1_024))) {
                try AttributedDocument.convert(oversized, toPDF: false)
            }

            let crowded = folder.appending(path: "crowded.rtfd")
            try FileManager.default.createDirectory(at: crowded, withIntermediateDirectories: false)
            for index in 0...1_024 {
                try Data().write(to: crowded.appending(path: "entry-\(index)"))
            }
            #expect(throws: EngineError.invalidInput(.malformed("Document package has too many entries"))) {
                try AttributedDocument.convert(crowded, toPDF: false)
            }

            let nested = folder.appending(path: "nested.rtfd")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            var child = nested
            for _ in 0...64 {
                child = child.appending(path: "branch")
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            }
            #expect(throws: EngineError.invalidInput(.malformed("Document package is too deeply nested"))) {
                try AttributedDocument.convert(nested, toPDF: false)
            }
        }
    }

    @Test func rejectsCompressedDocumentExpansion() throws {
        try withFolder { folder in
            let source = NSAttributedString(string: String(repeating: "A", count: 33 * 1_024 * 1_024))
            let bytes = try source.data(
                from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            #expect(bytes.count < 8 * 1_024 * 1_024)
            let url = folder.appending(path: "expanded.docx")
            try bytes.write(to: url)
            #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: 32 * 1_024 * 1_024))) {
                try AttributedDocument.convert(url, toPDF: false)
            }
        }
    }

    @Test(arguments: ["../outside.xml", "/outside.xml", "..\\outside.xml"])
    func refusesUnsafeArchivePaths(_ path: String) throws {
        try withFolder { folder in
            let url = folder.appending(path: "unsafe.docx")
            let writer = try #require(archive_write_new())
            defer { archive_write_free(writer) }
            try #require(archive_write_set_format_zip(writer) == ARCHIVE_OK)
            try #require(archive_write_open_filename(writer, url.path) == ARCHIVE_OK)
            let entry = try #require(archive_entry_new())
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, path)
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_size(entry, 0)
            try #require(archive_write_header(writer, entry) == ARCHIVE_OK)
            try #require(archive_write_close(writer) == ARCHIVE_OK)
            #expect(throws: EngineError.invalidInput(.malformed("Document archive contains an unsafe path"))) {
                try AttributedDocument.convert(url, toPDF: false)
            }
        }
    }

    private func expectTextAndPDF(_ url: URL, contains phrase: String) throws {
        let text = try AttributedDocument.convert(url, toPDF: false)
        #expect(String(data: text, encoding: .utf8)?.contains(phrase) == true)
        let pdf = try AttributedDocument.convert(url, toPDF: true)
        let document = try #require(PDFDocument(data: pdf))
        #expect(document.pageCount > 0)
        #expect(document.string?.contains(phrase) == true)
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "MacEaseDocuments-\(UUID().uuidString)")
        TestTemporaryFolders.register(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try body(url)
        try FileManager.default.removeItem(at: url)
    }
}
