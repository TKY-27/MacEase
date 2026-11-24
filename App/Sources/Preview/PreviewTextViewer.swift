import AppKit
import Engine
import SwiftUI
import os

private struct PreviewTextRequest: Equatable {
    let loaded: Bool
    let encoding: PreviewEncoding
    let rich: Bool
    let reloadToken: Int
}

// Evaluates HTML trust fresh on each load.
enum PreviewHTMLSnapshot {
    // File loads stream, skipping the text buffer.
    static let maximumFileBytes: Int64 = 64 * 1024 * 1024

    struct Prepared: Equatable, Sendable {
        let id: UUID
        let trust: PreviewTrust
        let policy: PreviewWebPolicy
        let page: PreviewWebViewer.Page?
        let limitBytes: Int64?

        var truncated: Bool { limitBytes != nil }
    }

    static func prepare(
        url: URL,
        trustedFolders: [String],
        scriptConsent: Set<PreviewScriptConsentKey>,
        encoding: PreviewEncoding = .automatic,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Prepared {
        let (source, trust, stamp) = try PreviewTextSource.readSnapshot(url, trustedFolders: trustedFolders)
        let consented = scriptConsent.contains(PreviewScriptConsentKey(resolvedPath: trust.resolvedPath, stamp: stamp))
        let policy = PreviewWebPolicy(trust: trust, interactiveConsented: consented)
        let resolved = URL(fileURLWithPath: trust.resolvedPath).standardizedFileURL
        if !trust.restricted,
            let readAccess = PreviewWebConfiguration.folderReadAccess(for: resolved, homeDirectory: homeDirectory)
        {
            guard let size = stamp.stamp.size, size <= maximumFileBytes else {
                return Prepared(
                    id: UUID(), trust: trust, policy: policy, page: nil, limitBytes: maximumFileBytes)
            }
            return Prepared(
                id: UUID(), trust: trust, policy: policy,
                page: .file(resolved, readAccess: readAccess, policy, expectedStamp: stamp),
                limitBytes: nil)
        }
        if source.truncated {
            return Prepared(
                id: UUID(), trust: trust, policy: policy, page: nil, limitBytes: Int64(PreviewTextSource.maximumBytes))
        }
        let html = try source.decoded(as: encoding)
        let page: PreviewWebViewer.Page = trust.restricted ? .generated(html) : .inline(html, policy)
        return Prepared(id: UUID(), trust: trust, policy: policy, page: page, limitBytes: nil)
    }
}

struct PreviewTextRendering: Sendable {
    private static let markdownStyle = """
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.6 -apple-system, sans-serif; margin: 16px; overflow-wrap: anywhere; }
        h1, h2 { border-bottom: 1px solid #8884; padding-bottom: .3em; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.3em; }
        code, pre { font: 12px/1.5 ui-monospace, Menlo, monospace; }
        code { background: #8881; padding: .1em .3em; border-radius: 4px; }
        pre { background: #8881; padding: 10px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        table { border-collapse: collapse; display: block; max-width: 100%; overflow-x: auto; }
        th, td { border: 1px solid #8884; padding: 4px 8px; }
        img { max-width: 100%; }
        a { color: LinkText; text-decoration: underline; text-underline-offset: .15em; }
        blockquote { margin: 0; padding-left: 1em; border-left: 3px solid #8886; color: #888; }
        </style>
        """
    let id = UUID()
    let text: String
    let tokens: [PreviewToken]
    let lineStarts: [Int]
    let html: Bool
    // Nil for converted or rendered text.
    let decodedAs: PreviewEncoding?

    static func make(
        source: PreviewTextSource, encoding: PreviewEncoding, rich: Bool, kind: PreviewKind, url: URL,
        restricted: Bool
    ) throws -> Self {
        try Task.checkCancellation()
        let text: String
        var decodedAs: PreviewEncoding?
        let html = rich && (kind == .markdown || kind == .svg || (kind == .html && restricted))
        var language = PreviewLanguage.resolve(url.pathExtension, fileName: url.lastPathComponent)
        if kind == .propertyList && (rich || source.binaryPropertyList) {
            guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
            text = try PropertyListConversion.json(from: source.bytes, indent: "  ")
            language = .json
        } else if html && kind == .svg {
            guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
            text = svgPage(source.bytes)
        } else {
            let decoded = try source.decoded(as: encoding)
            if !html {
                decodedAs = encoding == .automatic ? source.detectedEncoding : encoding
            }
            if rich && kind == .json {
                guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
                text = try JSONFormatter.formatted(decoded)
                language = .json
            } else if html && kind == .markdown {
                text = try PreviewMarkdownRenderer.html(
                    decoded, markdownURL: url, directory: source.parentDirectory?.rawValue, restricted: restricted
                )
                .replacingOccurrences(of: "</head>", with: markdownStyle + "</head>")
            } else if html {
                guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
                text = decoded
            } else {
                text = decoded
            }
        }
        let tokens = html ? [] : try PreviewTokenizer.tokens(text, language: language)
        var lineStarts = [0]
        let units = Array(text.utf16)
        for (offset, unit) in units.enumerated() {
            if unit == 10 || (unit == 13 && (offset + 1 == units.count || units[offset + 1] != 10)) {
                lineStarts.append(offset + 1)
            }
        }
        try Task.checkCancellation()
        return Self(text: text, tokens: tokens, lineStarts: lineStarts, html: html, decodedAs: decodedAs)
    }

    // An image element never runs SVG scripts.
    static func svgPage(_ svg: Data) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; height: 100%; }
        body { box-sizing: border-box; padding: 16px; display: flex; align-items: center; justify-content: center;
          background: repeating-conic-gradient(#8881 0 25%, transparent 0 50%) 0 0 / 16px 16px; }
        img { width: 100%; height: 100%; object-fit: contain; }
        </style></head><body><img alt="" src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
        """
    }
}

private enum PreviewTextFailure: Equatable {
    case tooLarge(limitBytes: Int64)
    case unreadable
}

struct PreviewTextViewer: View {
    let url: URL
    let kind: PreviewKind
    let trust: PreviewTrust
    let settings: FinderPreviewSettings
    @Binding var scriptConsent: Set<PreviewScriptConsentKey>
    @State private var source: PreviewTextSource?
    @State private var rendering: PreviewTextRendering?
    @State private var htmlLoad: PreviewHTMLSnapshot.Prepared?
    @State private var currentTrust: PreviewTrust
    @State private var encoding = PreviewEncoding.automatic
    @State private var rich: Bool
    @State private var reloadToken = 0
    @State private var failure: PreviewTextFailure?
    @State private var find = PreviewFind()

    init(
        url: URL, kind: PreviewKind, trust: PreviewTrust, settings: FinderPreviewSettings,
        scriptConsent: Binding<Set<PreviewScriptConsentKey>>
    ) {
        self.url = url
        self.kind = kind
        self.trust = trust
        self.settings = settings
        _scriptConsent = scriptConsent
        _currentTrust = State(initialValue: trust)
        let consented = trust.consentKey.map { scriptConsent.wrappedValue.contains($0) } ?? false
        let initialPolicy = PreviewWebPolicy(trust: trust, interactiveConsented: consented)
        // Source first unless interactive access is granted.
        _rich = State(initialValue: kind != .html || initialPolicy.allowsInteractive)
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar { HStack(spacing: 8) { controls }.layoutPriority(1) }
            if supportsFind && find.isPresented { PreviewFindBar(find: find) }
            notes
            Group {
                if let failure {
                    failureView(failure)
                } else if kind == .html, rich {
                    if let prepared = htmlLoad, let page = prepared.page {
                        PreviewWebViewer(page: page, find: find, onStaleFile: { reloadToken += 1 }).id(prepared.id)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if let rendering {
                    if rendering.html {
                        PreviewWebViewer(page: .generated(rendering.text), find: supportsFind ? find : nil)
                            .id(rendering.id)
                    } else {
                        PreviewCodeView(
                            rendering: rendering,
                            font: PreviewCodeFont.font(family: settings.codeFontFamily, size: settings.codeFontSize),
                            wrap: settings.wrapLines, find: find)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await read() }
        .task(id: PreviewTextRequest(loaded: source != nil, encoding: encoding, rich: rich, reloadToken: reloadToken)) {
            await render()
        }
        .onChange(of: rich) { _, isRich in
            if !isRich { htmlLoad = nil }
            if !supportsFind { find.dismiss() }
        }
        .onDisappear {
            source = nil
            rendering = nil
            htmlLoad = nil
        }
    }

    private var effectiveTrust: PreviewTrust { htmlLoad?.trust ?? currentTrust }

    private var activePolicy: PreviewWebPolicy? { htmlLoad?.policy }

    private var offersModes: Bool { kind != .text && source?.binaryPropertyList != true }

    private var supportsFind: Bool { !(kind == .svg && rich) }

    private var showsEncodingMenu: Bool {
        source?.binaryPropertyList != true && !(rich && (kind == .html || kind == .markdown || kind == .svg))
    }

    @ViewBuilder private var notes: some View {
        if effectiveTrust.restricted && (kind == .html || kind == .markdown) {
            if kind == .html && rich {
                PreviewNote(
                    symbol: "shield.lefthalf.filled",
                    text: Text(
                        "This file is from the internet. Preview is view-only, and scripts, external content and other files are disabled."
                    ),
                    shortText: Text("From the internet: view-only preview"))
            } else {
                PreviewNote(
                    symbol: "shield.lefthalf.filled",
                    text: Text(
                        "This file is from the internet. Scripts, external content and other files are disabled."),
                    shortText: Text("From the internet: limited preview"))
            }
        } else if kind == .html, rich, let activePolicy {
            switch activePolicy {
            case .staticPreview:
                PreviewNote(
                    symbol: "eye",
                    text: Text("Preview is static and view-only. Scripts and network access are off."),
                    shortText: Text("Static view-only preview"))
            case .interactive:
                PreviewNote(
                    symbol: "network",
                    text: Text("Scripts on this page can connect to the internet."),
                    shortText: Text("Scripts can use the internet"))
            case .restricted:
                EmptyView()
            }
        }
        if source?.truncated == true && failure == nil && !(kind == .html && rich) {
            PreviewNote(symbol: "scissors", text: Text("Showing the first 256 KB"))
        }
    }

    @ViewBuilder private var controls: some View {
        if offersModes {
            ViewThatFits(in: .horizontal) {
                modePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                modePicker.pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
        if kind == .html && rich {
            if let policy = activePolicy, policy.offersInteractive, !effectiveTrust.restricted {
                ViewThatFits(in: .horizontal) {
                    runScriptsButton.labelStyle(.titleOnly)
                    runScriptsButton.labelStyle(.iconOnly)
                }
            }
        } else if showsEncodingMenu {
            encodingMenu
        }
        Spacer(minLength: 0)
        if supportsFind { PreviewFindButton(find: find) }
    }

    private var modePicker: some View {
        Picker("View", selection: $rich) {
            if kind == .json || kind == .propertyList {
                Text("Formatted").tag(true)
            } else {
                Text("Preview").tag(true)
            }
            Text("preview.mode.source").tag(false)
        }
    }

    private var encodingMenu: some View {
        let shown = rendering?.decodedAs.map { Text(verbatim: $0.title) } ?? Text("Encoding")
        return ViewThatFits(in: .horizontal) {
            encodingMenu(label: shown)
            encodingMenu(label: Image(systemName: "textformat"))
        }
        .accessibilityLabel(Text("Encoding"))
        .accessibilityValue(shown)
        .help(Text("Encoding"))
    }

    private func encodingMenu(label: some View) -> some View {
        Menu {
            Picker("Encoding", selection: $encoding) {
                ForEach(PreviewEncoding.allCases, id: \.self) { choice in
                    Text(verbatim: choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            label
        }
        .fixedSize()
    }

    private var runScriptsButton: some View {
        Button {
            if let key = htmlLoad?.trust.consentKey { scriptConsent.insert(key) }
            reloadToken += 1
        } label: {
            Label("Run Scripts with Network Access", systemImage: "network")
        }
        .help(Text("Runs scripts and allows network access for this file until it changes or MacEase quits."))
        .fixedSize()
    }

    private func failureView(_ failure: PreviewTextFailure) -> some View {
        VStack(spacing: 12) {
            failureMessage(failure)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if rich && offersModes {
                Button("Show Source") { rich = false }
            }
        }
        .padding(PreviewLayout.margin)
    }

    private func failureMessage(_ failure: PreviewTextFailure) -> Text {
        let formats = kind == .json || kind == .propertyList
        switch failure {
        case .tooLarge(let limitBytes):
            let size = ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .memory)
            return formats
                ? Text("Files larger than \(size) can't be formatted.")
                : Text("Files larger than \(size) can't be previewed here.")
        case .unreadable where rich && kind != .text:
            return formats ? Text("This file could not be formatted.") : Text("This preview could not be displayed.")
        case .unreadable:
            return showsEncodingMenu
                ? Text("The text could not be decoded. Try another encoding.")
                : Text("The text could not be decoded.")
        }
    }

    private func read() async {
        do {
            let keepParent = kind == .markdown
            let trustedFolders = settings.trustedFolders
            let loaded = try await offMain { [url] in
                try PreviewTextSource.read(url, trustedFolders: trustedFolders, keepParentDirectory: keepParent)
            }
            try Task.checkCancellation()
            if let freshTrust = loaded.trust { currentTrust = freshTrust }
            // HTML Preview may stream the whole file.
            if loaded.truncated && !loaded.binaryPropertyList && kind != .html { rich = false }
            source = loaded
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = .unreadable
            Logger(category: "finder-preview").error(
                "Preview text read failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func render() async {
        rendering = nil
        htmlLoad = nil
        failure = nil
        if kind == .html, rich {
            await prepareHTML()
            return
        }
        guard let source else { return }
        let encoding = encoding
        let rich = rich
        do {
            let currentSource: PreviewTextSource
            if kind == .html {
                let trustedFolders = settings.trustedFolders
                let refreshed = try await offMain { [url] in
                    try PreviewTextSource.read(url, trustedFolders: trustedFolders)
                }
                try Task.checkCancellation()
                if let freshTrust = refreshed.trust { currentTrust = freshTrust }
                self.source = refreshed
                currentSource = refreshed
            } else {
                currentSource = source
            }
            let rendered = try await offMain { [kind, url, restricted = currentTrust.restricted] in
                try PreviewTextRendering.make(
                    source: currentSource, encoding: encoding, rich: rich, kind: kind, url: url,
                    restricted: restricted)
            }
            try Task.checkCancellation()
            rendering = rendered
        } catch is CancellationError {
        } catch CocoaError.fileReadTooLarge {
            guard !Task.isCancelled else { return }
            failure = .tooLarge(limitBytes: Int64(PreviewTextSource.maximumBytes))
        } catch {
            guard !Task.isCancelled else { return }
            failure = .unreadable
            Logger(category: "finder-preview").error(
                "Preview text rendering failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func prepareHTML() async {
        let trustedFolders = settings.trustedFolders
        let consent = scriptConsent
        let encoding = encoding
        do {
            let prepared = try await offMain { [url] in
                try PreviewHTMLSnapshot.prepare(
                    url: url, trustedFolders: trustedFolders, scriptConsent: consent, encoding: encoding)
            }
            try Task.checkCancellation()
            currentTrust = prepared.trust
            if let limitBytes = prepared.limitBytes {
                failure = .tooLarge(limitBytes: limitBytes)
                return
            }
            htmlLoad = prepared
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = .unreadable
            Logger(category: "finder-preview").error(
                "Preview HTML load failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

@MainActor
enum PreviewCodeFont {
    static let families = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: regularWeight, size: probeSize)?
            .isFixedPitch == true
    }
    // NSFontManager weight scale; 5 is regular.
    private static let regularWeight = 5
    private static let probeSize: CGFloat = 12

    // Uninstalled families use the system font.
    static func font(family: String, size: Int) -> NSFont {
        let points = CGFloat(size)
        guard !family.isEmpty,
            let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: regularWeight, size: points)
        else { return .monospacedSystemFont(ofSize: points, weight: .regular) }
        return font
    }
}

private struct PreviewCodeView: NSViewRepresentable {
    let rendering: PreviewTextRendering
    let font: NSFont
    let wrap: Bool
    let find: PreviewFind

    final class Coordinator {
        var renderingID: UUID?
        var font: NSFont?
        weak var find: PreviewFind?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = PreviewTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView
        let ruler = PreviewLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = textView
        ruler.clipsToBounds = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            ruler, selector: #selector(PreviewLineRuler.scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PreviewTextView else { return }
        context.coordinator.find = find
        // Identity checks keep large files cheap.
        if context.coordinator.renderingID != rendering.id || context.coordinator.font != font {
            context.coordinator.renderingID = rendering.id
            context.coordinator.font = font
            textView.show(rendering, font: font)
            find.attach(textView)
        }
        if let ruler = scroll.verticalRulerView as? PreviewLineRuler {
            ruler.lineStarts = rendering.lineStarts
            ruler.codeFont = font
        }
        scroll.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(
            width: wrap ? max(1, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        if wrap { textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height)) }
        scroll.verticalRulerView?.needsDisplay = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let textView = scroll.documentView as? PreviewTextView else { return }
        coordinator.find?.detach(textView)
    }
}

final class PreviewTextView: NSTextView, PreviewFindTarget {
    private var contentVersion: UInt64 = 0
    private var matchedQuery: String?
    private var matches: [NSRange] = []
    private var matchIndex: Int?

    func show(_ rendering: PreviewTextRendering, font: NSFont) {
        contentVersion &+= 1
        let styled = NSMutableAttributedString(
            string: rendering.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let sourceUnits = rendering.text as NSString
        for token in rendering.tokens {
            switch token.kind {
            case .keyword:
                styled.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: token.range)
            case .type:
                styled.addAttribute(.foregroundColor, value: Self.typeColor, range: token.range)
            case .string:
                styled.addAttribute(.foregroundColor, value: NSColor.systemRed, range: token.range)
            case .comment:
                styled.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: token.range)
            case .number:
                styled.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: token.range)
            case .diffAdded:
                styled.addAttributes(
                    [.foregroundColor: Self.diffAddedForeground, .backgroundColor: Self.diffAddedBackground],
                    range: token.range)
            case .diffRemoved:
                styled.addAttributes(
                    [.foregroundColor: Self.diffRemovedForeground, .backgroundColor: Self.diffRemovedBackground],
                    range: token.range)
            case .invisible:
                let code = sourceUnits.character(at: token.range.location)
                styled.addAttributes(
                    [
                        .backgroundColor: Self.invisibleBackground,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: Self.invisibleUnderline,
                        .kern: Self.invisibleKern,
                        .toolTip: String(format: "U+%04X", code),
                    ],
                    range: token.range)
            }
        }
        textStorage?.setAttributedString(styled)
        self.font = font
        matchedQuery = nil
        matches = []
        matchIndex = nil
    }

    private static let highContrastAppearances: Set<NSAppearance.Name> = [
        .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark,
    ]
    private static let invisibleKern: CGFloat = 4

    static func diffBackgroundColor(added: Bool, dark: Bool, highContrast: Bool) -> NSColor {
        switch (added, dark, highContrast) {
        case (true, false, false): NSColor(srgbRed: 0.15, green: 0.72, blue: 0.32, alpha: 0.13)
        case (true, false, true): NSColor(srgbRed: 0.15, green: 0.72, blue: 0.32, alpha: 0.24)
        case (true, true, false): NSColor(srgbRed: 0.18, green: 0.78, blue: 0.36, alpha: 0.18)
        case (true, true, true): NSColor(srgbRed: 0.10, green: 0.60, blue: 0.24, alpha: 0.32)
        case (false, false, false): NSColor(srgbRed: 0.88, green: 0.20, blue: 0.20, alpha: 0.12)
        case (false, false, true): NSColor(srgbRed: 0.88, green: 0.20, blue: 0.20, alpha: 0.22)
        case (false, true, false): NSColor(srgbRed: 0.90, green: 0.22, blue: 0.22, alpha: 0.18)
        case (false, true, true): NSColor(srgbRed: 0.85, green: 0.16, blue: 0.16, alpha: 0.32)
        }
    }

    private static let typeColor = adaptiveColor(
        light: NSColor(srgbRed: 0.0, green: 0.42, blue: 0.40, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.0, green: 0.32, blue: 0.30, alpha: 1),
        dark: NSColor(srgbRed: 0.36, green: 0.84, blue: 0.80, alpha: 1),
        darkHighContrast: NSColor(srgbRed: 0.52, green: 0.94, blue: 0.90, alpha: 1))

    private static let diffAddedForeground = adaptiveColor(
        light: NSColor(srgbRed: 0.04, green: 0.42, blue: 0.16, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.02, green: 0.30, blue: 0.10, alpha: 1),
        dark: NSColor(srgbRed: 0.49, green: 0.89, blue: 0.55, alpha: 1),
        darkHighContrast: NSColor(srgbRed: 0.68, green: 0.96, blue: 0.72, alpha: 1))

    private static let diffAddedBackground = adaptiveColor(
        light: diffBackgroundColor(added: true, dark: false, highContrast: false),
        lightHighContrast: diffBackgroundColor(added: true, dark: false, highContrast: true),
        dark: diffBackgroundColor(added: true, dark: true, highContrast: false),
        darkHighContrast: diffBackgroundColor(added: true, dark: true, highContrast: true))

    private static let diffRemovedForeground = adaptiveColor(
        light: NSColor(srgbRed: 0.66, green: 0.10, blue: 0.10, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.48, green: 0.05, blue: 0.05, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.60, alpha: 1),
        darkHighContrast: NSColor(srgbRed: 1.0, green: 0.78, blue: 0.76, alpha: 1))

    private static let diffRemovedBackground = adaptiveColor(
        light: diffBackgroundColor(added: false, dark: false, highContrast: false),
        lightHighContrast: diffBackgroundColor(added: false, dark: false, highContrast: true),
        dark: diffBackgroundColor(added: false, dark: true, highContrast: false),
        darkHighContrast: diffBackgroundColor(added: false, dark: true, highContrast: true))

    private static let invisibleBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.95, green: 0.60, blue: 0.05, alpha: 0.24),
        lightHighContrast: NSColor(srgbRed: 0.90, green: 0.52, blue: 0.0, alpha: 0.38),
        dark: NSColor(srgbRed: 0.95, green: 0.65, blue: 0.10, alpha: 0.28),
        darkHighContrast: NSColor(srgbRed: 0.98, green: 0.70, blue: 0.15, alpha: 0.42))

    private static let invisibleUnderline = adaptiveColor(
        light: NSColor(srgbRed: 0.78, green: 0.42, blue: 0.0, alpha: 1),
        lightHighContrast: NSColor(srgbRed: 0.58, green: 0.28, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1),
        darkHighContrast: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.40, alpha: 1))

    private static func adaptiveColor(
        light: NSColor, lightHighContrast: NSColor, dark: NSColor, darkHighContrast: NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let isHighContrast =
                highContrastAppearances.contains(appearance.name)
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            switch (isDark, isHighContrast) {
            case (true, true): return darkHighContrast
            case (true, false): return dark
            case (false, true): return lightHighContrast
            case (false, false): return light
            }
        }
    }

    func find(_ query: String, direction: PreviewFindDirection, restart: Bool) async -> PreviewFindOutcome {
        guard !Task.isCancelled else { return .notFound }
        if query != matchedQuery {
            let text = string
            let version = contentVersion
            let found: [NSRange]
            do {
                found = try await offMain { try Self.ranges(of: query, in: text) }
            } catch is CancellationError {
                return .notFound
            } catch {
                Logger(category: "finder-preview").error(
                    "Preview text find failed: \(error.localizedDescription, privacy: .private)")
                return .notFound
            }
            guard !Task.isCancelled, contentVersion == version else { return .notFound }
            matches = found
            matchedQuery = query
            matchIndex = nil
        }
        guard !Task.isCancelled, !matches.isEmpty else { return .notFound }
        let index: Int
        if let current = matchIndex, !restart {
            let step = direction == .forward ? 1 : -1
            index = (current + step + matches.count) % matches.count
        } else {
            let anchor = selectedRange().location
            index =
                direction == .forward
                ? matches.firstIndex { $0.location >= anchor } ?? 0
                : matches.lastIndex { $0.location < anchor } ?? matches.count - 1
        }
        matchIndex = index
        let range = matches[index]
        setSelectedRange(range)
        scrollRangeToVisible(range)
        showFindIndicator(for: range)
        return PreviewFindOutcome(found: true, current: index + 1, total: matches.count)
    }

    func endFind() { window?.makeFirstResponder(self) }

    nonisolated private static func ranges(of query: String, in text: String) throws -> [NSRange] {
        let haystack = text as NSString
        var found: [NSRange] = []
        var searchStart = 0
        while searchStart < haystack.length {
            if found.count.isMultiple(of: cancellationStride) { try Task.checkCancellation() }
            let range = haystack.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: searchStart, length: haystack.length - searchStart))
            guard range.location != NSNotFound else { break }
            found.append(range)
            searchStart = range.location + max(range.length, 1)
        }
        return found
    }

    nonisolated private static let cancellationStride = 1024
}

private final class PreviewLineRuler: NSRulerView {
    private static let minimumThickness: CGFloat = 40
    private static let labelPadding: CGFloat = 8
    var lineStarts = [0] {
        didSet {
            if lineStarts != oldValue { measure() }
        }
    }
    var codeFont = NSFont.monospacedSystemFont(
        ofSize: CGFloat(FinderPreviewSettings.defaultCodeFontSize), weight: .regular)
    {
        didSet {
            if codeFont != oldValue { measure() }
        }
    }
    private var labelAttributes: [NSAttributedString.Key: Any] = [:]

    private func measure() {
        labelAttributes = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(1, codeFont.pointSize - 1), weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let widest = String(repeating: "8", count: String(lineStarts.count).count) as NSString
        ruleThickness = max(
            Self.minimumThickness, ceil(widest.size(withAttributes: labelAttributes).width) + Self.labelPadding * 2)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    @objc func scrolled() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor = clientView as? NSTextView, let layout = editor.textLayoutManager,
            let content = layout.textContentManager
        else { return }
        let visible = editor.visibleRect
        let start = layout.textViewportLayoutController.viewportRange?.location
        _ = layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var lower = 0
            var upper = self.lineStarts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if self.lineStarts[middle] <= offset { lower = middle + 1 } else { upper = middle }
            }
            guard let first = fragment.textLineFragments.first else { return true }
            let label = String(max(1, lower)) as NSString
            let attributes = self.labelAttributes
            let origin = self.convert(
                NSPoint(x: 0, y: frame.minY + first.typographicBounds.minY + editor.textContainerOrigin.y), from: editor
            )
            label.draw(
                at: NSPoint(
                    x: self.ruleThickness - label.size(withAttributes: attributes).width - Self.labelPadding,
                    y: origin.y),
                withAttributes: attributes)
            return true
        }
    }
}
