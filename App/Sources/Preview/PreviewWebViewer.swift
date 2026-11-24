import AppKit
import Engine
import Network
import SwiftUI
import WebKit
import os

// Scripts without network access is unrepresentable.
enum PreviewWebPolicy: Hashable, Sendable {
    case restricted
    case staticPreview
    case interactive

    init(trust: PreviewTrust, interactiveConsented: Bool) {
        if trust.restricted {
            self = .restricted
        } else if trust.level == .trusted || interactiveConsented {
            self = .interactive
        } else {
            self = .staticPreview
        }
    }

    var allowsInteractive: Bool { self == .interactive }
    var offersInteractive: Bool { self == .staticPreview }
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

    // Isolated world; page content cannot undo it.
    static let staticPreviewNeutralizer = #"""
        (() => {
          const svgNS = 'http://www.w3.org/2000/svg';
          const xlinkNS = 'http://www.w3.org/1999/xlink';
          const run = (action) => { try { action(); } catch {} };
          const setSVGTitle = (el, text) => {
            if (!text || el.querySelector(':scope > title')) return;
            const title = document.createElementNS(svgNS, 'title');
            title.textContent = text;
            el.appendChild(title);
          };
          const neutralize = (root) => {
            for (const el of root.querySelectorAll('a[href], area[href], math[href], math [href]')) {
              let target = '';
              run(() => { target = el.getAttribute('href') ?? ''; });
              run(() => {
                if (!el.style) return;
                const style = getComputedStyle(el);
                if (!el.style.color && style.color) el.style.color = style.color;
                if (!el.style.textDecorationLine && style.textDecorationLine) {
                  el.style.textDecorationLine = style.textDecorationLine;
                }
              });
              const fragment = el instanceof HTMLElement && el.localName === 'a' && target.startsWith('#');
              run(() => {
                if (fragment) {
                  el.dataset.maceaseFragment = target.slice(1);
                  el.tabIndex = 0;
                  el.setAttribute('role', 'link');
                  if (el.style) el.style.cursor = 'pointer';
                } else {
                  if (el instanceof HTMLElement) {
                    if (!el.title) el.title = (typeof el.href === 'string' && el.href) || target;
                  } else if (el.namespaceURI === svgNS) {
                    setSVGTitle(el, (typeof el.href?.baseVal === 'string' && el.href.baseVal) || target);
                  }
                  el.setAttribute('aria-disabled', 'true');
                }
              });
              run(() => {
                el.removeAttribute('href');
                el.removeAttribute('ping');
                el.removeAttribute('download');
              });
            }
            for (const el of root.querySelectorAll('a, math, math *')) {
              run(() => {
                if (el.hasAttributeNS(xlinkNS, 'href')) {
                  const target = el.getAttributeNS(xlinkNS, 'href') ?? '';
                  if (el.namespaceURI === svgNS) setSVGTitle(el, target);
                  el.removeAttributeNS(xlinkNS, 'href');
                  el.setAttribute('aria-disabled', 'true');
                }
              });
            }
            for (const form of root.querySelectorAll('form')) {
              run(() => form.removeAttribute('action'));
            }
            for (const ctrl of root.querySelectorAll('button, input, select, textarea')) {
              run(() => {
                ctrl.removeAttribute('formaction');
                ctrl.disabled = true;
              });
            }
            for (const el of root.querySelectorAll('[contenteditable]')) {
              run(() => el.removeAttribute('contenteditable'));
            }
            for (const host of root.querySelectorAll('*')) {
              run(() => { if (host.shadowRoot) neutralize(host.shadowRoot); });
            }
          };
          neutralize(document);
        })();
        """#

    // Before parsing; covers closed shadow roots.
    static let staticPreviewGuard = #"""
        (() => {
          const blockedDrag =
            'a, area, img, picture, svg, video, audio, object, embed, math, [href], [draggable="true"]';
          const xlinkNS = 'http://www.w3.org/1999/xlink';
          const slug = (text) => text.trim().toLowerCase()
            .replace(/[^\p{L}\p{M}\p{N}\s_-]/gu, '').replace(/\s/g, '-');
          const headingFor = (fragment) => {
            const seen = new Map();
            for (const heading of document.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
              const base = slug(heading.textContent);
              const count = seen.get(base) ?? 0;
              seen.set(base, count + 1);
              if ((count ? `${base}-${count}` : base) === fragment) return heading;
            }
            return null;
          };
          const scrollToFragment = (encoded) => {
            let fragment = encoded;
            try { fragment = decodeURIComponent(encoded); } catch {}
            if (fragment === '' || fragment.toLowerCase() === 'top') {
              scrollTo(0, 0);
              return;
            }
            const target = document.getElementById(fragment)
              ?? document.getElementsByName(fragment)[0] ?? headingFor(fragment.toLowerCase());
            target?.scrollIntoView({block: 'start'});
          };
          const origin = (event) => event.target instanceof Element ? event.target : event.target?.parentElement;
          const fragmentLink = (event) => origin(event)?.closest('[data-macease-fragment]');
          addEventListener('click', (event) => {
            event.preventDefault();
            const link = fragmentLink(event);
            if (link) {
              scrollToFragment(link.getAttribute('data-macease-fragment') ?? '');
              return;
            }
            const details = origin(event)?.closest('summary')?.parentElement;
            if (details?.localName === 'details') details.open = !details.open;
          }, true);
          addEventListener('auxclick', (event) => event.preventDefault(), true);
          addEventListener('keydown', (event) => {
            if (event.key !== 'Enter') return;
            event.preventDefault();
            const link = fragmentLink(event);
            if (link) scrollToFragment(link.getAttribute('data-macease-fragment') ?? '');
          }, true);
          addEventListener('beforeinput', (event) => event.preventDefault(), true);
          addEventListener('submit', (event) => event.preventDefault(), true);
          addEventListener('dragstart', (event) => {
            const path = event.composedPath();
            const first = path[0] ?? event.target;
            if (!first || first.nodeType !== Node.TEXT_NODE) {
              event.preventDefault();
              return;
            }
            for (const node of path) {
              if (node instanceof Element
                  && (node.matches(blockedDrag) || node.hasAttributeNS(xlinkNS, 'href'))) {
                event.preventDefault();
                return;
              }
            }
          }, true);
        })();
        """#

    private enum Reach {
        case inline, inlineNetwork, localFiles, network

        var allowsInteractive: Bool { self == .network || self == .inlineNetwork }
    }

    // Blocks host-named preconnects on missed elements.
    static var failClosedProxy: ProxyConfiguration {
        var configuration = ProxyConfiguration(
            socksv5Proxy: NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any))
        configuration.allowFailover = false
        configuration.excludedDomains = []
        return configuration
    }

    private static func make(reach: Reach) async throws -> WKWebViewConfiguration {
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
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: reach.allowsInteractive)
        if !reach.allowsInteractive {
            configuration.websiteDataStore.proxyConfigurations = [failClosedProxy]
            for (source, injectionTime) in [
                (staticPreviewGuard, WKUserScriptInjectionTime.atDocumentStart),
                (staticPreviewNeutralizer, .atDocumentEnd),
            ] {
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: source, injectionTime: injectionTime, forMainFrameOnly: false, in: .defaultClient))
            }
        }
        configuration.userContentController.add(rules)
        return configuration
    }

    static func make(for page: PreviewWebViewer.Page) async throws -> WKWebViewConfiguration {
        switch page {
        case .file(_, _, let policy, _):
            try await make(reach: policy.allowsInteractive ? .network : .localFiles)
        case .inline(_, let policy):
            try await make(reach: policy.allowsInteractive ? .inlineNetwork : .inline)
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
            guard PreviewTrust.isUnchangedUnquarantined(url, expectedStamp: expectedStamp) else {
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
        case file(URL, readAccess: URL, PreviewWebPolicy, expectedStamp: PreviewFileStamp)
        case inline(String, PreviewWebPolicy)
        case generated(String)

        var allowsInteractive: Bool {
            switch self {
            case .file(_, _, let policy, _), .inline(_, let policy): policy.allowsInteractive
            case .generated: false
            }
        }
    }

    let page: Page
    var find: PreviewFind?
    var onStaleFile: (() -> Void)?
    @State private var configuration: WKWebViewConfiguration?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                PreviewFailure()
            } else if let configuration {
                PreviewBrowser(
                    page: page, configuration: configuration, find: find, failed: $failed, onStaleFile: onStaleFile)
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
    let find: PreviewFind?
    @Binding var failed: Bool
    let onStaleFile: (() -> Void)?

    func makeCoordinator() -> PreviewWebDelegate { PreviewWebDelegate(page: page, failed: $failed) }

    func makeNSView(context: Context) -> PreviewWebContainerView {
        let container = PreviewWebContainerView(
            frame: .zero, configuration: configuration, interactive: page.allowsInteractive)
        container.find = find
        context.coordinator.loaded = { [weak container] in container?.attachFind() }
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
        container.setInteractive(page.allowsInteractive)
    }

    static func dismantleNSView(_ container: PreviewWebContainerView, coordinator: PreviewWebDelegate) {
        container.tearDown()
    }
}

// Static pages stay selectable but inert.
@MainActor
final class PreviewWebContainerView: NSView, PreviewFindTarget {
    let webView: PreviewWKWebView
    weak var find: PreviewFind?

    init(frame: NSRect, configuration: WKWebViewConfiguration, interactive: Bool) {
        webView = PreviewWKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        addSubview(webView)
        setInteractive(interactive)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setInteractive(_ interactive: Bool) {
        webView.isInteractive = interactive
        if !interactive { webView.unregisterDraggedTypes() }
    }

    func attachFind() { find?.attach(self) }

    // WebKit reports no match count.
    func find(_ query: String, direction: PreviewFindDirection, restart: Bool) async -> PreviewFindOutcome {
        let configuration = WKFindConfiguration()
        configuration.backwards = direction == .backward
        do {
            // Typing more keeps the current match.
            if restart {
                _ = try await webView.evaluateJavaScript(
                    "getSelection().isCollapsed || getSelection().collapseToStart(), true", in: nil,
                    contentWorld: .defaultClient)
                guard !Task.isCancelled else { return .notFound }
            }
            let result = try await webView.find(query, configuration: configuration)
            guard !Task.isCancelled else { return .notFound }
            return PreviewFindOutcome(found: result.matchFound)
        } catch {
            guard !Task.isCancelled else { return .notFound }
            Logger(category: "finder-preview").error(
                "Preview page find failed: \(error.localizedDescription, privacy: .private)")
            return .notFound
        }
    }

    func endFind() { window?.makeFirstResponder(webView) }

    func tearDown() {
        find?.detach(self)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.configuration.userContentController.removeAllUserScripts()
    }
}

@MainActor
final class PreviewWKWebView: WKWebView {
    // WebKit's identifiers have no public constants.
    private static let staticMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSpeechMenu",
    ]
    private static let shareMenuItem = "WKMenuItemIdentifierShareMenu"
    private static let linkMenuItems: Set<String> = [
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierCopyMediaLink",
    ]

    var isInteractive = true

    // Text selection needs key focus.
    override var needsPanelToBecomeKey: Bool { true }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard !isInteractive else { return }
        Self.restrictToSelectionActions(menu)
    }

    // Shared links could be fetched elsewhere.
    static func restrictToSelectionActions(_ menu: NSMenu) {
        let identifiers = Set(menu.items.compactMap { $0.identifier?.rawValue })
        var allowed = staticMenuItems
        if identifiers.isDisjoint(with: linkMenuItems) { allowed.insert(shareMenuItem) }
        for menuItem in menu.items.reversed() where !menuItem.isSeparatorItem {
            if !allowed.contains(menuItem.identifier?.rawValue ?? "") { menu.removeItem(menuItem) }
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        for index in stride(from: menu.items.count - 1, to: 0, by: -1)
        where menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
            menu.removeItem(at: index)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isInteractive ? super.draggingEntered(sender) : []
    }
}

@MainActor
final class PreviewWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let webKitErrorDomain = "WebKitErrorDomain"
    private static let frameLoadInterruptedCode = 102

    let page: PreviewWebViewer.Page
    var failed: Binding<Bool>
    var loaded: (() -> Void)?

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) { loaded?() }

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
        Logger(category: "finder-preview").error(
            "Preview web load failed: \(error.localizedDescription, privacy: .private)")
    }
}
