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
}
