import Foundation
import PDFKit
import Testing

@testable import Engine

@Suite(.serialized) @MainActor struct HTMLDocumentTests {
    @Test func pageScriptsCannotChangeText() async throws {
        let source = URL(fileURLWithPath: "/private/tmp/source.html")
        let html =
            "<p id='proof'>Before script 日本語</p><script>document.getElementById('proof').textContent='Executed';</script>"
        let bytes = try await HTMLDocument.convert(html, source: source, toPDF: false)
        #expect(
            String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "Before script 日本語")
    }

    @Test func rendersPDFWithSearchableText() async throws {
        let bytes = try await HTMLDocument.convert(
            "<html><body><h1>Local document</h1><p>Last paragraph</p></body></html>",
            source: URL(fileURLWithPath: "/private/tmp/source.html"), toPDF: true)
        let document = try #require(PDFDocument(data: bytes))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("Local document") == true)
        #expect(document.string?.contains("Last paragraph") == true)
    }

    @Test func loadsLocalStylesButBlocksExternalStyles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseHTML-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(".local { display:none }".utf8).write(to: directory.appending(path: "style.css"))
        let html = """
            <link rel="stylesheet" href="style.css">
            <link rel="stylesheet" href="data:text/css,p%20%7B%20display%3Anone%20%7D">
            <p class="local">Hidden locally</p><p>Visible offline</p>
            """
        let bytes = try await HTMLDocument.convert(html, source: directory.appending(path: "source.html"), toPDF: false)
        #expect(
            String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Visible offline")
        try FileManager.default.removeItem(at: directory)
    }

    @Test func rejectsLocalResourcesOutsideSourceFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseHTML-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "outside.css"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        await #expect(throws: EngineError.self) {
            try await HTMLDocument.convert(
                "<link rel='stylesheet' href='outside.css'><p>Text</p>",
                source: directory.appending(path: "source.html"), toPDF: false)
        }
        try FileManager.default.removeItem(at: directory)
    }

    @Test func refusesOversizedLayoutInsteadOfClipping() async throws {
        await #expect(throws: EngineError.invalidInput(.malformed("HTML layout exceeds the PDF size limit"))) {
            try await HTMLDocument.convert(
                "<div style='height:30000px'>Too tall</div>",
                source: URL(fileURLWithPath: "/private/tmp/source.html"), toPDF: true)
        }
    }

    @Test func alreadyCancelledRequestDoesNotRender() async {
        let request = Task {
            return try await HTMLDocument.convert(
                "<p>Cancelled</p>", source: URL(fileURLWithPath: "/private/tmp/a.html"), toPDF: true)
        }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
    }
}
