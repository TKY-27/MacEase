import AppKit
import Engine
import SwiftUI
import WebKit
import os

// One-way; network resets on reselection.
struct PreviewWebPolicy: Hashable, Sendable {
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

    // Blocks scripted anchor clicks from preconnecting offline.
    private static let offlineScriptClickGuard = """
        (() => {
          const stop = (event) => {
            event.preventDefault();
            event.stopImmediatePropagation();
          };
          window.addEventListener('click', stop, true);
          window.addEventListener('submit', stop, true);
          const isNav = (node) =>
            node instanceof Element && (node instanceof SVGAElement || node.closest('a, area') !== null);
          const originalClick = HTMLElement.prototype.click;
          Object.defineProperty(HTMLElement.prototype, 'click', {
            value: function() {
              if (isNav(this)) return;
              return originalClick.apply(this, arguments);
            },
            writable: false,
            configurable: false
          });
          const originalDispatch = EventTarget.prototype.dispatchEvent;
          Object.defineProperty(EventTarget.prototype, 'dispatchEvent', {
            value: function(event) {
              if (event && event.type === 'click' && isNav(this)) return false;
              return originalDispatch.apply(this, arguments);
            },
            writable: false,
            configurable: false
          });
        })();
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
        if !reach.allowsNetwork, scripts {
            // Lockdown Mode removes WebRTC and WebTransport.
            configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: offlineScriptClickGuard, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                    in: .page))
        }
        configuration.userContentController.add(rules)
        return configuration
    }

    static func make(for page: PreviewWebViewer.Page) async throws -> WKWebViewConfiguration {
        switch page {
        case .file(_, _, let policy, _):
            try await make(scripts: policy.scripts, reach: policy.network ? .network : .localFiles)
        case .inline(_, let policy):
            try await make(scripts: policy.scripts, reach: policy.network ? .inlineNetwork : .inline)
        case .generated:
            try await make(reach: .inline)
        }
    }

    // Home-folder files get no folder access.
    nonisolated static func folderReadAccess(
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

    // Returns false when the file changed.
    @discardableResult
    static func load(_ page: PreviewWebViewer.Page, in browser: WKWebView) -> Bool {
        switch page {
        case .file(let url, let readAccess, _, let expectedStamp):
            if let expectedStamp, !PreviewTrust.isUnchangedUnquarantined(url, expectedStamp: expectedStamp) {
                return false
            }
            browser.loadFileURL(url, allowingReadAccessTo: readAccess)
            return true
        case .inline(let html, _), .generated(let html):
            browser.loadHTMLString(html, baseURL: nil)
            return true
        }
    }

    static func permitsNavigation(to destination: URL, page: PreviewWebViewer.Page) -> Bool {
        switch page {
        case .generated, .inline: destination.absoluteString == "about:blank"
        case .file(let source, _, _, _):
            destination.isFileURL && destination.host == source.host && destination.query == source.query
                && destination.standardizedFileURL.path == source.standardizedFileURL.path
        }
    }
}

struct PreviewWebViewer: View {
    // Generated pages are sealed and scriptless.
    enum Page: Hashable, Sendable {
        case file(URL, readAccess: URL, PreviewWebPolicy, expectedStamp: FileStamp? = nil)
        case inline(String, PreviewWebPolicy)
        case generated(String)

        var allowsNetwork: Bool {
            switch self {
            case .file(_, _, let policy, _), .inline(_, let policy): policy.network
            case .generated: false
            }
        }
    }

    let page: Page
    var onStaleFile: (() -> Void)?
    @State private var configuration: WKWebViewConfiguration?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                PreviewFailure()
            } else if let configuration {
                PreviewBrowser(page: page, configuration: configuration, failed: $failed, onStaleFile: onStaleFile)
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
    let onStaleFile: (() -> Void)?

    func makeCoordinator() -> PreviewWebDelegate { PreviewWebDelegate(page: page, failed: $failed) }

    func makeNSView(context: Context) -> PreviewWebContainerView {
        let container = PreviewWebContainerView(
            frame: .zero, configuration: configuration, interactive: page.allowsNetwork)
        container.webView.navigationDelegate = context.coordinator
        container.webView.uiDelegate = context.coordinator
        if !PreviewWebConfiguration.load(page, in: container.webView) {
            if let onStaleFile {
                Task { @MainActor in onStaleFile() }
            }
        }
        return container
    }

    func updateNSView(_ container: PreviewWebContainerView, context: Context) {
        container.setInteractive(page.allowsNetwork)
    }

    static func dismantleNSView(_ container: PreviewWebContainerView, coordinator: PreviewWebDelegate) {
        container.tearDown()
    }
}

// AppKit layer enforcing view-only offline previews.
@MainActor
final class PreviewWebContainerView: NSView {
    let webView: PreviewWKWebView
    let inputShield: PreviewInputShieldView

    init(frame: NSRect, configuration: WKWebViewConfiguration, interactive: Bool) {
        webView = PreviewWKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        inputShield = PreviewInputShieldView(frame: NSRect(origin: .zero, size: frame.size), webView: webView)
        super.init(frame: frame)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        inputShield.autoresizingMask = [.width, .height]
        addSubview(webView)
        addSubview(inputShield)
        setInteractive(interactive)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setInteractive(_ interactive: Bool) {
        webView.isInteractive = interactive
        inputShield.isHidden = interactive
        if !interactive {
            webView.unregisterDraggedTypes()
            if window?.firstResponder === webView { window?.makeFirstResponder(nil) }
        }
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.configuration.userContentController.removeAllUserScripts()
    }
}

@MainActor
final class PreviewWKWebView: WKWebView {
    var isInteractive = true

    override var acceptsFirstResponder: Bool { isInteractive && super.acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool { isInteractive && super.becomeFirstResponder() }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else { return }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        super.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isInteractive else { return }
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        super.rightMouseDragged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isInteractive else { return }
        super.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        super.otherMouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isInteractive else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard isInteractive else { return }
        super.keyUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        isInteractive && super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        isInteractive ? super.menu(for: event) : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isInteractive ? super.draggingEntered(sender) : []
    }
}

// Forwards only scroll and magnify offline.
@MainActor
final class PreviewInputShieldView: NSView {
    private weak var webView: PreviewWKWebView?

    init(frame: NSRect, webView: PreviewWKWebView) {
        self.webView = webView
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func scrollWheel(with event: NSEvent) { webView?.scrollWheel(with: event) }

    override func magnify(with event: NSEvent) { webView?.magnify(with: event) }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
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
