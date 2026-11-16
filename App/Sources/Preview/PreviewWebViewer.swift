import Engine
import SwiftUI
import WebKit
import os

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

    static func make(scripts: Bool = false, network: Bool = false) async throws -> WKWebViewConfiguration {
        guard let store = WKContentRuleListStore.default(),
            let rules = try await store.compileContentRuleList(
                forIdentifier: network ? "MacEasePreviewOnline" : "MacEasePreviewOffline",
                encodedContentRuleList: network ? onlineRules : offlineRules)
        else { throw CocoaError(.featureUnsupported) }
        try Task.checkCancellation()
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: scripts)
        configuration.userContentController.add(rules)
        return configuration
    }

    static func permitsNavigation(to destination: URL, source: URL, generated: Bool) -> Bool {
        if generated { return destination.absoluteString == "about:blank" }
        return destination.isFileURL && destination.host == source.host
            && destination.standardizedFileURL.path == source.standardizedFileURL.path
    }
}

struct PreviewWebViewer: View {
    let url: URL
    let html: String?
    let scripts: Bool
    let network: Bool
    @State private var configuration: WKWebViewConfiguration?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                PreviewFailure()
            } else if let configuration {
                PreviewBrowser(url: url, html: html, configuration: configuration, failed: $failed)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            do {
                let configured = try await PreviewWebConfiguration.make(scripts: scripts, network: network)
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
    let url: URL
    let html: String?
    let configuration: WKWebViewConfiguration
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(source: url, generated: html != nil, failed: $failed) }

    func makeNSView(context: Context) -> WKWebView {
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = context.coordinator
        browser.uiDelegate = context.coordinator
        browser.allowsBackForwardNavigationGestures = false
        browser.allowsLinkPreview = false
        if let html {
            browser.loadHTMLString(html, baseURL: nil)
        } else {
            browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
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
        let source: URL
        let generated: Bool
        var failed: Binding<Bool>

        init(source: URL, generated: Bool, failed: Binding<Bool>) {
            self.source = source
            self.generated = generated
            self.failed = failed
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            guard !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true,
                navigationAction.navigationType != .formSubmitted,
                navigationAction.navigationType != .formResubmitted,
                let destination = navigationAction.request.url,
                PreviewWebConfiguration.permitsNavigation(to: destination, source: source, generated: generated)
            else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
            -> WKNavigationResponsePolicy
        {
            guard navigationResponse.canShowMIMEType, navigationResponse.isForMainFrame,
                let destination = navigationResponse.response.url,
                PreviewWebConfiguration.permitsNavigation(to: destination, source: source, generated: generated),
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
