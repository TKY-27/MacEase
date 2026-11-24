import AppKit
import SwiftUI
import os

struct PreviewTableViewer: View {
    let rendering: PreviewTextRendering
    let format: PreviewTable.Format
    let find: PreviewFind
    @State private var loaded: (renderingID: UUID, table: PreviewTable, columnWidths: [CGFloat])?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            if let loaded, loaded.renderingID == rendering.id {
                note(loaded.table)
                PreviewTableGrid(table: loaded.table, columnWidths: loaded.columnWidths, find: find)
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
            let (table, columnWidths) = try await offMain { [format] in
                let layout = format.layout(of: text)
                let table = try PreviewTable.parse(layout.body, delimiter: layout.delimiter)
                return (table, try PreviewTableView.columnWidths(for: table))
            }
            try Task.checkCancellation()
            loaded = (renderingID, table, columnWidths)
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
    let columnWidths: [CGFloat]
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
        tableView.find = find
        guard context.coordinator.tableID != table.id else { return }
        context.coordinator.tableID = table.id
        tableView.show(table, columnWidths: columnWidths)
        find.attach(tableView)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tableView = scroll.documentView as? PreviewTableView else { return }
        tableView.cancelSorting()
        coordinator.find?.detach(tableView)
    }
}

final class PreviewTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate, PreviewFindTarget {
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("PreviewTableCell")
    // Core Text fonts are immutable and thread-safe.
    nonisolated(unsafe) private static let cellFont: CTFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    nonisolated(unsafe) private static let headerFont: CTFont = NSFont.boldSystemFont(
        ofSize: NSFont.systemFontSize(for: .small))
    private static let font = cellFont as NSFont
    nonisolated private static let cellPadding: CGFloat = 4
    private static let rowPadding: CGFloat = 6
    nonisolated private static let minimumColumnWidth: CGFloat = 40
    nonisolated private static let maximumColumnWidth: CGFloat = 240
    nonisolated private static let measuredRows = 20
    // About twice what the widest column shows.
    nonisolated private static let measuredScalars = 80
    nonisolated private static let sortIndicatorWidth: CGFloat = 16
    private(set) var table: PreviewTable?
    private(set) var order: [Int] = []
    private var contentVersion: UInt64 = 0
    private var matchedQuery: String?
    private var matches: [PreviewTable.Cell] = []
    private var matchIndex: Int?
    private var currentMatchCell: PreviewTable.Cell?
    private var sorting: Task<Void, Never>?
    weak var find: PreviewFind?

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

    func show(_ table: PreviewTable, columnWidths: [CGFloat]) {
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
            let header = table.value(row: 0, column: column)
            // Headers show at most the widest column.
            tableColumn.title = PreviewTable.displayText(header, limit: Self.measuredScalars)
            tableColumn.headerToolTip = PreviewTable.displayText(header)
            tableColumn.minWidth = Self.minimumColumnWidth
            tableColumn.width = columnWidths[column]
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: String(column), ascending: true)
            if table.numericColumns.contains(column) { tableColumn.headerCell.alignment = .right }
            addTableColumn(tableColumn)
        }
        reloadData()
    }

    // Off the main actor; headers measured bold.
    nonisolated static func columnWidths(for table: PreviewTable) throws -> [CGFloat] {
        try (0..<table.columnCount).map { column in
            try Task.checkCancellation()
            var widest = width(of: table.value(row: 0, column: column), font: headerFont) + sortIndicatorWidth
            for row in table.rows.indices.dropFirst().prefix(measuredRows) where widest < maximumColumnWidth {
                widest = max(widest, width(of: table.value(row: row, column: column), font: cellFont))
            }
            return min(maximumColumnWidth, max(minimumColumnWidth, ceil(widest + cellPadding * 4)))
        }
    }

    nonisolated private static func width(of raw: String, font: CTFont) -> CGFloat {
        let sample = PreviewTable.displayText(raw, limit: measuredScalars)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let table, let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView ?? makeCell()
        let shown = PreviewTable.displayText(table.value(row: order[row], column: column))
        cell.textField?.stringValue = shown
        cell.textField?.toolTip = shown.isEmpty ? nil : shown
        cell.textField?.alignment = table.numericColumns.contains(column) ? .right : .natural
        let current = currentMatchCell == PreviewTable.Cell(position: row, column: column)
        cell.textField?.drawsBackground = current
        cell.textField?.backgroundColor = .findHighlightColor
        // Find highlight stays yellow in Dark Mode.
        cell.textField?.textColor = current ? .black : .labelColor
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
        sorting = Task { [weak self] in
            do {
                let sorted = try await offMain { try table.order(sortedBy: column, ascending: ascending) }
                guard let self, !Task.isCancelled, self.table?.id == table.id else { return }
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
        // Recounts matches in the new order.
        find?.attach(self)
    }

    func cancelSorting() { sorting?.cancel() }

    private func resetFind() {
        contentVersion &+= 1
        matchedQuery = nil
        matches = []
        matchIndex = nil
        currentMatchCell = nil
    }

    private func highlight(_ cell: PreviewTable.Cell?) {
        let changed = [currentMatchCell, cell].compactMap { $0 }
        currentMatchCell = cell
        reloadData(
            forRowIndexes: IndexSet(changed.map(\.position).filter { $0 < numberOfRows }),
            columnIndexes: IndexSet(changed.map(\.column).filter { $0 < numberOfColumns }))
    }

    @objc func copy(_ sender: Any?) {
        guard let table, !selectedRowIndexes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(table.copiedText(rows: selectedRowIndexes.map { order[$0] }), forType: .string)
    }

    override func validateUserInterfaceItem(_ userInterfaceItem: any NSValidatedUserInterfaceItem) -> Bool {
        if userInterfaceItem.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(userInterfaceItem)
    }

    func find(_ query: String, direction: PreviewFindDirection, restart: Bool) async -> PreviewFindOutcome {
        // Order changes mid-search trigger a recount.
        while query != matchedQuery {
            guard !Task.isCancelled, let table else { return .notFound }
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
            guard !Task.isCancelled else { return .notFound }
            guard contentVersion == version else { continue }
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
            let anchor = selectedRow
            // Stepping leaves the selected row.
            index =
                direction == .forward
                ? matches.firstIndex { restart ? $0.position >= anchor : $0.position > anchor } ?? 0
                : matches.lastIndex { $0.position < anchor } ?? matches.count - 1
        }
        matchIndex = index
        let match = matches[index]
        highlight(match)
        selectRowIndexes([match.position], byExtendingSelection: false)
        scrollRowToVisible(match.position)
        scrollColumnToVisible(match.column)
        return PreviewFindOutcome(found: true, current: index + 1, total: matches.count)
    }

    func endFind() {
        highlight(nil)
        window?.makeFirstResponder(self)
    }
}
