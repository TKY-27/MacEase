import Engine
import Foundation
import XCTest

@testable import MacEase

final class PreviewMarkdownRendererTests: XCTestCase {
    private static let minimalPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ])

    func testEmbedsSameFolderAndSubdirectoryImagesIncludingEncodedNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let direct = root.appendingPathComponent("diagram.png")
        let spaced = root.appendingPathComponent("my photo.jpg")
        let subdir = nested.appendingPathComponent("icon.svg")
        let japanese = root.appendingPathComponent("図.png")
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let svgBytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        try Self.minimalPNG.write(to: direct)
        try jpegBytes.write(to: spaced)
        try svgBytes.write(to: subdir)
        try Self.minimalPNG.write(to: japanese)

        let markdownURL = root.appendingPathComponent("readme.md")
        let markdown = """
            ![direct](diagram.png)
            ![dot](./diagram.png)
            ![spaced](my%20photo.jpg)
            ![nested](assets/icon.svg)
            ![jp](図.png)
            ![remote](https://example.com/pic.png)
            """
        let html = try PreviewMarkdownRenderer.html(markdown, markdownURL: markdownURL, restricted: false)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,\(Self.minimalPNG.base64EncodedString())\""))
        XCTAssertTrue(html.contains("src=\"data:image/jpeg;base64,\(jpegBytes.base64EncodedString())\""))
        XCTAssertTrue(html.contains("src=\"data:image/svg+xml;base64,\(svgBytes.base64EncodedString())\""))
        XCTAssertTrue(html.contains("src=\"https://example.com/pic.png\""))
        XCTAssertFalse(html.contains("src=\"diagram.png\""))
        XCTAssertFalse(html.contains("src=\"assets/icon.svg\""))
    }

    func testRestrictedModeDisablesAllImageEmbedding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try Self.minimalPNG.write(to: root.appendingPathComponent("pic.png"))
        let markdownURL = root.appendingPathComponent("readme.md")
        let html = try PreviewMarkdownRenderer.html(
            "![pic](pic.png)\n\n<script>alert(1)</script>", markdownURL: markdownURL, restricted: true)
        XCTAssertTrue(html.contains("src=\"pic.png\""))
        XCTAssertFalse(html.contains("data:image/"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testBlocksTraversalAbsolutePathsSymlinkEscapesAndNonImages() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = parent.appendingPathComponent("doc")
        let sibling = parent.appendingPathComponent("doc2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }

        let outside = parent.appendingPathComponent("outside.png")
        let siblingImage = sibling.appendingPathComponent("sibling.png")
        try Self.minimalPNG.write(to: outside)
        try Self.minimalPNG.write(to: siblingImage)
        try Data("TOP_SECRET=1\n".utf8).write(to: folder.appendingPathComponent("secret.env"))

        let escapeLink = folder.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        let escapeDirLink = folder.appendingPathComponent("escape-dir")
        try FileManager.default.createSymbolicLink(at: escapeDirLink, withDestinationURL: sibling)
        let siblingLink = folder.appendingPathComponent("sibling-link.png")
        try FileManager.default.createSymbolicLink(at: siblingLink, withDestinationURL: siblingImage)

        let markdownURL = folder.appendingPathComponent("note.md")
        let markdown = """
            ![parent](../outside.png)
            ![encoded](%2e%2e/outside.png)
            ![abs](\(outside.path))
            ![escape](escape.png)
            ![escapeDir](escape-dir/sibling.png)
            ![sibling](sibling-link.png)
            ![env](secret.env)
            """
        let html = try PreviewMarkdownRenderer.html(markdown, markdownURL: markdownURL, restricted: false)
        XCTAssertFalse(html.contains("data:image/"))
        XCTAssertFalse(html.contains("TOP_SECRET"))
    }

    func testEnforcesPerImage8MiBAndTotal32MiBLimitsAndSafeMarkdownLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var oversized = Self.minimalPNG
        oversized.append(Data(repeating: 0, count: PreviewMarkdownRenderer.maximumImageBytes + 1 - oversized.count))
        try oversized.write(to: root.appendingPathComponent("too-big.png"))

        var sevenMiB = Self.minimalPNG
        sevenMiB.append(Data(repeating: 0, count: 7 * 1024 * 1024 - sevenMiB.count))
        for index in 1...5 {
            try sevenMiB.write(to: root.appendingPathComponent("chunk-\(index).png"))
        }

        let markdownURL = root.appendingPathComponent("heavy.md")
        let markdown = """
            ![oversized](too-big.png)
            ![1](chunk-1.png)
            ![2](chunk-2.png)
            ![3](chunk-3.png)
            ![4](chunk-4.png)
            ![5](chunk-5.png)
            """
        let html = try PreviewMarkdownRenderer.html(markdown, markdownURL: markdownURL, restricted: false)
        XCTAssertTrue(html.contains("src=\"too-big.png\""))
        XCTAssertTrue(html.contains("src=\"chunk-5.png\""))
        XCTAssertFalse(html.contains("src=\"chunk-1.png\""))
        XCTAssertFalse(html.contains("src=\"chunk-4.png\""))

        let oversizedMarkdown = String(repeating: "a", count: 1024 * 1024 + 1)
        XCTAssertThrowsError(
            try PreviewMarkdownRenderer.html(oversizedMarkdown, markdownURL: markdownURL, restricted: false))
    }

    func testDocumentedLimitsAreEightAndThirtyTwoMiB() {
        XCTAssertEqual(PreviewMarkdownRenderer.maximumImageBytes, 8_388_608)
        XCTAssertEqual(PreviewMarkdownRenderer.maximumTotalImageBytes, 33_554_432)
    }

    func testSymlinkedFoldersAreNeverFollowedEvenInsideTheFolder() throws {
        let root = try PreviewFixtures.directory(self)
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        try Self.minimalPNG.write(to: assets.appendingPathComponent("pic.png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: assets)

        let markdownURL = root.appendingPathComponent("readme.md")
        let html = try PreviewMarkdownRenderer.html(
            "![real](assets/pic.png)\n\n![linked](link/pic.png)", markdownURL: markdownURL, restricted: false)
        XCTAssertFalse(html.contains("src=\"assets/pic.png\""))
        XCTAssertTrue(html.contains("src=\"link/pic.png\""))
    }

    func testSpecialFilesAreSkippedWithoutBlocking() throws {
        let root = try PreviewFixtures.directory(self)
        let pipe = root.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        try Self.minimalPNG.write(to: root.appendingPathComponent("pic.png"))
        let markdownURL = root.appendingPathComponent("readme.md")
        let html = try PreviewMarkdownRenderer.html(
            "![pipe](pipe.png)\n\n![pic](pic.png)", markdownURL: markdownURL, restricted: false)
        XCTAssertTrue(html.contains("src=\"pipe.png\""))
        XCTAssertFalse(html.contains("src=\"pic.png\""))
    }

    func testHardlinksEmbedLikeFilesAndStayWithinTheTotal() throws {
        let root = try PreviewFixtures.directory(self)
        var sevenMiB = Self.minimalPNG
        sevenMiB.append(Data(repeating: 0, count: 7 * 1024 * 1024 - sevenMiB.count))
        let original = root.appendingPathComponent("chunk-1.png")
        try sevenMiB.write(to: original)
        for index in 2...5 {
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("chunk-\(index).png"))
        }
        let markdownURL = root.appendingPathComponent("heavy.md")
        let markdown = (1...5).map { "![\($0)](chunk-\($0).png)" }.joined(separator: "\n\n")
        let html = try PreviewMarkdownRenderer.html(markdown, markdownURL: markdownURL, restricted: false)
        XCTAssertFalse(html.contains("src=\"chunk-4.png\""))
        XCTAssertTrue(html.contains("src=\"chunk-5.png\""))
    }

    func testRepeatedNonImageReferencesAreNotReadInFull() throws {
        let root = try PreviewFixtures.directory(self)
        let payload = Data(repeating: 0x41, count: PreviewMarkdownRenderer.maximumImageBytes)
        try payload.write(to: root.appendingPathComponent("payload.bin"))
        try Self.minimalPNG.write(to: root.appendingPathComponent("pic.png"))
        let markdownURL = root.appendingPathComponent("readme.md")
        let markdown = String(repeating: "![p](payload.bin)\n", count: 50_000) + "\n![pic](pic.png)"

        let start = ContinuousClock.now
        let html = try PreviewMarkdownRenderer.html(markdown, markdownURL: markdownURL, restricted: false)
        // Reading 400 GiB would take far longer.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
        XCTAssertEqual(html.components(separatedBy: "src=\"payload.bin\"").count - 1, 50_000)
        XCTAssertFalse(html.contains("src=\"pic.png\""))
    }

    func testCancellationStopsEmbedding() async throws {
        let root = try PreviewFixtures.directory(self)
        try Self.minimalPNG.write(to: root.appendingPathComponent("pic.png"))
        let markdownURL = root.appendingPathComponent("readme.md")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewMarkdownRenderer.html("![pic](pic.png)", markdownURL: markdownURL, restricted: false)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testAltTextAndFileNamesCannotInjectMarkupOrReachTheNetwork() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let root = try PreviewFixtures.directory(self)
        let hostileName = "x\" onerror=\"document.title='ran'.png"
        try PreviewFixtures.png().write(to: root.appendingPathComponent(hostileName))
        let markdownURL = root.appendingPathComponent("readme.md")
        try Data(
            """
            # Title

            ![\\"><script>document.title='ran'</script>](x%22%20onerror=%22document.title='ran'.png)

            ![remote](http://127.0.0.1:\(port)/remote.png)

            <img src="http://127.0.0.1:\(port)/raw.png" onerror="document.title='ran'">
            """.utf8
        ).write(to: markdownURL)

        let page = try PreviewTextRendering.make(
            source: try PreviewTextSource.read(markdownURL), encoding: .automatic, rich: true, kind: .markdown,
            url: markdownURL, restricted: false)
        XCTAssertFalse(page.text.contains("<script"))
        let probe = try await PreviewWebProbe.loading(.generated(page.text))
        try await probe.settle()
        let scripts = try await probe.evaluate("document.querySelectorAll('script, [onerror]').length")
        XCTAssertEqual(scripts as? Int, 0)
        let embedded = try await probe.evaluate("document.images[0].naturalWidth")
        XCTAssertEqual(embedded as? Int, 8)
        let source = try await probe.evaluate("document.images[0].src.slice(0, 22)")
        XCTAssertEqual(source as? String, "data:image/png;base64,")
        let title = try await probe.evaluate("document.title")
        XCTAssertNotEqual(title as? String, "ran")
        XCTAssertEqual(listener.connectionCount, 0)
    }

    func testMarkdownKeepsOriginalDirectoryDescriptorAfterPathSwap() throws {
        let root = try PreviewFixtures.directory(self)
        let original = root.appendingPathComponent("docs")
        let outside = root.appendingPathComponent("outside")
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)

        let originalImage = try PreviewFixtures.png(width: 8, height: 6)
        let outsideImage = try PreviewFixtures.png(width: 12, height: 4)
        XCTAssertNotEqual(originalImage, outsideImage)
        try originalImage.write(to: original.appendingPathComponent("pic.png"))
        try outsideImage.write(to: outside.appendingPathComponent("pic.png"))
        let markdownURL = original.appendingPathComponent("readme.md")
        try Data("![pic](pic.png)\n".utf8).write(to: markdownURL)

        let source = try PreviewTextSource.read(markdownURL, keepParentDirectory: true)
        XCTAssertNotNil(source.parentDirectory)

        // Swap folder path with symlink after reading.
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)

        let rendering = try PreviewTextRendering.make(
            source: source, encoding: .automatic, rich: true, kind: .markdown, url: markdownURL, restricted: false)
        XCTAssertTrue(rendering.text.contains("data:image/png;base64,\(originalImage.base64EncodedString())"))
        XCTAssertFalse(rendering.text.contains("data:image/png;base64,\(outsideImage.base64EncodedString())"))
    }

    func testExternalLinksRenderWithoutANavigableTargetButInPageLinksKeepTheirFragment() throws {
        let markdownURL = FileManager.default.temporaryDirectory.appendingPathComponent("links.md")
        let markdown = """
            [Install](#install), [site](https://example.com/a?b=1&c=2 "Home"), <https://example.org>, \
            [page](other.md) and `<a href="kept">` in code.
            """
        for restricted in [false, true] {
            let html = try PreviewMarkdownRenderer.html(markdown, markdownURL: markdownURL, restricted: restricted)
            XCTAssertTrue(html.contains(##"<a href="#install">Install</a>"##), html)
            XCTAssertTrue(html.contains(#"<a title="https://example.com/a?b=1&amp;c=2""#), html)
            XCTAssertTrue(html.contains(#"<a title="https://example.com/a?b=1&amp;c=2">site</a>"#), html)
            XCTAssertFalse(html.contains(#"title="Home""#), html)
            XCTAssertTrue(html.contains(#"<a title="https://example.org">"#), html)
            XCTAssertTrue(html.contains(#"<a title="other.md">page</a>"#), html)
            XCTAssertTrue(html.contains("&lt;a href=&quot;kept&quot;&gt;"), html)
            XCTAssertEqual(html.components(separatedBy: "<a href=").count, 2, html)
        }
    }
}
