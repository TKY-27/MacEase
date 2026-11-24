import Engine
import Network
import SwiftUI
import WebKit
import os

// One-way; network resets on reselection.
struct PreviewWebPolicy: Hashable {
    let restricted: Bool
    private(set) var scripts: Bool
    private(set) var network = false

    init(trust: PreviewTrust, scriptsConsented: Bool) {
        restricted = trust.restricted
        scripts = !restricted && (trust.level == .trusted || scriptsConsented)
    }

    var offersScripts: Bool { !restricted && !scripts }
    var offersNetwork: Bool { !restricted && !network }

    mutating func allowScripts() {
        guard !restricted else { return }
        scripts = true
    }

    mutating func allowNetwork() {
        guard !restricted else { return }
        scripts = true
        network = true
    }
}

@MainActor
enum PreviewWebConfiguration {
    static let offlineRules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}
        ]
        """
    // Generated pages may only use inline data.
    private static let inlineRules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}
        ]
        """
    private static let inlineOnlineRules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^https?:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^wss?:"},"action":{"type":"ignore-previous-rules"}}
        ]
        """
    private static let onlineRules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^https?:"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^wss?:"},"action":{"type":"ignore-previous-rules"}}
        ]
        """

    // Prevents link-click speculative TCP preconnect offline.
    private static let offlineNavigationGuard = """
        document.addEventListener('click', (event) => {
          const anchor = event.target && event.target.closest ? event.target.closest('a[href], area[href]') : null;
          if (!anchor) return;
          const href = (anchor.getAttribute('href') || '').trim();
          if (!href.startsWith('#')) { event.preventDefault(); event.stopImmediatePropagation(); }
        }, true);
        document.addEventListener('submit', (event) => {
          event.preventDefault();
          event.stopImmediatePropagation();
        }, true);
        """

    enum Reach {
        case inline, inlineNetwork, localFiles, network

        var allowsNetwork: Bool { self == .network || self == .inlineNetwork }
    }

    static func make(scripts: Bool = false, reach: Reach = .localFiles) async throws -> WKWebViewConfiguration {
        let (identifier, encoded) =
            switch reach {
            case .inline: ("MacEasePreviewInline", inlineRules)
            case .inlineNetwork: ("MacEasePreviewInlineOnline", inlineOnlineRules)
            case .localFiles: ("MacEasePreviewOffline", offlineRules)
            case .network: ("MacEasePreviewOnline", onlineRules)
            }
        guard let store = WKContentRuleListStore.default(),
            let rules = try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: encoded)
        else { throw CocoaError(.featureUnsupported) }
        try Task.checkCancellation()
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: scripts)
        if !reach.allowsNetwork {
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: .any))
            proxy.allowFailover = false
            configuration.websiteDataStore.proxyConfigurations = [proxy]
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: offlineNavigationGuard, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                    in: .defaultClient))
            if scripts {
                // Lockdown Mode removes WebRTC and WebTransport.
                configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
            }
        }
        configuration.userContentController.add(rules)
        return configuration
    }

    static func make(for page: PreviewWebViewer.Page) async throws -> WKWebViewConfiguration {
        switch page {
        case .file(_, _, let policy):
            try await make(scripts: policy.scripts, reach: policy.network ? .network : .localFiles)
        case .inline(_, let policy):
            try await make(scripts: policy.scripts, reach: policy.network ? .inlineNetwork : .inline)
        case .generated:
            try await make(reach: .inline)
        }
    }

    // Home-folder files get no folder access.
    static func folderReadAccess(
        for url: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL
        let folder = resolvedFile.deletingLastPathComponent().standardizedFileURL
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let folderPath = folder.path
        if folderPath == "/" || folderPath == home || home.hasPrefix(folderPath + "/") {
            return nil
        }
        return folder
    }

    static func load(_ page: PreviewWebViewer.Page, in browser: WKWebView) {
        switch page {
        case .file(let url, let readAccess, _): browser.loadFileURL(url, allowingReadAccessTo: readAccess)
        case .inline(let html, _), .generated(let html): browser.loadHTMLString(html, baseURL: nil)
        }
    }

    static func permitsNavigation(to destination: URL, page: PreviewWebViewer.Page) -> Bool {
        switch page {
        case .generated, .inline: destination.absoluteString == "about:blank"
        case .file(let source, _, _):
            destination.isFileURL && destination.host == source.host && destination.query == source.query
                && destination.standardizedFileURL.path == source.standardizedFileURL.path
        }
    }
}

struct PreviewWebViewer: View {
    // Generated pages are sealed and scriptless.
    enum Page: Hashable {
        case file(URL, readAccess: URL, PreviewWebPolicy)
        case inline(String, PreviewWebPolicy)
        case generated(String)
    }

    let page: Page
    @State private var configuration: WKWebViewConfiguration?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                PreviewFailure()
            } else if let configuration {
                PreviewBrowser(page: page, configuration: configuration, failed: $failed)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            do {
                let configured = try await PreviewWebConfiguration.make(for: page)
                try Task.checkCancellation()
                configuration = configured
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                Logger(category: "finder-preview").error(
                    "Preview web restrictions failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        .onDisappear { configuration = nil }
    }
}

private struct PreviewBrowser: NSViewRepresentable {
    let page: PreviewWebViewer.Page
    let configuration: WKWebViewConfiguration
    @Binding var failed: Bool

    func makeCoordinator() -> PreviewWebDelegate { PreviewWebDelegate(page: page, failed: $failed) }

    func makeNSView(context: Context) -> WKWebView {
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = context.coordinator
        browser.uiDelegate = context.coordinator
        browser.allowsBackForwardNavigationGestures = false
        browser.allowsLinkPreview = false
        PreviewWebConfiguration.load(page, in: browser)
        return browser
    }

    func updateNSView(_ browser: WKWebView, context: Context) {}

    static func dismantleNSView(_ browser: WKWebView, coordinator: PreviewWebDelegate) {
        browser.stopLoading()
        browser.navigationDelegate = nil
        browser.uiDelegate = nil
        browser.configuration.userContentController.removeAllContentRuleLists()
    }
}

@MainActor
final class PreviewWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let webKitErrorDomain = "WebKitErrorDomain"
    private static let frameLoadInterruptedCode = 102

    let page: PreviewWebViewer.Page
    var failed: Binding<Bool>
    var onFinishNavigation: (() -> Void)?
    var onFailNavigation: ((any Error) -> Void)?

    init(page: PreviewWebViewer.Page, failed: Binding<Bool>) {
        self.page = page
        self.failed = failed
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        let method = navigationAction.request.httpMethod?.uppercased()
        guard !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true,
            navigationAction.navigationType != .formSubmitted,
            navigationAction.navigationType != .formResubmitted,
            method == nil || method == "GET",
            let destination = navigationAction.request.url,
            PreviewWebConfiguration.permitsNavigation(to: destination, page: page)
        else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        guard navigationResponse.canShowMIMEType, navigationResponse.isForMainFrame,
            let destination = navigationResponse.response.url,
            PreviewWebConfiguration.permitsNavigation(to: destination, page: page),
            (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
                == nil
        else { return .cancel }
        return .allow
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinishNavigation?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        report(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
    ) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed.wrappedValue = true }

    private func report(_ error: any Error) {
        let nsError = error as NSError
        if (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == Self.webKitErrorDomain && nsError.code == Self.frameLoadInterruptedCode)
        {
            return
        }
        failed.wrappedValue = true
        onFailNavigation?(error)
        Logger(category: "finder-preview").error(
            "Preview web load failed: \(error.localizedDescription, privacy: .private)")
    }
}
