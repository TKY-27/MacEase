import Engine
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import MacEase

final class PreviewContentTests: XCTestCase {
    func testSpecializedTypesPrecedeTextAndGenericImages() {
        let cases: [(UTType?, String, PreviewKind)] = [
            (.html, "html", .html), (.json, "json", .json), (.xml, "xml", .text),
            (.propertyList, "plist", .propertyList), (.pdf, "pdf", .pdf), (.png, "png", .image),
            (.audio, "wav", .audio), (.movie, "mov", .media), (.sourceCode, "swift", .text),
            (.plainText, "txt", .text), (.plainText, "MD", .markdown), (.svg, "svg", .svg), (nil, "yaml", .text),
            (nil, "toml", .text), (nil, "csv", .text), (nil, "LOG", .text), (nil, "unknown", .quickLook),
        ]
        for (type, suffix, expected) in cases {
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix), expected, suffix)
        }
    }

    func testFoldersAndPackagesUseTheSystemPreviewWhateverTheirName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for name in ["Folder", "notes.md", "Archive.pdf", "Sample.app", "Report.rtfd"] {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            XCTAssertEqual(try PreviewKind.inspect(folder), .quickLook, name)
        }
        let document = directory.appendingPathComponent("notes.md")
            .appendingPathComponent("inside.md")
        try Data("# Title".utf8).write(to: document)
        XCTAssertEqual(try PreviewKind.inspect(document), .markdown)
        XCTAssertThrowsError(try PreviewKind.inspect(directory.appendingPathComponent("missing.txt")))
    }

    func testReadLimitKeepsFourMiBButExcerptsLargerFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.txt")
        for size in [0, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1] {
            try Data(repeating: 65, count: size).write(to: url)
            let source = try PreviewTextSource.read(url)
            XCTAssertEqual(source.bytes.count, size > 4 * 1024 * 1024 ? 256 * 1024 : size)
            XCTAssertEqual(source.truncated, size > 4 * 1024 * 1024)
            XCTAssertTrue(source.bytes.allSatisfy { $0 == 65 })
        }
    }

    func testEncodingPickerRedecodesOriginalBytesWithoutLossyReplacement() throws {
        let source = PreviewTextSource(bytes: Data([0xC3, 0xA9]), truncated: false)
        XCTAssertEqual(try source.decoded(as: .automatic), "é")
        XCTAssertEqual(try source.decoded(as: .utf8), "é")
        XCTAssertEqual(try source.decoded(as: .windows1252), "Ã©")
        XCTAssertEqual(source.bytes, Data([0xC3, 0xA9]))
        let japanese = PreviewTextSource(bytes: Data([0x93, 0xFA, 0x96, 0x7B]), truncated: false)
        XCTAssertEqual(try japanese.decoded(as: .shiftJIS), "日本")
        XCTAssertThrowsError(try japanese.decoded(as: .utf8))
        XCTAssertEqual(try PreviewEncoding.automatic.decode(Data([0xFF, 0xFE, 0x41, 0x00])), "A")
        XCTAssertEqual(
            try PreviewTextSource(bytes: Data([0x97, 0xD1]), truncated: true).decoded(as: .automatic), "林")
    }

    func testOnlyAnExcerptMayOmitAnIncompleteTrailingCharacter() throws {
        let bytes = Data([0x41, 0xE3, 0x81])
        XCTAssertEqual(try PreviewTextSource(bytes: bytes, truncated: true).decoded(as: .utf8), "A")
        XCTAssertThrowsError(try PreviewTextSource(bytes: bytes, truncated: false).decoded(as: .utf8))
        XCTAssertThrowsError(try PreviewTextSource(bytes: Data([0x41, 0xFF]), truncated: true).decoded(as: .utf8))
        XCTAssertEqual(try PreviewTextSource(bytes: bytes, truncated: true).decoded(as: .automatic), "A")
        XCTAssertEqual(
            try PreviewTextSource(bytes: Data([0x41, 0, 0x3D, 0xD8]), truncated: true).decoded(as: .utf16LE), "A")
        XCTAssertEqual(try PreviewTextSource(bytes: Data([0x41, 0x93]), truncated: true).decoded(as: .shiftJIS), "A")
        XCTAssertThrowsError(try PreviewTextSource(bytes: Data([0xFF, 0x41]), truncated: true).decoded(as: .utf8))
        let oddUTF16 = Data([0xFF, 0xFE, 0x41, 0, 0xBC])
        XCTAssertThrowsError(try PreviewTextSource(bytes: oddUTF16, truncated: false).decoded(as: .automatic))
        XCTAssertThrowsError(try PreviewTextSource(bytes: oddUTF16, truncated: false).decoded(as: .utf16LE))
        XCTAssertEqual(try PreviewTextSource(bytes: oddUTF16, truncated: true).decoded(as: .automatic), "A")
    }

    func testTokenizerRecognizesSmallSamplesForEverySupportedLanguage() throws {
        let cases: [(PreviewLanguage, String, String, PreviewToken.Kind)] = [
            (.swift, "let count = 12 // note", "let", .keyword),
            (.javascript, "const x = 'hello';", "'hello'", .string),
            (.python, "def f(): # note", "# note", .comment),
            (.c, "int count = 42;", "42", .number),
            (.json, "{\"flag\": true}", "true", .keyword),
            (.markup, "<p><!-- note --></p>", "<!-- note -->", .comment),
            (.css, "a { color: red; }", "color", .keyword),
            (.shell, "if true; then # note", "then", .keyword),
            (.yaml, "name: 'MacEase'", "name", .keyword),
            (.markdown, "# Heading\n`code`", "# Heading", .keyword),
        ]
        for (language, sample, literal, kind) in cases {
            let tokens = try PreviewTokenizer.tokens(sample, language: language)
            XCTAssertTrue(
                tokens.contains { $0.kind == kind && (sample as NSString).substring(with: $0.range) == literal }, sample
            )
        }
        XCTAssertEqual(try PreviewTokenizer.tokens("let x = 12", language: .plain), [])
    }

    func testTokenizerKeepsCommentMarkersInsideStringsAndUTF16Ranges() throws {
        let sample = "let emoji = \"😀 // text\" /* real */"
        let tokens = try PreviewTokenizer.tokens(sample, language: .swift)
        XCTAssertEqual(
            tokens.filter { $0.kind == .comment }.map { (sample as NSString).substring(with: $0.range) }, ["/* real */"]
        )
        XCTAssertEqual(
            tokens.filter { $0.kind == .string }.map { (sample as NSString).substring(with: $0.range) },
            ["\"😀 // text\""])
    }

    func testHighlightingStopsAt512KiBWithoutTruncatingSource() throws {
        let text = String(repeating: " ", count: 512 * 1024) + "let untouched = 42"
        XCTAssertEqual(try PreviewTokenizer.tokens(text, language: .swift), [])
        XCTAssertTrue(text.hasSuffix("let untouched = 42"))
    }

    func testEngineFormattingPreservesJSONNumberLiteralsAndBinaryPlists() throws {
        let formatted = try JSONFormatter.formatted("{\"number\":9007199254740993,\"flag\":true}")
        XCTAssertEqual(formatted, "{\n  \"number\": 9007199254740993,\n  \"flag\": true\n}\n")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["enabled": true], format: .binary, options: 0)
        XCTAssertTrue(PreviewTextSource(bytes: bytes, truncated: false).binaryPropertyList)
        XCTAssertEqual(try PropertyListConversion.json(from: bytes, indent: "  "), "{\n  \"enabled\": true\n}\n")
        XCTAssertThrowsError(try JSONFormatter.formatted("{broken}"))
    }

    func testMarkdownUsesSafeEngineConversion() throws {
        let html = try MarkdownConversion.html("# Heading\n\n<script>alert(1)</script>", title: "Preview")
        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertFalse(html.contains("<script>"))
    }

    @MainActor
    func testOfflineRulesCompileAndConfigurationDisablesScriptsByDefault() async throws {
        let configuration = try await PreviewWebConfiguration.make()
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let rules = try await store.contentRuleList(forIdentifier: "MacEasePreviewOffline")
        XCTAssertNotNil(rules)
        let allowed = try await PreviewWebConfiguration.make(scripts: true, reach: .network)
        XCTAssertTrue(allowed.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(allowed.websiteDataStore.isPersistent)
        let reset = try await PreviewWebConfiguration.make()
        XCTAssertFalse(reset.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @MainActor
    func testNavigationRejectsExternalHostsSchemesAndSiblingFiles() throws {
        let source = URL(fileURLWithPath: "/tmp/example/index.html")
        let page = PreviewWebViewer.Page.file(
            source,
            PreviewWebPolicy(trust: PreviewTrust(level: .standard, resolvedPath: source.path), scriptsConsented: false))
        XCTAssertTrue(PreviewWebConfiguration.permitsNavigation(to: source, page: page))
        for address in [
            "https://example.com", "macease://run", "file:///tmp/example/other.html",
            "file://remote/tmp/example/index.html", "data:text/html,hi",
        ] {
            let destination = try XCTUnwrap(URL(string: address))
            XCTAssertFalse(PreviewWebConfiguration.permitsNavigation(to: destination, page: page))
        }
        let generated = PreviewWebViewer.Page.generated("<p>x</p>")
        XCTAssertTrue(
            PreviewWebConfiguration.permitsNavigation(to: try XCTUnwrap(URL(string: "about:blank")), page: generated))
        XCTAssertFalse(PreviewWebConfiguration.permitsNavigation(to: source, page: generated))
    }
}
