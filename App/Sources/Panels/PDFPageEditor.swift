import Engine
import PDFKit
import SwiftUI

struct PDFPageEditor: View {
    let source: URL
    let session: PDFPageEditSession
    let cancel: () -> Void
    let run: ([Int], FileStamp) -> Void
    @State private var order: [Int]
    @State private var selection = Set<Int>()
    @State private var undoOrders = [[Int]]()
    @State private var redoOrders = [[Int]]()

    init(
        source: URL, session: PDFPageEditSession, cancel: @escaping () -> Void,
        run: @escaping ([Int], FileStamp) -> Void
    ) {
        self.source = source
        self.session = session
        self.cancel = cancel
        self.run = run
        _order = State(initialValue: Array(0..<session.pageCount))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                    .disabled(undoOrders.isEmpty)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                    .disabled(redoOrders.isEmpty)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer()
                Button("Move Up", systemImage: "arrow.up") { moveSelection(by: -1) }
                    .disabled(!canMove(by: -1))
                Button("Move Down", systemImage: "arrow.down") { moveSelection(by: 1) }
                    .disabled(!canMove(by: 1))
                Button("Remove", systemImage: "trash", role: .destructive, action: removeSelection)
                    .disabled(selection.isEmpty)
            }
            .labelStyle(.iconOnly)
            .padding()
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(order, id: \.self) { index in
                        HStack {
                            Thumbnail(entry: PageEntry(file: source, pageIndex: index))
                            Text("Page \(index + 1)")
                        }
                        .tag(index)
                        .accessibilityElement(children: .combine)
                    }
                    .onMove { offsets, destination in
                        var changed = order
                        changed.move(fromOffsets: offsets, toOffset: destination)
                        apply(changed)
                    }
                }
                .onDeleteCommand(perform: removeSelection)
                .frame(minWidth: 200, idealWidth: 240)
                PDFEditorPreview(
                    source: source, pageIndex: order.first(where: { selection.contains($0) }) ?? order.first
                )
                .frame(minWidth: 320)
            }
            .frame(minHeight: 450, maxHeight: .infinity)
            PanelBar(
                actionTitle: String(localized: "Save", comment: "PDF page editor action"),
                canRun: !order.isEmpty && order != Array(0..<session.pageCount), cancel: cancel
            ) { run(order, session.sourceStamp) }
        }
        .frame(minWidth: 760, idealWidth: 850, maxWidth: .infinity)
    }

    private func apply(_ changed: [Int]) {
        guard changed != order else { return }
        undoOrders.append(order)
        redoOrders.removeAll()
        order = changed
        selection.formIntersection(order)
    }

    private func canMove(by offset: Int) -> Bool {
        guard !selection.isEmpty else { return false }
        return offset < 0
            ? order.first.map { !selection.contains($0) } ?? false
            : order.last.map { !selection.contains($0) } ?? false
    }

    private func moveSelection(by offset: Int) {
        guard canMove(by: offset) else { return }
        var changed = order
        let positions = offset < 0 ? Array(changed.indices) : Array(changed.indices.reversed())
        for index in positions where selection.contains(changed[index]) {
            changed.swapAt(index, index + offset)
        }
        apply(changed)
    }

    private func removeSelection() {
        apply(order.filter { !selection.contains($0) })
    }

    private func undo() {
        guard let previous = undoOrders.popLast() else { return }
        redoOrders.append(order)
        order = previous
        selection.formIntersection(order)
    }

    private func redo() {
        guard let next = redoOrders.popLast() else { return }
        undoOrders.append(order)
        order = next
        selection.formIntersection(order)
    }
}

private struct PDFEditorPreview: NSViewRepresentable {
    let source: URL
    let pageIndex: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.document = PDFDocument(url: source)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if let pageIndex, let page = view.document?.page(at: pageIndex) {
            view.isHidden = false
            view.go(to: page)
        } else {
            view.isHidden = true
        }
    }
}
