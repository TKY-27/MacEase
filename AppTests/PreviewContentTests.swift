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

        // Truncated BOM-less UTF-16LE Cyrillic decodes automatically.
        let cyrillic = "Привет, мир!\n"
        let cyrillicLE = Data(cyrillic.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        XCTAssertEqual(
            try PreviewTextSource(bytes: cyrillicLE.dropLast(1), truncated: true).decoded(as: .automatic),
            "Привет, мир!")
        let mixed = "Hello Привет مرحبا दुनिया"
        let mixedBE = Data(mixed.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        XCTAssertEqual(try PreviewTextSource(bytes: mixedBE, truncated: false).decoded(as: .automatic), mixed)
    }

    func testCJKEncodingsDecodeManuallyAndExposeDetectedEncoding() throws {
        XCTAssertTrue(PreviewEncoding.allCases.contains(.gb18030))
        XCTAssertTrue(PreviewEncoding.allCases.contains(.big5))
        XCTAssertTrue(PreviewEncoding.allCases.contains(.eucKR))
        XCTAssertEqual(PreviewEncoding.gb18030.title, "GB18030")
        XCTAssertEqual(PreviewEncoding.big5.title, "Big5")
        XCTAssertEqual(PreviewEncoding.eucKR.title, "EUC-KR")

        let simplified = "简体中文😀"
        let gbBytes = try XCTUnwrap(simplified.data(using: PreviewEncoding.gb18030.foundation))
        XCTAssertEqual(try PreviewTextSource(bytes: gbBytes, truncated: false).decoded(as: .gb18030), simplified)
        XCTAssertEqual(
            try PreviewTextSource(bytes: gbBytes.dropLast(1), truncated: true).decoded(as: .gb18030), "简体中文")
        XCTAssertEqual(
            try PreviewTextSource(bytes: gbBytes.dropLast(2), truncated: true).decoded(as: .gb18030), "简体中文")
        XCTAssertEqual(
            try PreviewTextSource(bytes: gbBytes.dropLast(3), truncated: true).decoded(as: .gb18030), "简体中文")
        XCTAssertThrowsError(try PreviewTextSource(bytes: gbBytes.dropLast(1), truncated: false).decoded(as: .gb18030))
        XCTAssertThrowsError(
            try PreviewTextSource(bytes: Data([0x41, 0xFF]), truncated: true).decoded(as: .gb18030))

        let traditional = "繁體中文邨"
        let big5Bytes = try XCTUnwrap(traditional.data(using: PreviewEncoding.big5.foundation))
        XCTAssertEqual(try PreviewTextSource(bytes: big5Bytes, truncated: false).decoded(as: .big5), traditional)
        XCTAssertEqual(
            try PreviewTextSource(bytes: big5Bytes.dropLast(1), truncated: true).decoded(as: .big5), "繁體中文")
        XCTAssertThrowsError(try PreviewTextSource(bytes: big5Bytes.dropLast(1), truncated: false).decoded(as: .big5))

        let korean = "한국어 똠"
        let eucKRBytes = try XCTUnwrap(korean.data(using: PreviewEncoding.eucKR.foundation))
        XCTAssertEqual(try PreviewTextSource(bytes: eucKRBytes, truncated: false).decoded(as: .eucKR), korean)
        XCTAssertEqual(
            try PreviewTextSource(bytes: eucKRBytes.dropLast(1), truncated: true).decoded(as: .eucKR), "한국어 ")
        XCTAssertThrowsError(
            try PreviewTextSource(bytes: eucKRBytes.dropLast(1), truncated: false).decoded(as: .eucKR))

        let gbWithBOM = PreviewTextSource(bytes: Data([0x84, 0x31, 0x95, 0x33]) + gbBytes, truncated: false)
        XCTAssertEqual(gbWithBOM.detectedEncoding, .gb18030)
        XCTAssertEqual(try gbWithBOM.decoded(as: .automatic), simplified)

        XCTAssertEqual(PreviewTextSource(bytes: Data("Hello".utf8), truncated: false).detectedEncoding, .utf8)
        XCTAssertEqual(
            PreviewTextSource(bytes: Data([0x93, 0xFA, 0x96, 0x7B]), truncated: false).detectedEncoding, .shiftJIS)
        XCTAssertEqual(
            PreviewTextSource(bytes: Data([0xFF, 0xFE, 0x41, 0x00]), truncated: false).detectedEncoding, .utf16LE)
        let bplist = try PropertyListSerialization.data(
            fromPropertyList: ["enabled": true], format: .binary, options: 0)
        XCTAssertNil(PreviewTextSource(bytes: bplist, truncated: false).detectedEncoding)
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

    func testTokenizerScopesQuotesPerLanguage() throws {
        let markdown = "It's fine and \"quoted\"\n# Heading\n`code`"
        let markdownTokens = try PreviewTokenizer.tokens(markdown, language: .markdown)
        XCTAssertEqual(
            markdownTokens.filter { $0.kind == .string }.map { (markdown as NSString).substring(with: $0.range) },
            ["`code`"])
        XCTAssertTrue(
            markdownTokens.contains {
                $0.kind == .keyword && (markdown as NSString).substring(with: $0.range) == "# Heading"
            })

        let html = "<p>don't stop</p><a href=\"/ok\" data-mode='view'>it's</a>"
        let htmlTokens = try PreviewTokenizer.tokens(html, language: .markup)
        XCTAssertEqual(
            htmlTokens.filter { $0.kind == .string }.map { (html as NSString).substring(with: $0.range) },
            ["\"/ok\"", "'view'"])
        XCTAssertEqual(
            htmlTokens.filter { $0.kind == .keyword }.map { (html as NSString).substring(with: $0.range) },
            ["<p", "</p", "<a", "</a"])

        let yaml = "note: don't panic\nflag: true\nname: 'MacEase'\nquoted: 'it''s ok'"
        let yamlTokens = try PreviewTokenizer.tokens(yaml, language: .yaml)
        XCTAssertEqual(
            yamlTokens.filter { $0.kind == .string }.map { (yaml as NSString).substring(with: $0.range) },
            ["'MacEase'", "'it''s ok'"])
        XCTAssertTrue(
            yamlTokens.contains {
                $0.kind == .keyword && (yaml as NSString).substring(with: $0.range) == "true"
            })

        let swift = "let pattern = /don't/\nlet count = 42"
        let swiftTokens = try PreviewTokenizer.tokens(swift, language: .swift)
        XCTAssertEqual(swiftTokens.filter { $0.kind == .string }, [])
        XCTAssertTrue(
            swiftTokens.contains {
                $0.kind == .number && (swift as NSString).substring(with: $0.range) == "42"
            })

        let jsonc = "// don't edit\n{\"flag\": true}"
        let jsoncTokens = try PreviewTokenizer.tokens(jsonc, language: .json)
        XCTAssertEqual(
            jsoncTokens.filter { $0.kind == .string }.map { (jsonc as NSString).substring(with: $0.range) },
            ["\"flag\""])
        XCTAssertTrue(
            jsoncTokens.contains {
                $0.kind == .keyword && (jsonc as NSString).substring(with: $0.range) == "true"
            })

        let cpp = "int million = 1'000'000; char ch = 'a';"
        let cppTokens = try PreviewTokenizer.tokens(cpp, language: .c)
        XCTAssertEqual(
            cppTokens.filter { $0.kind == .string }.map { (cpp as NSString).substring(with: $0.range) },
            ["'a'"])
    }

    func testMPEGTransportStreamRoutesToMediaWhileTypeScriptStaysText() throws {
        let directory = try PreviewFixtures.directory(self)
        var tsBytes = [UInt8](repeating: 0, count: 377)
        tsBytes[0] = 0x47
        tsBytes[188] = 0x47
        tsBytes[376] = 0x47
        var mtsBytes = [UInt8](repeating: 0, count: 389)
        mtsBytes[4] = 0x47
        mtsBytes[196] = 0x47
        mtsBytes[388] = 0x47

        let tsVideo = directory.appendingPathComponent("clip.ts")
        try Data(tsBytes).write(to: tsVideo)
        let mtsVideo = directory.appendingPathComponent("camera.mts")
        try Data(mtsBytes).write(to: mtsVideo)
        let typeScript = directory.appendingPathComponent("app.ts")
        try Data("export const answer: number = 42;\n".utf8).write(to: typeScript)
        let fakeTS = directory.appendingPathComponent("spoof.ts")
        try PreviewFixtures.png().write(to: fakeTS)

        let tsResult = try PreviewKind.inspectContent(tsVideo)
        XCTAssertEqual(tsResult.kind, .media)
        XCTAssertEqual(tsResult.detected?.family, .video)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: tsResult.kind, detected: try XCTUnwrap(tsResult.detected)), .matches)

        let mtsResult = try PreviewKind.inspectContent(mtsVideo)
        XCTAssertEqual(mtsResult.kind, .media)
        XCTAssertEqual(mtsResult.detected?.family, .video)
        XCTAssertEqual(try PreviewKind.inspect(mtsVideo, disabled: [.text]), .media)
        XCTAssertEqual(try PreviewKind.inspect(mtsVideo, disabled: [.video]), .quickLook)

        let scriptResult = try PreviewKind.inspectContent(typeScript)
        XCTAssertEqual(scriptResult.kind, .text)
        XCTAssertEqual(scriptResult.detected?.family, .text)
        XCTAssertEqual(try PreviewKind.inspect(typeScript, disabled: [.text]), .quickLook)

        let fakeResult = try PreviewKind.inspectContent(fakeTS)
        XCTAssertEqual(fakeResult.kind, .text)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: fakeResult.kind, detected: try XCTUnwrap(fakeResult.detected)),
            .binaryWithTextExtension(detectedName: "PNG"))
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
        let directory = try PreviewFixtures.directory(self)
        let source = directory.appendingPathComponent("index.html")
        try Data("<p>x</p>".utf8).write(to: source)
        let stamp = try PreviewFileStamp(of: source)

        let staticPage = PreviewWebViewer.Page.file(
            source, readAccess: directory, .staticPreview, expectedStamp: stamp)
        let configuration = try await PreviewWebConfiguration.make(for: staticPage)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(configuration.websiteDataStore.proxyConfigurations.isEmpty)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let rules = try await store.contentRuleList(forIdentifier: "MacEasePreviewOffline")
        XCTAssertNotNil(rules)

        let interactivePage = PreviewWebViewer.Page.file(
            source, readAccess: directory, .interactive, expectedStamp: stamp)
        let allowed = try await PreviewWebConfiguration.make(for: interactivePage)
        XCTAssertTrue(allowed.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(allowed.websiteDataStore.isPersistent)
        XCTAssertTrue(allowed.websiteDataStore.proxyConfigurations.isEmpty)

        let sealed = try await PreviewWebConfiguration.make(for: .generated("<p>x</p>"))
        XCTAssertFalse(sealed.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(sealed.websiteDataStore.proxyConfigurations.isEmpty)
    }

    @MainActor
    func testNavigationRejectsExternalHostsSchemesAndSiblingFiles() throws {
        let directory = try PreviewFixtures.directory(self)
        let source = directory.appendingPathComponent("index.html")
        try Data("<p>x</p>".utf8).write(to: source)
        let stamp = try PreviewFileStamp(of: source)
        let page = PreviewWebViewer.Page.file(
            source, readAccess: directory,
            PreviewWebPolicy(
                trust: PreviewTrust(level: .standard, resolvedPath: source.path, stamp: stamp),
                interactiveConsented: false),
            expectedStamp: stamp)
        XCTAssertTrue(PreviewWebConfiguration.permitsNavigation(to: source, page: page))
        let sibling = directory.appendingPathComponent("other.html").absoluteString
        for address in [
            "https://example.com", "macease://run", sibling,
            "file://remote\(source.path)", "data:text/html,hi",
        ] {
            let destination = try XCTUnwrap(URL(string: address))
            XCTAssertFalse(PreviewWebConfiguration.permitsNavigation(to: destination, page: page))
        }
        let generated = PreviewWebViewer.Page.generated("<p>x</p>")
        XCTAssertTrue(
            PreviewWebConfiguration.permitsNavigation(to: try XCTUnwrap(URL(string: "about:blank")), page: generated))
        XCTAssertFalse(PreviewWebConfiguration.permitsNavigation(to: source, page: generated))
    }

    func testDetectedFormatNamesHaveJapaneseLocalizations() throws {
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        let asfHeader: [UInt8] = [
            0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
        ]
        let asfVideoGUID: [UInt8] = [
            0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
        ]
        let samples: [([UInt8], String, String)] = [
            ([0x46, 0x4C, 0x56, 0x01, 0x05], "Flash Video", "Flash動画"),
            (asfHeader + asfVideoGUID, "Windows Media Video", "Windows Media動画"),
            (asfHeader + [0x00, 0x00], "Windows Media Audio", "Windows Mediaオーディオ"),
            ([0x00, 0x00, 0x00, 0x14] + Array("ftypcrx ".utf8), "Canon RAW", "Canon RAW画像"),
        ]
        for (header, expectedEnglish, expectedJapanese) in samples {
            let detected = ContentSniffer.identify(header: header)
            XCTAssertEqual(detected.displayName, expectedEnglish)
            XCTAssertEqual(
                japanese.localizedString(forKey: detected.displayName, value: nil, table: nil), expectedJapanese)
        }
    }
}
