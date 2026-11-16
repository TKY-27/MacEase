import AppKit
import Engine
import SwiftUI
import os

private struct PreviewTextRequest: Equatable {
    let loaded: Bool
    let encoding: PreviewEncoding
    let rich: Bool
    let buffer: String?
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
        source: PreviewTextSource, encoding: PreviewEncoding, rich: Bool, kind: PreviewKind, url: URL,
        buffer: String? = nil, document: TextEditDocument? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        let text: String
        let html = rich && kind == .markdown
        var language = PreviewLanguage.resolve(url.pathExtension)
        if kind == .propertyList && (rich || source.binaryPropertyList) {
            guard !source.truncated else { throw CocoaError(.fileReadTooLarge) }
            let bytes: Data
            if let buffer, let document {
                bytes = try document.encoded(buffer)
            } else {
                bytes = source.bytes
            }
            text = try PropertyListConversion.json(from: bytes, indent: "  ")
            language = .json
        } else {
            let decoded = try buffer ?? source.decoded(as: encoding)
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
    let editor: PreviewTextEditor
    let jobs: JobCenter
    @State private var source: PreviewTextSource?
    @State private var rendering: PreviewTextRendering?
    @State private var encoding = PreviewEncoding.automatic
    @State private var rich = true
    @State private var wrap = true
    @State private var scripts = false
    @State private var network = false
    @State private var failed = false
    @State private var confirmsUTF8 = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar { controls }
            if editor.dirty {
                HStack(spacing: 8) {
                    Text("Unsaved changes").font(.caption)
                    Spacer(minLength: 0)
                    Button("Save") { save() }
                    Button("Discard") { editor.discard() }
                }
                .controlSize(.small).padding(.horizontal, PreviewLayout.margin).padding(.vertical, 6)
                .disabled(editor.saving || editor.confirming)
                Divider()
            }
            Group {
                if editor.editing {
                    ZStack {
                        PreviewCodeView(
                            text: editor.buffer, tokens: [], lineStarts: [], wrap: wrap, model: editor, editable: !rich
                        )
                        .opacity(rich ? 0 : 1).allowsHitTesting(!rich)
                        .accessibilityHidden(rich)
                        if rich {
                            if failed {
                                PreviewFailure()
                            } else if let rendering {
                                if rendering.html {
                                    PreviewWebViewer(url: url, html: rendering.text, scripts: false, network: false)
                                        .id(rendering.text)
                                } else {
                                    PreviewCodeView(
                                        text: rendering.text, tokens: rendering.tokens,
                                        lineStarts: rendering.lineStarts, wrap: wrap)
                                }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                } else if kind == .html && rich {
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
            if editor.saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption)
                }.padding(6)
            } else if let message = editor.message {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(message).padding(6)
                if editor.offersUTF8 {
                    Button("Save as UTF-8…") { confirmsUTF8 = true }.controlSize(.small).padding(.bottom, 6)
                }
            }
            if source?.truncated == true && !(kind == .html && rich) {
                Divider()
                Text("Showing the first 256 KB").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
        }
        .task { await read() }
        .task(
            id: PreviewTextRequest(
                loaded: source != nil, encoding: encoding, rich: rich,
                buffer: rich && editor.editing ? editor.buffer : nil)
        ) { await render() }
        .alert("Save as UTF-8?", isPresented: $confirmsUTF8) {
            Button("Save as UTF-8") { save(asUTF8: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the file’s encoding to UTF-8. The original remains available through Undo.")
        }
        .onDisappear {
            source = nil
            rendering = nil
        }
    }

    @ViewBuilder private var controls: some View {
        if editor.editing {
            Button {
                save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command).labelStyle(.iconOnly).help(Text("Save"))
            .disabled(!editor.dirty || editor.saving || editor.confirming)
            Button {
                editor.discard()
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly).help(Text("Revert"))
            .disabled(!editor.dirty || editor.saving || editor.confirming)
        } else if kind != .html && !(kind == .markdown && rich) {
            Button("Edit") { beginEditing() }.keyboardShortcut("e", modifiers: .command)
                .disabled(!canEditSource)
        }
        if kind != .text && source?.binaryPropertyList != true {
            ViewThatFits(in: .horizontal) {
                modePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                modePicker.pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
        Spacer(minLength: 0)
        if kind == .html && rich {
            ViewThatFits(in: .horizontal) {
                webPermissions.labelStyle(.titleOnly)
                webPermissions.labelStyle(.iconOnly)
            }
        } else if !(rich && kind == .markdown) {
            if source?.binaryPropertyList != true && !editor.editing {
                ViewThatFits(in: .horizontal) {
                    encodingPicker.labelsHidden().fixedSize()
                    Menu {
                        encodingPicker.pickerStyle(.inline)
                    } label: {
                        Label("Encoding", systemImage: "textformat")
                    }
                    .labelStyle(.iconOnly).fixedSize()
                }
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

    private func beginEditing() {
        guard let source else { return }
        do {
            try editor.begin(url: url, source: source, encoding: encoding)
            if editor.editing { rich = false }
        } catch {
            editor.message = UserMessages.describeResult(
                EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
        }
    }

    private var canEditSource: Bool {
        guard let source, !source.truncated, !source.binaryPropertyList else { return false }
        return !failed || rich && (kind == .json || kind == .propertyList)
    }

    private func save(asUTF8: Bool = false) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { _ = await editor.save(using: jobs, asUTF8: asUTF8) }
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
        let buffer = editor.editing ? editor.buffer : nil
        let document = editor.document
        if editor.editing && !rich { return }
        do {
            let rendered = try await offMain { [kind, url] in
                try PreviewTextRendering.make(
                    source: source, encoding: encoding, rich: rich, kind: kind, url: url, buffer: buffer,
                    document: document)
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
    var model: PreviewTextEditor? = nil
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: PreviewTextEditor?
        init(model: PreviewTextEditor?) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            model?.buffer = view.string
        }
        func undoManager(for view: NSTextView) -> UndoManager? { model?.undo }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = PreviewEditingTextView(usingTextLayoutManager: true)
        editor.delegate = context.coordinator
        editor.allowsUndo = model != nil
        editor.usesFindBar = true
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isEditable = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isSelectable = true
        editor.isRichText = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.backgroundColor = .textBackgroundColor
        scroll.documentView = editor
        let ruler = PreviewLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor
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
        guard let editor = scroll.documentView as? NSTextView else { return }
        let wasEditable = editor.isEditable
        editor.isEditable = editable && model != nil && model?.saving == false && model?.confirming == false
        (editor as? PreviewEditingTextView)?.lineEnding = model?.document?.lineEnding ?? "\n"
        if !editor.isEditable, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
        if editor.isEditable && !wasEditable {
            editor.window?.makeFirstResponder(editor)
        }
        if !editor.string.utf8.elementsEqual(text.utf8) {
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
            editor.textStorage?.setAttributedString(styled)
        }
        if model != nil {
            let units = Array(text.utf16)
            var starts = [0]
            for (offset, unit) in units.enumerated() {
                if unit == 10 || (unit == 13 && (offset + 1 == units.count || units[offset + 1] != 10)) {
                    starts.append(offset + 1)
                }
            }
            (scroll.verticalRulerView as? PreviewLineRuler)?.lineStarts = starts
        } else {
            (scroll.verticalRulerView as? PreviewLineRuler)?.lineStarts = lineStarts
        }
        scroll.hasHorizontalScroller = !wrap
        editor.isHorizontallyResizable = !wrap
        editor.autoresizingMask = wrap ? [.width] : []
        editor.textContainer?.widthTracksTextView = wrap
        editor.textContainer?.containerSize = NSSize(
            width: wrap ? max(1, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        if wrap { editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height)) }
        scroll.verticalRulerView?.needsDisplay = true
    }
}

private final class PreviewEditingTextView: NSTextView {
    var lineEnding = "\n"

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isEditable { window?.makeFirstResponder(self) }
    }

    override func insertNewline(_ sender: Any?) {
        insertText(lineEnding, replacementRange: selectedRange())
    }

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
