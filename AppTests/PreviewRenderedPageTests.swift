import AppKit
import XCTest

@testable import MacEase

@MainActor
final class PreviewRenderedPageTests: XCTestCase {
    private static let filler = String(
        repeating: "Filler paragraph that pushes the target below the fold.\n\n", count: 40)

    // Copy writes the shared pasteboard.
    private func preservingPasteboard(_ body: () async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            let copy = NSPasteboardItem()
            for type in pasteboardItem.types {
                if let bytes = pasteboardItem.data(forType: type) { copy.setData(bytes, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        try await body()
    }

    private func scrollTop(of selector: String, in probe: PreviewWebProbe) async throws -> Double {
        let top = try await probe.evaluate("document.querySelector('\(selector)').getBoundingClientRect().top")
        return try XCTUnwrap(top as? Double)
    }

    func testRenderedMarkdownSelectsCopiesAndJumpsToHeadingsButNeverFollowsExternalLinks() async throws {
        let directory = try PreviewFixtures.directory(self)
        let file = directory.appendingPathComponent("README.md")
        try Data(
            """
            # Guide

            See [Usage](#usage) or [the site](https://example.com/docs?a=1&b=2).

            \(Self.filler)
            ## Usage

            Run the tool.

            \(Self.filler)
            """.utf8
        ).write(to: file)
        let rendering = try PreviewTextRendering.make(
            source: try PreviewTextSource.read(file), encoding: .automatic, rich: true, kind: .markdown, url: file,
            restricted: false)
        let probe = try await PreviewWebProbe.loading(.generated(rendering.text))
        let startURL = probe.currentURL
        XCTAssertTrue(probe.focusWebView())

        try await preservingPasteboard {
            try probe.click(webPoint: try await probe.center(of: "h1"), clickCount: 2)
            let selected = try await PreviewFixtures.waitUntil {
                (try await probe.evaluate("getSelection().toString()") as? String) == "Guide"
            }
            XCTAssertTrue(selected)
            XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: probe.container.webView, from: nil))
            let copied = try await PreviewFixtures.waitUntil {
                NSPasteboard.general.string(forType: .string) == "Guide"
            }
            XCTAssertTrue(copied)
        }
        let menusBefore = probe.shownMenuItems.count
        try probe.rightClick(webPoint: try await probe.center(of: "h1"))
        let menuShown = try await PreviewFixtures.waitUntil { probe.shownMenuItems.count > menusBefore }
        XCTAssertTrue(menuShown, "right-clicking a selection shows a menu")
        let menu = try XCTUnwrap(probe.shownMenuItems.last)
        XCTAssertTrue(menu.contains("WKMenuItemIdentifierCopy"), "\(menu)")
        XCTAssertTrue(Set(menu).isSubset(of: PreviewWebProbe.selectionMenuItems), "\(menu)")

        let external = try await probe.evaluate(
            "JSON.stringify([...document.links].length + ':' + document.querySelectorAll('a')[1].title)")
        XCTAssertEqual(external as? String, #""0:https://example.com/docs?a=1&b=2""#)
        try probe.click(webPoint: try await probe.center(of: "a[title]"))
        try await probe.nextFrame()
        XCTAssertEqual(probe.currentURL, startURL)

        _ = try await probe.evaluate("scrollTo(0, 0), true")
        let headingBefore = try await scrollTop(of: "h2", in: probe)
        XCTAssertGreaterThan(headingBefore, 300)
        try probe.click(webPoint: try await probe.center(of: "a[data-macease-fragment]"))
        let jumped = try await PreviewFixtures.waitUntil { abs(try await self.scrollTop(of: "h2", in: probe)) <= 2 }
        XCTAssertTrue(jumped)
        let headingAfter = try await scrollTop(of: "h2", in: probe)
        XCTAssertEqual(headingAfter, 0, accuracy: 2)
        XCTAssertEqual(probe.currentURL, startURL)
        XCTAssertEqual(probe.requestedNavigationURLs.count, 1, "\(probe.requestedNavigationURLs)")

        let found = await probe.container.find("run the TOOL", direction: .forward, restart: true)
        XCTAssertTrue(found.found)
        let missing = await probe.container.find("absent words", direction: .forward, restart: true)
        XCTAssertFalse(missing.found)
    }

    func testStaticHTMLKeepsInPageAnchorsAndSelectionWithoutConnectingThroughBaseHref() async throws {
        let tcp = try LoopbackListener()
        let port = try await tcp.start()
        defer { tcp.stop() }
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("report.html")
        try Data(
            """
            <!DOCTYPE html><html><head><base href="http://127.0.0.1:\(port)/"></head><body>
            <p id="intro">Intro words to select</p>
            <a id="toc" href="#later">Jump</a> <a id="ext" href="page.html">Elsewhere</a>
            \(Self.filler.replacingOccurrences(of: "\n\n", with: "<br>"))
            <h2 id="later">Later section</h2>
            \(Self.filler.replacingOccurrences(of: "\n\n", with: "<br>"))</body></html>
            """.utf8
        ).write(to: page)
        let resolved = page.resolvingSymlinksInPath().standardizedFileURL
        let probe = try await PreviewWebProbe.loading(
            .file(
                resolved, readAccess: try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolved)),
                .staticPreview, expectedStamp: try PreviewFileStamp(of: resolved)))

        let intro = try await probe.center(of: "#intro")
        try probe.drag(from: NSPoint(x: 4, y: intro.y), to: NSPoint(x: 300, y: intro.y))
        let dragged = try await PreviewFixtures.waitUntil {
            ((try await probe.evaluate("getSelection().toString()") as? String) ?? "").hasPrefix("Intro words")
        }
        XCTAssertTrue(dragged)

        let title = try await probe.evaluate("document.getElementById('ext').title") as? String
        XCTAssertEqual(title, "http://127.0.0.1:\(port)/page.html", "inert links show where they lead")
        try probe.click(webPoint: try await probe.center(of: "#ext"))
        try probe.click(webPoint: try await probe.center(of: "#toc"))
        let jumped = try await PreviewFixtures.waitUntil { abs(try await self.scrollTop(of: "#later", in: probe)) <= 2 }
        XCTAssertTrue(jumped)
        let later = try await scrollTop(of: "#later", in: probe)
        XCTAssertEqual(later, 0, accuracy: 2)
        XCTAssertEqual(probe.currentURL?.standardizedFileURL.path, resolved.path)
        XCTAssertEqual(probe.requestedNavigationURLs.count, 1, "\(probe.requestedNavigationURLs)")
        XCTAssertEqual(tcp.connectionCount, 0)
    }

    func testRenderedPageMenuKeepsOnlySelectionActions() {
        let identifiers = [
            "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink",
            "", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSearchWeb",
            "WKMenuItemIdentifierTranslate", "", "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierSpeechMenu",
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "",
        ]
        func menu(_ identifiers: [String]) -> NSMenu {
            let menu = NSMenu()
            for identifier in identifiers {
                guard !identifier.isEmpty else {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
                menuItem.identifier = NSUserInterfaceItemIdentifier(identifier)
                menu.addItem(menuItem)
            }
            PreviewWKWebView.restrictToSelectionActions(menu)
            return menu
        }
        XCTAssertEqual(
            menu(identifiers).items.map(\.title),
            ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "", "WKMenuItemIdentifierSpeechMenu"],
            "sharing a link could make another app fetch it")
        XCTAssertEqual(
            menu([
                "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierShareMenu",
            ])
            .items.map(\.title),
            [],
            "sharing an image must be stripped")
        XCTAssertEqual(
            menu(identifiers.filter { !$0.contains("Link") }).items.map(\.title),
            [
                "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "", "WKMenuItemIdentifierShareMenu",
                "WKMenuItemIdentifierSpeechMenu",
            ])
    }

    func testLargeHTMLStreamsFromItsFileButRestrictedAndOversizedFilesAreUnavailable() throws {
        let directory = try PreviewFixtures.directory(self)
        let large = directory.appendingPathComponent("large.html")
        let body = String(repeating: "<p>row</p>\n", count: (PreviewTextSource.maximumBytes / 11) + 1024)
        try Data("<html><body>\(body)</body></html>".utf8).write(to: large)
        let streamed = try PreviewHTMLSnapshot.prepare(url: large, trustedFolders: [], scriptConsent: [])
        XCTAssertFalse(streamed.truncated)
        guard case .file(let url, _, .staticPreview, _) = streamed.page else {
            return XCTFail("expected a file load, got \(String(describing: streamed.page))")
        }
        XCTAssertEqual(url.lastPathComponent, "large.html")

        let downloaded = directory.appendingPathComponent("downloaded.html")
        try FileManager.default.copyItem(at: large, to: downloaded)
        try PreviewFixtures.quarantine(downloaded)
        let restricted = try PreviewHTMLSnapshot.prepare(url: downloaded, trustedFolders: [], scriptConsent: [])
        XCTAssertTrue(restricted.truncated)
        XCTAssertNil(restricted.page)

        let oversized = directory.appendingPathComponent("oversized.html")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data("<p>".utf8)))
        let writer = try FileHandle(forWritingTo: oversized)
        try writer.truncate(atOffset: UInt64(PreviewHTMLSnapshot.maximumFileBytes) + 1)
        try writer.close()
        let refused = try PreviewHTMLSnapshot.prepare(url: oversized, trustedFolders: [], scriptConsent: [])
        XCTAssertTrue(refused.truncated)
        XCTAssertNil(refused.page)
    }

    func testLargeStructuredFilesReportTooLargeWhileSourceStillShowsTheirText() throws {
        let directory = try PreviewFixtures.directory(self)
        let json = directory.appendingPathComponent("big.json")
        try Data(("[" + String(repeating: "1,", count: PreviewTextSource.maximumBytes / 2) + "1]").utf8).write(to: json)
        let svg = directory.appendingPathComponent("big.svg")
        let padding = String(repeating: " ", count: PreviewTextSource.maximumBytes)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\">\(padding)</svg>".utf8).write(to: svg)
        for (file, kind) in [(json, PreviewKind.json), (svg, .svg)] {
            let source = try PreviewTextSource.read(file)
            XCTAssertTrue(source.truncated)
            XCTAssertThrowsError(
                try PreviewTextRendering.make(
                    source: source, encoding: .automatic, rich: true, kind: kind, url: file, restricted: false)
            ) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileReadTooLarge, "\(kind)")
            }
            let excerpt = try PreviewTextRendering.make(
                source: source, encoding: .automatic, rich: false, kind: kind, url: file, restricted: false)
            XCTAssertEqual(excerpt.decodedAs, .utf8)
            XCTAssertFalse(excerpt.text.isEmpty)
        }
    }

    func testSourceReportsTheDetectedOrChosenEncoding() throws {
        let directory = try PreviewFixtures.directory(self)
        let japanese = directory.appendingPathComponent("memo.txt")
        let shiftJIS = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        try XCTUnwrap("日本語のメモです。".data(using: shiftJIS)).write(to: japanese)
        let source = try PreviewTextSource.read(japanese)
        func encoding(_ choice: PreviewEncoding) throws -> PreviewEncoding? {
            try PreviewTextRendering.make(
                source: source, encoding: choice, rich: false, kind: .text, url: japanese, restricted: false
            ).decodedAs
        }
        XCTAssertEqual(try encoding(.automatic), .shiftJIS)
        XCTAssertEqual(try encoding(.latin1), .latin1)

        let markdown = directory.appendingPathComponent("notes.md")
        try Data("# Title".utf8).write(to: markdown)
        let rendered = try PreviewTextRendering.make(
            source: try PreviewTextSource.read(markdown), encoding: .automatic, rich: true, kind: .markdown,
            url: markdown, restricted: false)
        XCTAssertNil(rendered.decodedAs, "rendered pages hide the encoding menu")
    }
}
