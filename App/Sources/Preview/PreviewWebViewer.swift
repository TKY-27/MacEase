import Engine
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

    enum Reach {
        case inline, localFiles, network
    }

    static func make(scripts: Bool = false, reach: Reach = .localFiles) async throws -> WKWebViewConfiguration {
        let (identifier, encoded) =
            switch reach {
            case .inline: ("MacEasePreviewInline", inlineRules)
            case .localFiles: ("MacEasePreviewOffline", offlineRules)
            case .network: ("MacEasePreviewOnline", onlineRules)
            }
        guard let store = WKContentRuleListStore.default(),
            let rules = try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: encoded)
        else { throw CocoaError(.featureUnsupported) }
        try Task.checkCancellation()
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: scripts)
        configuration.userContentController.add(rules)
        return configuration
    }

    static func make(for page: PreviewWebViewer.Page) async throws -> WKWebViewConfiguration {
        switch page {
        case .file(_, let policy):
            try await make(scripts: policy.scripts, reach: policy.network ? .network : .localFiles)
        case .generated: try await make(reach: .inline)
        }
    }

    static func load(_ page: PreviewWebViewer.Page, in browser: WKWebView) {
        switch page {
        case .file(let url, _): browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case .generated(let html): browser.loadHTMLString(html, baseURL: nil)
        }
    }

    static func permitsNavigation(to destination: URL, page: PreviewWebViewer.Page) -> Bool {
        switch page {
        case .generated: destination.absoluteString == "about:blank"
        case .file(let source, _):
            destination.isFileURL && destination.host == source.host
                && destination.standardizedFileURL.path == source.standardizedFileURL.path
        }
    }
}

struct PreviewWebViewer: View {
    // Generated pages are sealed and scriptless.
    enum Page: Hashable {
        case file(URL, PreviewWebPolicy)
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

    func makeCoordinator() -> Coordinator { Coordinator(page: page, failed: $failed) }

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

    static func dismantleNSView(_ browser: WKWebView, coordinator: Coordinator) {
        browser.stopLoading()
        browser.navigationDelegate = nil
        browser.uiDelegate = nil
        browser.configuration.userContentController.removeAllContentRuleLists()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let page: PreviewWebViewer.Page
        var failed: Binding<Bool>

        init(page: PreviewWebViewer.Page, failed: Binding<Bool>) {
            self.page = page
            self.failed = failed
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            guard !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true,
                navigationAction.navigationType != .formSubmitted,
                navigationAction.navigationType != .formResubmitted,
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
            if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                return
            }
            failed.wrappedValue = true
            Logger(category: "finder-preview").error(
                "Preview web load failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
