import Foundation
import XCTest

@testable import MacEase

@MainActor
final class PreviewSealedPageTests: XCTestCase {
    private func rendering(_ url: URL, kind: PreviewKind, restricted: Bool = false) throws -> PreviewTextRendering {
        try PreviewTextRendering.make(
            source: try PreviewTextSource.read(url), encoding: .automatic, rich: true, kind: kind, url: url,
            restricted: restricted)
    }

    func testSVGPreviewShowsTheImageWithoutScriptsOrNetwork() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let directory = try PreviewFixtures.directory(self)
        let svg = directory.appendingPathComponent("icon.svg")
        try Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
              width="40" height="20" onload="top.document.title='ran'">
            <script>top.document.title = "ran";</script>
            <image href="http://127.0.0.1:\(port)/remote.png" width="10" height="10"/>
            <rect width="40" height="20" fill="teal"/></svg>
            """.utf8
        ).write(to: svg)

        let page = try rendering(svg, kind: .svg)
        XCTAssertTrue(page.html)
        let probe = try await PreviewWebProbe.loading(.generated(page.text))
        try await probe.settle()
        let width = try await probe.evaluate("document.images[0].naturalWidth")
        XCTAssertEqual(width as? Int, 40)
        let title = try await probe.evaluate("document.title")
        XCTAssertEqual(title as? String, "")
        XCTAssertEqual(listener.connectionCount, 0)
    }
}
