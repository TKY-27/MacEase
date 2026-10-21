import Foundation
import MenuCatalog
import PDFKit
import Testing

@testable import Engine

@Suite(.serialized) struct MarkdownConversionTests {
    @Test func rendersGitHubFlavoredMarkdown() throws {
        let markdown = """
            # Title & more

            | Name | Done |
            | --- | --- |
            | ~~old~~ | yes |

            - [x] shipped
            - [ ] pending

            Visit https://example.com today.[^1]

            [^1]: Footnote text.
            """
        let html = try MarkdownConversion.html(markdown, title: "<Notes>")
        #expect(html.contains("<title>&lt;Notes&gt;</title>"))
        #expect(html.contains("<h1>Title &amp; more</h1>"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<del>old</del>"))
        #expect(html.contains(#"type="checkbox" checked="" disabled="""#))
        #expect(html.contains(#"<a href="https://example.com">"#))
        #expect(html.contains("Footnote text."))
    }

    @Test func omitsScriptsRawHTMLAndUnsafeLinks() throws {
        let markdown = """
            <script>document.body.innerHTML = 'Executed'</script>

            Visible <img src=x onerror="alert(1)"> [link](javascript:alert(1))
            """
        let html = try MarkdownConversion.html(markdown, title: "doc")
        #expect(!html.contains("<script"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("Visible"))
    }

    @Test @MainActor func scriptsNeverRunInRenderedOutput() async throws {
        let html = try MarkdownConversion.html(
            "<script>document.body.textContent = 'Executed'</script>\n\nVisible text", title: "doc")
        let source = URL(fileURLWithPath: "/private/tmp/source.md")
        let text = try await HTMLDocument.convert(html, source: source, toPDF: false)
        #expect(String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Visible text")
        let pdf = try #require(
            PDFDocument(data: try await HTMLDocument.convert(html, source: source, toPDF: true)))
        #expect(pdf.string?.contains("Visible text") == true)
        #expect(pdf.string?.contains("Executed") == false)
    }

    @Test func boundsInputAndExpandedOutput() {
        let limit = Int64(MarkdownConversion.maximumBytes)
        #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: limit))) {
            try MarkdownConversion.html(String(repeating: "a", count: MarkdownConversion.maximumBytes + 1), title: "")
        }
        let quotes = String(repeating: ">", count: MarkdownConversion.maximumBytes / 2)
        #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))) {
            try MarkdownConversion.html(quotes, title: "")
        }
    }

    @Test(arguments: [
        ("source.md", "# Heading\n\n<b>raw</b> text\n", TextConversion.markdownToPDF, "source.pdf", "%PDF"),
        ("source.md", "# Heading\n", .markdownToHTML, "source.html", "<h1>Heading</h1>"),
        ("source.yaml", "a: 1\n", .yamlToJSON, "source.json", #""a": 1"#),
        ("source.json", #"{"a":1}"#, .jsonToYAML, "source.yaml", "a: 1\n"),
        ("source.toml", "a = 1\n", .tomlToJSON, "source.json", #""a": 1"#),
        ("source.json", #"{"a":1}"#, .jsonToTOML, "source.toml", "a = 1"),
    ])
    func exportsStayDerivedEvenInReplaceMode(
        name: String, content: String, conversion: TextConversion, output: String, expected: String
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: name)
        try Data(content.utf8).write(to: source)
        var settings = Settings()
        settings.outputMode = .replace
        let outcome = try await run(conversion, on: source, settings: settings, in: directory)
        guard case .succeeded(let outputs, let warnings) = outcome else {
            Issue.record("Conversion failed: \(outcome)")
            return
        }
        let written = try #require(outputs.first)
        #expect(outputs.map(\.lastPathComponent) == [output])
        #expect(String(decoding: try Data(contentsOf: written), as: UTF8.self).contains(expected))
        #expect(try Data(contentsOf: source) == Data(content.utf8))
        switch conversion {
        case .markdownToPDF: #expect(warnings == [.markdownUnsafeContentOmitted, .htmlOfflineContent])
        case .markdownToHTML: #expect(warnings == [.markdownUnsafeContentOmitted])
        default: #expect(warnings == [.structuredTextFormattingLost])
        }
    }

    @Test(arguments: [
        ("large.toml", TextConversion.tomlToJSON, TOMLConversion.maximumBytes),
        ("large.json", .jsonToTOML, TOMLConversion.maximumBytes),
        ("large.md", .markdownToHTML, MarkdownConversion.maximumBytes),
    ])
    func oversizedInputsAreRefusedWhileReading(name: String, conversion: TextConversion, limit: Int) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: name)
        try Data(repeating: UInt8(ascii: " "), count: limit + 1).write(to: source)
        let outcome = try await run(conversion, on: source, settings: Settings(), in: directory)
        #expect(outcome == .failed(.invalidInput(.tooLarge(limitBytes: Int64(limit)))))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseText-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(_ conversion: TextConversion, on source: URL, settings: Settings, in directory: URL) async throws
        -> ItemOutcome?
    {
        let engine = try JobEngine(supportDirectory: directory.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(op: .textConvert, options: .text(.convert(conversion)), inputs: [source])
        let result = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        return result.outcomes.first
    }
}
