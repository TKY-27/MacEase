import PDFKit
import SwiftUI
import os

struct PreviewPDFViewer: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var locked = false
    @State private var failed = false
    @State private var navigator = PreviewPDFNavigator()
    @State private var find = PreviewFind()

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {
                if document != nil && !locked {
                    HStack(spacing: 8) {
                        PreviewPDFControls(navigator: navigator)
                        Spacer(minLength: 0)
                        PreviewFindButton(find: find)
                    }
                    .layoutPriority(1)
                }
            }
            if find.isPresented { PreviewFindBar(find: find) }
            if failed {
                PreviewFailure()
            } else if let document {
                if locked {
                    PreviewPDFUnlock(document: document) { locked = false }
                } else {
                    PreviewPDFDocument(document: document, navigator: navigator, find: find)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                let loaded = try await Self.read(url)
                guard !Task.isCancelled else { return }
                locked = loaded.isLocked
                document = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                Logger(category: "finder-preview").error("Preview PDF could not be read")
            }
        }
        .onDisappear { document = nil }
    }

    nonisolated private static func read(_ url: URL) async throws -> sending PDFDocument {
        guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }
}

private struct PreviewPDFUnlock: View {
    let document: PDFDocument
    let unlocked: () -> Void
    @State private var password = ""
    @State private var rejected = false
    @FocusState private var focused: Bool
    private static let fieldWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: 28)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text("This PDF is locked with a password.").font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: Self.fieldWidth)
                .focused($focused)
                .onSubmit(unlock)
                .onChange(of: password) { _, updated in
                    if !updated.isEmpty { rejected = false }
                }
            if rejected {
                Text("The password is incorrect.").font(.callout).foregroundStyle(.red)
            }
            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
        .padding(PreviewLayout.margin * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        if document.unlock(withPassword: password) {
            unlocked()
            return
        }
        password = ""
        rejected = true
        focused = true
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: String(localized: "The password is incorrect.")])
    }
}

struct PreviewPDFOutlineEntry: Identifiable {
    let id: Int
    let title: String
    let destination: PDFDestination?
    let children: [Self]?
}

@MainActor
@Observable
final class PreviewPDFNavigator {
    // Bounds main-thread work for hostile outlines.
    static let maximumOutlineEntries = 2000
    private static let actualSizeTolerance: CGFloat = 0.01

    private(set) var pageCount = 0
    private(set) var pageNumber = 0
    private(set) var outline: [PreviewPDFOutlineEntry] = []
    private(set) var fitsWidth = true
    private(set) var isActualSize = false
    @ObservationIgnored private weak var view: PDFView?

    func attach(_ view: PDFView) {
        self.view = view
        pageCount = view.document?.pageCount ?? 0
        outline = view.document?.outlineRoot.map(Self.entries) ?? []
        pageChanged()
        scaleChanged()
    }

    func pageChanged() {
        guard let view, let document = view.document, let page = view.currentPage else { return }
        pageNumber = document.index(for: page) + 1
    }

    func scaleChanged() {
        guard let view else { return }
        fitsWidth = view.autoScales
        isActualSize = !view.autoScales && abs(view.scaleFactor - 1) < Self.actualSizeTolerance
    }

    func go(toPage number: Int) {
        guard pageCount > 0, let view, let page = view.document?.page(at: min(max(number, 1), pageCount) - 1) else {
            return
        }
        view.go(to: page)
        pageChanged()
    }

    func go(to destination: PDFDestination) { view?.go(to: destination) }

    func fitWidth() {
        view?.autoScales = true
        scaleChanged()
    }

    func actualSize() {
        view?.autoScales = false
        view?.scaleFactor = 1
        scaleChanged()
    }

    private static func entries(_ root: PDFOutline) -> [PreviewPDFOutlineEntry] {
        var budget = maximumOutlineEntries
        func children(of node: PDFOutline) -> [PreviewPDFOutlineEntry] {
            var result: [PreviewPDFOutlineEntry] = []
            for index in 0..<node.numberOfChildren {
                guard budget > 0, let child = node.child(at: index) else { break }
                budget -= 1
                let id = budget
                let nested = children(of: child)
                result.append(
                    PreviewPDFOutlineEntry(
                        id: id, title: child.label ?? "", destination: child.destination,
                        children: nested.isEmpty ? nil : nested))
            }
            return result
        }
        return children(of: root)
    }
}

private struct PreviewPDFControls: View {
    let navigator: PreviewPDFNavigator
    @State private var showsOutline = false

    var body: some View {
        if !navigator.outline.isEmpty {
            Button {
                showsOutline.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .help(Text("Table of Contents"))
            .accessibilityLabel(Text("Table of Contents"))
            .popover(isPresented: $showsOutline, arrowEdge: .bottom) {
                PreviewPDFOutline(entries: navigator.outline) { destination in
                    navigator.go(to: destination)
                    showsOutline = false
                }
            }
        }
        PreviewPDFPageField(navigator: navigator)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Toggle("Fit Width", isOn: fitWidthBinding).toggleStyle(.button)
                Toggle("Actual Size", isOn: actualSizeBinding).toggleStyle(.button)
            }
            .fixedSize()
            Menu {
                Toggle("Fit Width", isOn: fitWidthBinding)
                Toggle("Actual Size", isOn: actualSizeBinding)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .fixedSize()
            .help(Text("Zoom"))
            .accessibilityLabel(Text("Zoom"))
        }
    }

    private var fitWidthBinding: Binding<Bool> {
        Binding(get: { navigator.fitsWidth }, set: { if $0 { navigator.fitWidth() } })
    }

    private var actualSizeBinding: Binding<Bool> {
        Binding(get: { navigator.isActualSize }, set: { if $0 { navigator.actualSize() } })
    }
}

private struct PreviewPDFPageField: View {
    let navigator: PreviewPDFNavigator
    @State private var entry = "1"
    @FocusState private var focused: Bool
    private static let digitWidth: CGFloat = 8
    private static let fieldPadding: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            TextField("Page", text: $entry)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: CGFloat(max(1, String(navigator.pageCount).count)) * Self.digitWidth + Self.fieldPadding)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(Text("Page"))
                .accessibilityValue(Text("\(navigator.pageNumber) of \(navigator.pageCount)"))
                .help(Text("Go to Page"))
            Text(verbatim: "/ \(navigator.pageCount)")
                .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                .accessibilityHidden(true)
        }
        .onChange(of: navigator.pageNumber, initial: true) { _, page in entry = String(page) }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { entry = String(navigator.pageNumber) }
        }
    }

    private func commit() {
        if let parsed = Int(entry.trimmingCharacters(in: .whitespaces)) {
            navigator.go(toPage: parsed)
        }
        entry = String(navigator.pageNumber)
    }
}

private struct PreviewPDFOutline: View {
    let entries: [PreviewPDFOutlineEntry]
    let open: (PDFDestination) -> Void
    private static let size = CGSize(width: 280, height: 360)

    var body: some View {
        List(entries, children: \.children) { entry in
            Button {
                if let destination = entry.destination { open(destination) }
            } label: {
                Text(entry.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(entry.destination == nil)
        }
        .listStyle(.sidebar)
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityLabel(Text("Table of Contents"))
    }
}

private struct PreviewPDFDocument: NSViewRepresentable {
    let document: PDFDocument
    let navigator: PreviewPDFNavigator
    let find: PreviewFind

    func makeNSView(context: Context) -> PreviewPDFView {
        let viewer = PreviewPDFView()
        viewer.autoScales = true
        viewer.displayMode = .singlePageContinuous
        viewer.backgroundColor = .underPageBackgroundColor
        viewer.document = document
        viewer.navigator = navigator
        navigator.attach(viewer)
        find.attach(viewer)
        viewer.find = find
        return viewer
    }

    func updateNSView(_ viewer: PreviewPDFView, context: Context) {}

    static func dismantleNSView(_ viewer: PreviewPDFView, coordinator: ()) {
        viewer.find?.detach(viewer)
        viewer.endFind()
        viewer.document?.cancelFindString()
        viewer.document = nil
    }
}

final class PreviewPDFView: PDFView, PreviewFindTarget {
    weak var navigator: PreviewPDFNavigator? {
        didSet {
            let center = NotificationCenter.default
            center.removeObserver(self, name: .PDFViewPageChanged, object: self)
            center.removeObserver(self, name: .PDFViewScaleChanged, object: self)
            guard navigator != nil else { return }
            center.addObserver(
                self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
            center.addObserver(
                self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: self)
        }
    }
    weak var find: PreviewFind?
    private var matchedQuery: String?
    private var matches: [PDFSelection] = []
    private var matchIndex: Int?
    private var collector: PreviewPDFMatchCollector?

    @objc private func pageChanged() { navigator?.pageChanged() }

    @objc private func scaleChanged() { navigator?.scaleChanged() }

    func find(_ query: String, direction: PreviewFindDirection, restart: Bool) async -> PreviewFindOutcome {
        if query != matchedQuery {
            guard !Task.isCancelled else { return .notFound }
            // PDFKit allows one search per document.
            while let active = collector, active.isRunning {
                await active.cancel()
                guard !Task.isCancelled else { return .notFound }
            }
            guard !Task.isCancelled, let document else { return .notFound }
            let started = PreviewPDFMatchCollector(document: document)
            collector = started
            let found = await started.run(query)
            guard !Task.isCancelled, collector === started else { return .notFound }
            matches = found
            matchedQuery = query
            matchIndex = nil
            highlightedSelections = matches.isEmpty ? nil : matches
        }
        guard !Task.isCancelled, !matches.isEmpty else { return .notFound }
        let index: Int
        if let current = matchIndex, !restart {
            let step = direction == .forward ? 1 : -1
            index = (current + step + matches.count) % matches.count
        } else {
            let anchor = currentPage.flatMap { document?.index(for: $0) } ?? 0
            index = matches.firstIndex { pageIndex(of: $0).map { $0 >= anchor } ?? false } ?? 0
        }
        matchIndex = index
        setCurrentSelection(matches[index], animate: false)
        go(to: matches[index])
        return PreviewFindOutcome(found: true, current: index + 1, total: matches.count)
    }

    func endFind() {
        collector?.requestCancel()
        highlightedSelections = nil
        matchedQuery = nil
        matches = []
        matchIndex = nil
        window?.makeFirstResponder(self)
    }

    private func pageIndex(of selection: PDFSelection) -> Int? {
        selection.pages.first.flatMap { document?.index(for: $0) }
    }
}

// PDFKit searches the document incrementally.
@MainActor
private final class PreviewPDFMatchCollector: NSObject {
    private let document: PDFDocument
    private var found: [PDFSelection] = []
    private(set) var isRunning = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    init(document: PDFDocument) { self.document = document }

    func run(_ query: String) async -> [PDFSelection] {
        guard !Task.isCancelled else { return [] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                endWaiters.append(continuation)
                isRunning = true
                document.delegate = self
                document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            }
            return found
        } onCancel: {
            Task { @MainActor in self.requestCancel() }
        }
    }

    func requestCancel() {
        guard isRunning else { return }
        document.cancelFindString()
    }

    func cancel() async {
        guard isRunning else { return }
        await withCheckedContinuation { continuation in
            endWaiters.append(continuation)
            document.cancelFindString()
        }
    }
}

extension PreviewPDFMatchCollector: @preconcurrency PDFDocumentDelegate {
    func didMatchString(_ instance: PDFSelection) { found.append(instance) }

    func documentDidEndDocumentFind(_ notification: Notification) {
        isRunning = false
        if document.delegate === self { document.delegate = nil }
        let waiters = endWaiters
        endWaiters = []
        waiters.forEach { $0.resume() }
    }
}
