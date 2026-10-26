import AppKit
import Engine
import Formats
import MenuCatalog
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
@Observable
final class SVGTracePanelModel {
    let source: URL
    private let settings: Engine.Settings
    private let runBatch: @MainActor (Batch) -> Void
    var colors: Int
    var detail: SVGTraceDetail = .standard
    private(set) var result: SVGTraceResult?
    private(set) var error: String?
    private(set) var renderError: String?
    private(set) var renderToken = UUID()
    private var loadedToken: UUID?
    private(set) var isPreparing = false
    private var preparation: Task<Void, Never>?
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var generation = 0
    private var closed = false

    init(source: URL, settings: Engine.Settings, runBatch: @escaping @MainActor (Batch) -> Void) {
        self.source = source
        self.settings = settings
        self.runBatch = runBatch
        colors = settings.image.svgColors
    }

    var canSave: Bool { !closed && !isPreparing && result != nil && loadedToken == renderToken }
    var isSVGLoaded: Bool { loadedToken == renderToken }

    func prepare() {
        guard !closed else { return }
        preparation?.cancel()
        generation += 1
        let expected = generation
        let options = SVGTraceOptions(colors: colors, detail: detail)
        result = nil
        error = nil
        renderError = nil
        loadedToken = nil
        renderToken = UUID()
        isPreparing = true
        let taskID = UUID()
        let task = Task { [source, settings] in
            defer { preparations.removeValue(forKey: taskID) }
            do {
                let prepared = try await offMain {
                    try await SVGTrace.prepare(source, options: options, settings: settings)
                }
                guard !Task.isCancelled, !closed, expected == generation else { return }
                result = prepared
                renderToken = UUID()
                isPreparing = false
            } catch is CancellationError {
                guard expected == generation else { return }
                isPreparing = false
            } catch {
                guard !closed, expected == generation else { return }
                self.error = UserMessages.describe(
                    EngineError.wrapping(error, path: source.path), file: source.lastPathComponent)
                isPreparing = false
            }
        }
        preparation = task
        preparations[taskID] = task
    }

    func didLoadSVG(_ token: UUID) {
        guard !closed, result != nil, token == renderToken else { return }
        loadedToken = token
        renderError = nil
    }

    func didFailSVG(_ token: UUID, error: any Error) {
        guard !closed, result != nil, token == renderToken else { return }
        loadedToken = nil
        renderError = String(
            localized: "The SVG preview could not be displayed: \(error.localizedDescription)",
            comment: "SVG renderer failure")
    }

    func retrySVGPreview() {
        guard !closed, result != nil else { return }
        loadedToken = nil
        renderError = nil
        renderToken = UUID()
    }

    func save() {
        guard canSave, let result else { return }
        let expected = generation
        if !result.warnings.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Review before saving", comment: "SVG trace warning title")
            alert.informativeText = result.warnings.map(UserMessages.describe).joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "Continue", comment: "Accept SVG warnings"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss SVG warnings"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".svg"
        panel.message = String(
            localized: "Existing files are kept. If the name is taken, a numbered name is used.",
            comment: "Explains collision-safe saving")
        guard panel.runModal() == .OK, let destination = panel.url, canSave, expected == generation else { return }
        runBatch(result.batch(to: destination, operation: .imageTraceSVG))
    }

    func close() async {
        closed = true
        generation += 1
        for task in preparations.values { task.cancel() }
        for task in Array(preparations.values) { await task.value }
        preparation = nil
        result = nil
        loadedToken = nil
    }
}

struct SVGTracePanel: View {
    @Bindable var model: SVGTracePanelModel
    let close: () -> Void
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(model.source.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Picker("Colors", selection: $model.colors) {
                    ForEach(1...8, id: \.self) { count in Text("\(count)").tag(count) }
                }
                .frame(width: 110)
                Picker("Detail", selection: $model.detail) {
                    Text("Less").tag(SVGTraceDetail.less)
                    Text("Standard").tag(SVGTraceDetail.standard)
                    Text("Fine").tag(SVGTraceDetail.fine)
                }
                .frame(width: 145)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                previewPane(title: String(localized: "Original", comment: "Source PNG preview")) {
                    if let result = model.result {
                        GeometryReader { geometry in
                            let size = canvasSize(result: result, viewport: geometry.size)
                            Image(nsImage: NSImage(cgImage: result.sourceImage, size: .zero))
                                .resizable()
                                .frame(width: size.width, height: size.height)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                        }
                    } else {
                        previewStatus
                    }
                }
                Divider()
                previewPane(title: String(localized: "Traced SVG", comment: "Vector result preview")) {
                    if let result = model.result {
                        GeometryReader { geometry in
                            let size = canvasSize(result: result, viewport: geometry.size)
                            ZStack {
                                SVGDocumentView(
                                    svg: result.svg, token: model.renderToken,
                                    onLoad: model.didLoadSVG, onFailure: model.didFailSVG
                                )
                                .frame(width: size.width, height: size.height)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                if let error = model.renderError {
                                    ContentUnavailableView {
                                        Label("Could Not Display SVG", systemImage: "exclamationmark.triangle")
                                    } description: {
                                        Text(error)
                                    } actions: {
                                        Button("Retry Preview") { model.retrySVGPreview() }
                                    }
                                } else if !model.isSVGLoaded {
                                    ProgressView("Rendering SVG…")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        }
                    } else {
                        previewStatus
                    }
                }
            }
            Divider()
            HStack {
                Text("Zoom", comment: "Preview scale")
                Slider(value: $zoom, in: 0.25...4)
                    .frame(width: 145)
                Text("\(Int(zoom * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = model.result {
                    Text("\(result.width) × \(result.height) px")
                        .foregroundStyle(.secondary)
                }
                Button("Close", action: close)
                Button("Save…") { model.save() }
                    .disabled(!model.canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 850, minHeight: 560)
        .onAppear { model.prepare() }
        .onChange(of: model.colors) { _, _ in model.prepare() }
        .onChange(of: model.detail) { _, _ in model.prepare() }
    }

    private var previewStatus: some View {
        Group {
            if model.isPreparing {
                ProgressView("Tracing…")
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Could Not Trace Image", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { model.prepare() }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewPane<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)); Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(minWidth: 300)
        .frame(maxWidth: .infinity)
    }

    private func canvasSize(result: SVGTraceResult, viewport: CGSize) -> CGSize {
        let fit = min(viewport.width / CGFloat(result.width), viewport.height / CGFloat(result.height))
        return CGSize(width: CGFloat(result.width) * fit * zoom, height: CGFloat(result.height) * fit * zoom)
    }
}

private struct SVGDocumentView: NSViewRepresentable {
    let svg: Data
    let token: UUID
    let onLoad: @MainActor (UUID) -> Void
    let onFailure: @MainActor (UUID, any Error) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLoad = onLoad
        coordinator.onFailure = onFailure
        guard coordinator.requestedToken != token else { return }
        coordinator.requestedToken = token
        coordinator.tokens.removeAll()
        let encoded = svg.base64EncodedString()
        let html = """
            <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <style>html,body,img{margin:0;width:100%;height:100%;overflow:hidden}</style>
            <img src="data:image/svg+xml;base64,\(encoded)">
            """
        if let navigation = webView.loadHTMLString(html, baseURL: nil) {
            coordinator.tokens[ObjectIdentifier(navigation)] = token
        } else {
            onFailure(token, EngineError.decodeFailed("SVG preview navigation"))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var requestedToken: UUID?
        var tokens: [ObjectIdentifier: UUID] = [:]
        var onLoad: (@MainActor (UUID) -> Void)?
        var onFailure: (@MainActor (UUID, any Error) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about"
                ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, let token = tokens.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
            Task { @MainActor in
                do {
                    let loaded =
                        try await webView.evaluateJavaScript(
                            "document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0"
                        ) as? Bool
                    if loaded == true {
                        onLoad?(token)
                    } else {
                        onFailure?(token, EngineError.decodeFailed("SVG preview image"))
                    }
                } catch {
                    onFailure?(token, error)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail(navigation, error: error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            fail(navigation, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let requestedToken { onFailure?(requestedToken, EngineError.decodeFailed("SVG preview process")) }
        }

        private func fail(_ navigation: WKNavigation?, error: any Error) {
            guard let navigation, let token = tokens.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
            onFailure?(token, error)
        }
    }
}
