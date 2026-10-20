import AppKit
import WebKit

/// Scripts off and every load blocked.
@MainActor
enum SVGRenderer {
    nonisolated static let sniffLength = 4096

    nonisolated static func isSVG(_ data: Data) -> Bool {
        String(decoding: data.prefix(sniffLength), as: UTF8.self).lowercased().contains("<svg")
    }

    nonisolated static let defaultEdge = 1024.0
    nonisolated static let maximumEdge = 8192.0
    private static let blockEverything = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    private static let ruleListIdentifier = "MacEaseSVGBlockAll"

    static func render(_ svg: Data) async throws -> CGImage {
        let size = SVGSize.parse(svg)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(try await ruleList())
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        // No public API disables the white backdrop.
        webView.setValue(false, forKey: "drawsBackground")
        let loader = NavigationWaiter()
        webView.navigationDelegate = loader
        guard let blank = URL(string: "about:blank") else { throw EngineError.decodeFailed("SVG base URL") }
        try await loader.wait {
            webView.load(svg, mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: blank)
        }
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: size)
        snapshotConfiguration.snapshotWidth = NSNumber(value: Double(size.width))
        let snapshot = try await webView.takeSnapshot(configuration: snapshotConfiguration)
        guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw EngineError.decodeFailed("SVG snapshot")
        }
        return try ImagePixels.draw(
            width: Int(size.width), height: Int(size.height), like: image, fill: nil
        ) { context in
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    private static func ruleList() async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else { throw EngineError.decodeFailed("rule store") }
        guard
            let compiled = try await store.compileContentRuleList(
                forIdentifier: ruleListIdentifier, encodedContentRuleList: blockEverything)
        else { throw EngineError.decodeFailed("rule list") }
        return compiled
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait(_ start: () -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(CancellationError()) } else { start() }
            }
        } onCancel: {
            Task { @MainActor in self.finish(CancellationError()) }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(EngineError.decodeFailed("SVG renderer terminated"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        finish(error)
    }

    private func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        switch error {
        case nil: continuation.resume()
        case let known as CancellationError: continuation.resume(throwing: known)
        case let known as EngineError: continuation.resume(throwing: known)
        case let other?: continuation.resume(throwing: EngineError.decodeFailed("SVG load \((other as NSError).code)"))
        }
    }
}

/// Root size in CSS pixels.
private final class SVGSize: NSObject, XMLParserDelegate {
    private var size: CGSize?

    static func parse(_ svg: Data) -> CGSize {
        let reader = SVGSize()
        let parser = XMLParser(data: svg)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        let found = reader.size ?? CGSize(width: SVGRenderer.defaultEdge, height: SVGRenderer.defaultEdge)
        let scale = min(1, SVGRenderer.maximumEdge / max(found.width, found.height))
        return CGSize(width: max(1, (found.width * scale).rounded()), height: max(1, (found.height * scale).rounded()))
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        defer { parser.abortParsing() }
        guard elementName == "svg" || elementName.hasSuffix(":svg") else { return }
        let viewBox = attributes["viewBox"]?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap {
            Double($0)
        }
        let boxSize = viewBox.flatMap {
            $0.count == 4 && $0[2] > 0 && $0[3] > 0 ? CGSize(width: $0[2], height: $0[3]) : nil
        }
        let width = Self.pixels(attributes["width"])
        let height = Self.pixels(attributes["height"])
        switch (width, height, boxSize) {
        case (let width?, let height?, _): size = CGSize(width: width, height: height)
        case (let width?, nil, let box?): size = CGSize(width: width, height: width * box.height / box.width)
        case (nil, let height?, let box?): size = CGSize(width: height * box.width / box.height, height: height)
        default: size = boxSize
        }
    }

    /// Only unitless or `px` lengths count.
    private static func pixels(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        let number = value.hasSuffix("px") ? String(value.dropLast(2)) : value
        return Double(number).flatMap { $0 > 0 ? $0 : nil }
    }
}
