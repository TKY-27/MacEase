import AppKit
import Engine
import SwiftUI
import os

private struct PreviewTextRequest: Equatable {
    let loaded: Bool
    let encoding: PreviewEncoding
    let rich: Bool
}

private struct PreviewTextRendering: Sendable {
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
        blockquote { margin: 0; padding-left: 1em; border-left: 3px solid #8886; color: #888; }
        </style>
        """
    let text: String
    let tokens: [PreviewToken]
    let lineStarts: [Int]
    let html: Bool

    static func make(
        source: PreviewTextSource, encoding: PreviewEncoding, rich: Bool, kind: PreviewKind, url: URL
    ) throws -> Self {
        try Task.checkCancellation()
        let text: String
        let html = rich && kind == .markdown
        var language = PreviewLanguage.resolve(url.pathExtension)
        if kind == .propertyList && (rich || source.binaryPropertyList) {
            guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
            text = try PropertyListConversion.json(from: source.bytes, indent: "  ")
            language = .json
        } else {
            let decoded = try source.decoded(as: encoding)
            if rich && kind == .json {
                guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
                text = try JSONFormatter.formatted(decoded)
                language = .json
            } else if html {
                text = try MarkdownConversion.html(decoded, title: url.lastPathComponent)
                    .replacingOccurrences(of: "</head>", with: markdownStyle + "</head>")
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
        return Self(text: text, tokens: tokens, lineStarts: lineStarts, html: html)
    }
}

struct PreviewTextViewer: View {
    let url: URL
    let kind: PreviewKind
    @State private var source: PreviewTextSource?
    @State private var rendering: PreviewTextRendering?
    @State private var encoding = PreviewEncoding.automatic
    @State private var rich = true
    @State private var wrap = true
    @State private var scripts = false
    @State private var network = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar { controls }
            if source?.truncated == true && !(kind == .html && rich) {
                Text("Showing the first 256 KB").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24)
                Divider()
            }
            Group {
                if kind == .html && rich {
                    PreviewWebViewer(url: url, html: nil, scripts: scripts, network: network)
                        .id("\(scripts)-\(network)")
                } else if failed {
                    Text("The text could not be decoded or formatted. Try Source or another encoding.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(PreviewLayout.margin)
                } else if let rendering {
                    if rendering.html {
                        PreviewWebViewer(url: url, html: rendering.text, scripts: false, network: false)
                            .id(rendering.text)
                    } else {
                        PreviewCodeView(
                            text: rendering.text, tokens: rendering.tokens, lineStarts: rendering.lineStarts,
                            wrap: wrap)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await read() }
        .task(id: PreviewTextRequest(loaded: source != nil, encoding: encoding, rich: rich)) { await render() }
        .onDisappear {
            source = nil
            rendering = nil
        }
    }

    @ViewBuilder private var controls: some View {
        if kind != .text && source?.binaryPropertyList != true {
            ViewThatFits(in: .horizontal) {
                modePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                modePicker.pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
        if kind == .html && rich {
            ViewThatFits(in: .horizontal) {
                webPermissions.labelStyle(.titleOnly)
                webPermissions.labelStyle(.iconOnly)
            }
        } else if !(rich && kind == .markdown) {
            if source?.binaryPropertyList != true {
                Menu {
                    encodingPicker.pickerStyle(.inline)
                } label: {
                    Label("Encoding", systemImage: "textformat")
                }
                .labelStyle(.iconOnly).fixedSize()
                .accessibilityLabel(Text("Encoding"))
                .help(Text("Encoding"))
            }
            Toggle(isOn: $wrap) {
                Label("Soft Wrap", systemImage: "arrow.turn.down.left")
            }
            .toggleStyle(.button).labelStyle(.iconOnly).help(Text("Soft Wrap"))
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $rich) {
            if kind == .html {
                Text("Preview").tag(true)
            } else if kind == .markdown {
                Text("Rendered").tag(true)
            } else {
                Text("Formatted").tag(true)
            }
            Text("Source").tag(false)
        }
    }

    private var encodingPicker: some View {
        Picker("Encoding", selection: $encoding) {
            ForEach(PreviewEncoding.allCases, id: \.self) { choice in
                Text(verbatim: choice.title).tag(choice)
            }
        }
    }

    private var webPermissions: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $scripts) { Label("Run Scripts", systemImage: "curlybraces") }
                .help(Text("Run Scripts"))
            Toggle(isOn: $network) { Label("Allow Network", systemImage: "network") }
                .help(Text("Allow Network"))
        }
        .toggleStyle(.button)
        .fixedSize()
    }

    private func read() async {
        do {
            let loaded = try await offMain { [url] in try PreviewTextSource.read(url) }
            try Task.checkCancellation()
            if loaded.truncated && !loaded.binaryPropertyList { rich = false }
            source = loaded
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            Logger(category: "finder-preview").error(
                "Preview text read failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func render() async {
        guard let source else { return }
        rendering = nil
        failed = false
        guard !(kind == .html && rich) else { return }
        let encoding = encoding
        let rich = rich
        do {
            let rendered = try await offMain { [kind, url] in
                try PreviewTextRendering.make(source: source, encoding: encoding, rich: rich, kind: kind, url: url)
            }
            try Task.checkCancellation()
            rendering = rendered
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            Logger(category: "finder-preview").error(
                "Preview text rendering failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

private struct PreviewCodeView: NSViewRepresentable {
    let text: String
    let tokens: [PreviewToken]
    let lineStarts: [Int]
    let wrap: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = PreviewTextView(usingTextLayoutManager: true)
        textView.usesFindBar = true
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        guard let textView = scroll.documentView as? NSTextView else { return }
        if !textView.string.utf8.elementsEqual(text.utf8) {
            let styled = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ])
            for token in tokens {
                let color: NSColor
                switch token.kind {
                case .keyword: color = .systemPurple
                case .string: color = .systemRed
                case .comment: color = .secondaryLabelColor
                case .number: color = .systemBlue
                }
                styled.addAttribute(.foregroundColor, value: color, range: token.range)
            }
            textView.textStorage?.setAttributedString(styled)
        }
        (scroll.verticalRulerView as? PreviewLineRuler)?.lineStarts = lineStarts
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
}

private final class PreviewTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "f"
        {
            let command = NSMenuItem()
            command.tag = NSTextFinder.Action.showFindInterface.rawValue
            performFindPanelAction(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PreviewLineRuler: NSRulerView {
    var lineStarts = [0] {
        didSet {
            ruleThickness = max(40, CGFloat(String(lineStarts.count).count) * 8 + 16)
            needsDisplay = true
        }
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
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let origin = self.convert(
                NSPoint(x: 0, y: frame.minY + first.typographicBounds.minY + editor.textContainerOrigin.y), from: editor
            )
            label.draw(
                at: NSPoint(x: self.ruleThickness - label.size(withAttributes: attributes).width - 8, y: origin.y),
                withAttributes: attributes)
            return true
        }
    }
}
