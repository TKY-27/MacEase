import AppKit
import SwiftUI
import os

struct PreviewTableViewer: View {
    let rendering: PreviewTextRendering
    let format: PreviewTable.Format
    let find: PreviewFind
    @State private var loaded: (renderingID: UUID, table: PreviewTable)?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            if let loaded, loaded.renderingID == rendering.id {
                note(loaded.table)
                PreviewTableGrid(table: loaded.table, find: find)
            } else if failed {
                PreviewFailure()
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: rendering.id) { await load() }
    }

    @ViewBuilder private func note(_ table: PreviewTable) -> some View {
        let rows = PreviewTable.maximumDataRows
        let columns = PreviewTable.maximumColumns
        if table.rowsClipped && table.columnsClipped {
            PreviewNote(
                symbol: "scissors",
                text: Text("Showing the first \(rows.formatted()) rows and \(columns.formatted()) columns"))
        } else if table.rowsClipped {
            PreviewNote(symbol: "scissors", text: Text("Showing the first \(rows.formatted()) rows"))
        } else if table.columnsClipped {
            PreviewNote(symbol: "scissors", text: Text("Showing the first \(columns.formatted()) columns"))
        }
    }

    private func load() async {
        failed = false
        let text = rendering.text
        let renderingID = rendering.id
        do {
            let table = try await offMain { [format] in
                try PreviewTable.parse(text, delimiter: format.delimiter(for: text))
            }
            try Task.checkCancellation()
            loaded = (renderingID, table)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            Logger(category: "finder-preview").error(
                "Preview table parsing failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

private struct PreviewTableGrid: NSViewRepresentable {
    let table: PreviewTable
    let find: PreviewFind

    final class Coordinator {
        var tableID: UUID?
        weak var find: PreviewFind?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = PreviewTableView()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tableView = scroll.documentView as? PreviewTableView else { return }
        context.coordinator.find = find
        guard context.coordinator.tableID != table.id else { return }
        context.coordinator.tableID = table.id
        tableView.show(table)
        find.attach(tableView)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tableView = scroll.documentView as? PreviewTableView else { return }
        coordinator.find?.detach(tableView)
    }
}

final class PreviewTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate, PreviewFindTarget {
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("PreviewTableCell")
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    private static let cellPadding: CGFloat = 4
    private static let rowPadding: CGFloat = 6
    private static let minimumColumnWidth: CGFloat = 40
    private static let maximumColumnWidth: CGFloat = 240
    private static let measuredRows = 50
    private static let sortIndicatorWidth: CGFloat = 16
    private(set) var table: PreviewTable?
    private(set) var order: [Int] = []
    private var contentVersion: UInt64 = 0
    private var matchedQuery: String?
    private var matches: [PreviewTable.Cell] = []
    private var matchIndex: Int?
    private var sorting: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        dataSource = self
        delegate = self
        style = .plain
        allowsMultipleSelection = true
        allowsColumnReordering = false
        columnAutoresizingStyle = .noColumnAutoresizing
        usesAlternatingRowBackgroundColors = true
        gridStyleMask = [.solidVerticalGridLineMask]
        rowHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading) + Self.rowPadding
        setAccessibilityLabel(String(localized: "Table"))
    }

    required init?(coder: NSCoder) { nil }

    // Clicking a row enables Copy and Find.
    override var needsPanelToBecomeKey: Bool { true }

    func show(_ table: PreviewTable) {
        sorting?.cancel()
        // Nil table keeps the sort callback inert.
        self.table = nil
        deselectAll(nil)
        sortDescriptors = []
        tableColumns.forEach(removeTableColumn)
        self.table = table
        order = table.fileOrder
        resetFind()
        for column in 0..<table.columnCount {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column)))
            let title = PreviewTable.displayText(table.value(row: 0, column: column))
            tableColumn.title = title
            tableColumn.headerToolTip = title
            tableColumn.minWidth = Self.minimumColumnWidth
            tableColumn.width = width(of: tableColumn, at: column, in: table)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: String(column), ascending: true)
            if table.numericColumns.contains(column) { tableColumn.headerCell.alignment = .right }
            addTableColumn(tableColumn)
        }
        reloadData()
    }

    // Sorted headers turn bold with an arrow.
    private func width(of tableColumn: NSTableColumn, at column: Int, in table: PreviewTable) -> CGFloat {
        let headerSize = tableColumn.headerCell.font?.pointSize ?? Self.font.pointSize
        let header =
            (tableColumn.title as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: headerSize)])
            .width + Self.sortIndicatorWidth
        let cells = table.rows.indices.dropFirst().prefix(Self.measuredRows).map {
            (PreviewTable.displayText(table.value(row: $0, column: column)) as NSString)
                .size(withAttributes: [.font: Self.font]).width
        }
        let widest = max(header, cells.max() ?? 0) + Self.cellPadding * 4
        return min(Self.maximumColumnWidth, max(Self.minimumColumnWidth, ceil(widest)))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let table, let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView ?? makeCell()
        let shown = PreviewTable.displayText(table.value(row: order[row], column: column))
        cell.textField?.stringValue = shown
        cell.textField?.toolTip = shown.isEmpty ? nil : shown
        cell.textField?.alignment = table.numericColumns.contains(column) ? .right : .natural
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier
        let field = NSTextField(labelWithString: "")
        field.font = Self.font
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.cellPadding),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.cellPadding),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // A third click returns to file order.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let table else { return }
        let previous = oldDescriptors.first
        guard let current = sortDescriptors.first, let key = current.key, let column = Int(key) else {
            apply(table.fileOrder)
            return
        }
        if let previous, previous.key == key, !previous.ascending, current.ascending {
            sortDescriptors = []
            return
        }
        sorting?.cancel()
        let ascending = current.ascending
        sorting = Task {
            do {
                let sorted = try await offMain { try table.order(sortedBy: column, ascending: ascending) }
                guard !Task.isCancelled, self.table?.id == table.id else { return }
                apply(sorted)
            } catch is CancellationError {
            } catch {
                Logger(category: "finder-preview").error(
                    "Preview table sort failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func apply(_ newOrder: [Int]) {
        sorting?.cancel()
        let selected = Set(selectedRowIndexes.map { order[$0] })
        order = newOrder
        resetFind()
        reloadData()
        let positions = newOrder.indices.filter { selected.contains(newOrder[$0]) }
        selectRowIndexes(IndexSet(positions), byExtendingSelection: false)
    }

    private func resetFind() {
        contentVersion &+= 1
        matchedQuery = nil
        matches = []
        matchIndex = nil
    }

    @objc func copy(_ sender: Any?) {
        guard let table, !selectedRowIndexes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(table.copiedText(rows: selectedRowIndexes.map { order[$0] }), forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    func find(_ query: String, direction: PreviewFindDirection, restart: Bool) async -> PreviewFindOutcome {
        guard !Task.isCancelled, let table else { return .notFound }
        if query != matchedQuery {
            let order = order
            let version = contentVersion
            let found: [PreviewTable.Cell]
            do {
                found = try await offMain { try table.matches(of: query, in: order) }
            } catch is CancellationError {
                return .notFound
            } catch {
                Logger(category: "finder-preview").error(
                    "Preview table find failed: \(error.localizedDescription, privacy: .private)")
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
            let anchor = max(selectedRow, 0)
            index =
                direction == .forward
                ? matches.firstIndex { $0.position >= anchor } ?? 0
                : matches.lastIndex { $0.position < anchor } ?? matches.count - 1
        }
        matchIndex = index
        let match = matches[index]
        selectRowIndexes([match.position], byExtendingSelection: false)
        scrollRowToVisible(match.position)
        scrollColumnToVisible(match.column)
        return PreviewFindOutcome(found: true, current: index + 1, total: matches.count)
    }

    func endFind() { window?.makeFirstResponder(self) }
}
