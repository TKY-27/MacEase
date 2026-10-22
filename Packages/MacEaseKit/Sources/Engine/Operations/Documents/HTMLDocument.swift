import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
enum HTMLDocument {
    private static let rules =
        #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^macease-document://local/"},"action":{"type":"ignore-previous-rules"}}]"#

    static func convert(_ html: String, source: URL, toPDF: Bool) async throws -> Data {
        guard html.utf8.count <= ConversionInput.maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))
        }
        try Task.checkCancellation()
        guard let store = WKContentRuleListStore.default(),
            let rules = try await store.compileContentRuleList(
                forIdentifier: "MacEaseOfflineDocument", encodedContentRuleList: rules)
        else { throw EngineError.decodeFailed("HTML content restrictions could not be installed") }
        return try await HTMLSession(html: html, source: source, rules: rules).convert(toPDF: toPDF)
    }
}

@MainActor
private final class HTMLSession: NSObject, WKNavigationDelegate {
    private static let pageWidth = 595.28
    private static let pageHeight = 841.89
    private static let maximumEdge = 20_000.0
    private static let maximumArea = 16_000_000.0
    private static let maximumOutputBytes = 32 * 1024 * 1024
    private static let timeout: Duration = .seconds(20)
    private let browser: WKWebView
    private let resources: HTMLResources
    private var continuation: CheckedContinuation<Data, any Error>?
    private var deadline: Task<Void, Never>?
    private var rendering: Task<Void, Never>?
    private var toPDF = false

    init(html: String, source: URL, rules: WKContentRuleList) {
        resources = HTMLResources(html: html, source: source)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(rules)
        configuration.setURLSchemeHandler(resources, forURLScheme: HTMLResources.scheme)
        browser = WKWebView(
            frame: CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight),
            configuration: configuration)
        super.init()
        browser.navigationDelegate = self
    }

    func convert(toPDF: Bool) async throws -> Data {
        self.toPDF = toPDF
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                    return
                }
                deadline = Task {
                    do {
                        try await Task.sleep(for: Self.timeout)
                        finish(.failure(EngineError.decodeFailed("HTML rendering timed out")))
                    } catch is CancellationError {
                        return
                    } catch {
                        finish(.failure(error))
                    }
                }
                guard let address = URL(string: "\(HTMLResources.scheme)://local/document.html") else {
                    finish(.failure(EngineError.decodeFailed("HTML base URL is invalid")))
                    return
                }
                browser.load(URLRequest(url: address))
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, rendering == nil else { return }
        rendering = Task {
            do {
                if let failure = resources.failure { throw failure }
                let output = try await renderedOutput()
                try Task.checkCancellation()
                if let failure = resources.failure { throw failure }
                guard output.count <= Self.maximumOutputBytes else {
                    throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(Self.maximumOutputBytes)))
                }
                finish(.success(output))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func renderedOutput() async throws -> Data {
        if !toPDF {
            let result = try await browser.evaluateJavaScript("document.body ? document.body.innerText : ''")
            guard let text = result as? String else { throw EngineError.decodeFailed("HTML text is unavailable") }
            guard !text.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
            return Data((text + "\n").utf8)
        }
        let dimensions = try await browser.evaluateJavaScript(
            "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]")
        guard let extent = dimensions as? [Double], extent.count == 2,
            extent.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= Self.maximumEdge }),
            extent[0] * extent[1] <= Self.maximumArea
        else {
            throw EngineError.invalidInput(.malformed("HTML layout exceeds the PDF size limit"))
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: extent[0], height: extent[1])
        return try await browser.pdf(configuration: configuration)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        let address = navigationAction.request.url
        let initial =
            navigationAction.targetFrame?.isMainFrame == true
            && address?.scheme == HTMLResources.scheme && address?.host == "local"
            && address?.path == "/document.html" && !resources.mainLoaded
        if !initial {
            finish(.failure(EngineError.invalidInput(.malformed("HTML navigation and embedded pages are unsupported"))))
        }
        return initial ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(EngineError.decodeFailed("HTML renderer terminated")))
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        rendering?.cancel()
        browser.navigationDelegate = nil
        browser.stopLoading()
        continuation.resume(with: result)
    }
}

@MainActor
private final class HTMLResources: NSObject, WKURLSchemeHandler {
    static let scheme = "macease-document"
    private static let maximumRequests = 256
    private static let maximumResourceBytes = 32 * 1024 * 1024
    private static let contentPolicy =
        "default-src 'none'; style-src 'unsafe-inline' macease-document:; img-src macease-document:; font-src macease-document:; base-uri 'none'; form-action 'none'"
    private static let allowedExtensions: Set<String> = [
        "css", "png", "jpg", "jpeg", "gif", "webp", "svg", "woff", "woff2", "ttf", "otf",
    ]
    private let html: Data
    private let directory: URL
    private var requestCount = 0
    private var byteCount = 0
    private(set) var mainLoaded = false
    private(set) var failure: (any Error)?

    init(html: String, source: URL) {
        self.html = Data(html.utf8)
        directory = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let address = urlSchemeTask.request.url, address.scheme == Self.scheme, address.host == "local" else {
                throw EngineError.invalidInput(.malformed("HTML resource URL is unsupported"))
            }
            requestCount += 1
            guard requestCount <= Self.maximumRequests else {
                throw EngineError.invalidInput(.malformed("HTML exceeds 256 resource requests"))
            }
            let bytes: Data
            let mime: String
            if address.path == "/document.html", !mainLoaded {
                mainLoaded = true
                bytes = html
                mime = "text/html"
            } else {
                let resource = directory.appending(path: String(address.path.dropFirst()))
                    .resolvingSymlinksInPath().standardizedFileURL
                guard resource.path.hasPrefix(directory.path + "/"),
                    Self.allowedExtensions.contains(resource.pathExtension.lowercased()),
                    let resourceMIME = UTType(filenameExtension: resource.pathExtension)?.preferredMIMEType
                else {
                    throw EngineError.invalidInput(
                        .malformed("HTML resources must be static files inside the source folder"))
                }
                bytes = try ConversionInput.read(resource)
                mime = resourceMIME
            }
            guard bytes.count <= Self.maximumResourceBytes - byteCount else {
                throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(Self.maximumResourceBytes)))
            }
            byteCount += bytes.count
            guard
                let response = HTTPURLResponse(
                    url: address, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime == "text/html" ? "text/html; charset=utf-8" : mime,
                        "Content-Security-Policy": Self.contentPolicy,
                    ])
            else { throw EngineError.decodeFailed("HTML response headers are unavailable") }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(bytes)
            urlSchemeTask.didFinish()
        } catch {
            failure = error
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
