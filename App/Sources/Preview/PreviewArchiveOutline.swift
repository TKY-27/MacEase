import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class PreviewArchiveRow {
    let node: ArchiveNode
    let order: Int
    private(set) lazy var name = ArchiveTree.displayText(node.name)
    private(set) lazy var path = ArchiveTree.displayText(node.path)
    lazy var children: [PreviewArchiveRow] = Self.rows(node.children ?? [])
    fileprivate var sortedChildren: (revision: Int, rows: [PreviewArchiveRow])?

    init(node: ArchiveNode, order: Int) {
        self.node = node
        self.order = order
    }

    static func rows(_ nodes: [ArchiveNode]) -> [PreviewArchiveRow] {
        nodes.enumerated().map { PreviewArchiveRow(node: $0.element, order: $0.offset) }
    }

    var fileExtension: String { (node.name as NSString).pathExtension.lowercased() }
}

enum PreviewArchiveColumn: String, CaseIterable {
    case name, size, modified, kind

    // Narrow panels keep name and size.
    var minimumOutlineWidth: CGFloat {
        switch self {
        case .name, .size: 0
        case .modified: 460
        case .kind: 600
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 200
        case .size: 76
        case .modified: 170
        case .kind: 120
        }
    }

    var minimumWidth: CGFloat { self == .name ? 80 : 40 }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .size: String(localized: "Size")
        case .modified: String(localized: "Date Modified")
        case .kind: String(localized: "Kind")
        }
    }
}

struct PreviewArchiveSort {
    private static let finderDomain = "com.apple.finder"
    private static let foldersFirstKey = "_FXSortFoldersFirst"

    var column = PreviewArchiveColumn.name
    var ascending = true
    let foldersFirst: Bool

    // Mirrors Finder's "Keep folders on top".
    static var finderKeepsFoldersOnTop: Bool {
        UserDefaults(suiteName: finderDomain)?.bool(forKey: foldersFirstKey) ?? false
    }

    static func nameOrdered(_ lhs: ArchiveNode, _ rhs: ArchiveNode, foldersFirst: Bool) -> Bool {
        if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // Stable: equal names keep archive order.
    static func nameSorted(_ nodes: [ArchiveNode], foldersFirst: Bool) throws -> [ArchiveNode] {
        try Task.checkCancellation()
        return try nodes.sorted { nameOrdered($0, $1, foldersFirst: foldersFirst) }.map { node in
            guard let children = node.children else { return node }
            return ArchiveNode(
                id: node.id, path: node.path, name: node.name, entry: node.entry,
                children: try nameSorted(children, foldersFirst: foldersFirst))
        }
    }

    func ordered(_ lhs: PreviewArchiveRow, _ rhs: PreviewArchiveRow, kinds: PreviewArchiveKinds) -> Bool {
        if foldersFirst, column == .name, lhs.node.isDirectory != rhs.node.isDirectory {
            return lhs.node.isDirectory
        }
        var order = compare(lhs, rhs, kinds: kinds)
        if order == .orderedSame, column != .name { order = lhs.node.name.localizedStandardCompare(rhs.node.name) }
        if order == .orderedSame { return lhs.order < rhs.order }
        return order == (ascending ? .orderedAscending : .orderedDescending)
    }

    private func compare(
        _ lhs: PreviewArchiveRow, _ rhs: PreviewArchiveRow, kinds: PreviewArchiveKinds
    ) -> ComparisonResult {
        switch column {
        case .name: lhs.node.name.localizedStandardCompare(rhs.node.name)
        case .size: Self.compare(lhs.node.fileSize, rhs.node.fileSize)
        case .modified: Self.compare(lhs.node.entry?.modified, rhs.node.entry?.modified)
        case .kind: kinds.description(for: lhs).localizedStandardCompare(kinds.description(for: rhs))
        }
    }

    // Unknown values sort after known ones.
    private static func compare<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        }
    }
}

extension ArchiveNode {
    var fileSize: Int64? { isDirectory ? nil : entry?.size }
}

// Kinds come from extensions, never contents.
final class PreviewArchiveKinds {
    static let iconSide: CGFloat = 16
    private var descriptions: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private lazy var folderIcon = sized(NSWorkspace.shared.icon(for: .folder))

    func description(for row: PreviewArchiveRow) -> String {
        if row.node.isDirectory { return String(localized: "Folder") }
        let suffix = row.fileExtension
        if let known = descriptions[suffix] { return known }
        let type = type(for: suffix)
        // Type descriptions start lowercase; Finder's kinds don't.
        let described =
            type == .data
            ? String(localized: "Document")
            : type.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                ?? String(localized: "Document")
        descriptions[suffix] = described
        return described
    }

    func icon(for row: PreviewArchiveRow) -> NSImage {
        if row.node.isDirectory { return folderIcon }
        let suffix = row.fileExtension
        if let known = icons[suffix] { return known }
        let icon = sized(NSWorkspace.shared.icon(for: type(for: suffix)))
        icons[suffix] = icon
        return icon
    }

    private func type(for suffix: String) -> UTType {
        suffix.isEmpty ? .data : UTType(filenameExtension: suffix) ?? .data
    }

    private func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: Self.iconSide, height: Self.iconSide)
        return image
    }
}

enum PreviewArchiveDescription {
    static func size(_ node: ArchiveNode) -> String {
        node.fileSize.map { $0.formatted(.byteCount(style: .file)) } ?? "--"
    }

    static func modified(_ node: ArchiveNode) -> String {
        node.entry?.modified?.formatted(date: .abbreviated, time: .shortened) ?? "--"
    }

    static func accessibilityLabel(_ row: PreviewArchiveRow, kinds: PreviewArchiveKinds) -> String {
        var parts = [row.name, kinds.description(for: row)]
        if let size = row.node.fileSize { parts.append(size.formatted(.byteCount(style: .file))) }
        if let modified = row.node.entry?.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        if row.node.entry?.isEncrypted == true { parts.append(String(localized: "Encrypted")) }
        return parts.joined(separator: ", ")
    }
}

struct PreviewArchiveOutline: NSViewRepresentable {
    let roots: [ArchiveNode]
    let revision: Int
    let expandsAll: Bool
    let foldersFirst: Bool

    func makeCoordinator() -> Coordinator { Coordinator(sort: PreviewArchiveSort(foldersFirst: foldersFirst)) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = PreviewArchiveOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.autosaveExpandedItems = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.style = .inset
        for column in PreviewArchiveColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column == .size { tableColumn.headerCell.alignment = .right }
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }
        outline.sortDescriptors = [NSSortDescriptor(key: PreviewArchiveColumn.name.rawValue, ascending: true)]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.copyPaths = { [weak coordinator = context.coordinator] rows in coordinator?.copy(rows) }
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Copy Path"), action: #selector(PreviewArchiveOutlineView.copy(_:)),
            keyEquivalent: ""
        ).target = outline
        outline.menu = menu
        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.outline = outline
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.show(roots, revision: revision, expandsAll: expandsAll)
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: PreviewArchiveOutlineView?
        private var roots: [PreviewArchiveRow] = []
        private var shownRevision: Int?
        private var sort: PreviewArchiveSort
        // Zero keeps the listing's own name order.
        private var sortRevision = 0
        private let kinds = PreviewArchiveKinds()

        init(sort: PreviewArchiveSort) {
            self.sort = sort
        }

        func show(_ nodes: [ArchiveNode], revision: Int, expandsAll: Bool) {
            guard revision != shownRevision, let outline else { return }
            shownRevision = revision
            roots = sorted(PreviewArchiveRow.rows(nodes))
            outline.reloadData()
            if expandsAll { outline.expandItem(nil, expandChildren: true) }
        }

        func copy(_ rows: [PreviewArchiveRow]) {
            guard !rows.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
        }

        private func children(of item: Any?) -> [PreviewArchiveRow] {
            guard let parent = item as? PreviewArchiveRow else { return roots }
            if let cached = parent.sortedChildren, cached.revision == sortRevision { return cached.rows }
            let rows = sorted(parent.children)
            parent.sortedChildren = (sortRevision, rows)
            return rows
        }

        // Sorts each folder lazily, on first display.
        private func sorted(_ rows: [PreviewArchiveRow]) -> [PreviewArchiveRow] {
            guard sortRevision > 0 else { return rows }
            return rows.sorted { [sort, kinds] in sort.ordered($0, $1, kinds: kinds) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? PreviewArchiveRow)?.node.children?.isEmpty == false
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first,
                let column = descriptor.key.flatMap(PreviewArchiveColumn.init(rawValue:))
            else { return }
            sort.column = column
            sort.ascending = descriptor.ascending
            sortRevision += 1
            roots = sorted(roots)
            outlineView.reloadData()
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any)
            -> String?
        {
            (item as? PreviewArchiveRow)?.name
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let row = item as? PreviewArchiveRow,
                let column = tableColumn.flatMap({ PreviewArchiveColumn(rawValue: $0.identifier.rawValue) })
            else { return nil }
            let cell =
                outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue), owner: nil)
                as? PreviewArchiveCell ?? PreviewArchiveCell(column: column)
            switch column {
            case .name:
                cell.show(
                    row.name, icon: kinds.icon(for: row), locked: row.node.entry?.isEncrypted == true,
                    tooltip: row.path, accessibility: PreviewArchiveDescription.accessibilityLabel(row, kinds: kinds))
            case .size: cell.show(PreviewArchiveDescription.size(row.node))
            case .modified: cell.show(PreviewArchiveDescription.modified(row.node))
            case .kind: cell.show(kinds.description(for: row))
            }
            return cell
        }
    }
}

final class PreviewArchiveOutlineView: NSOutlineView {
    var copyPaths: (([PreviewArchiveRow]) -> Void)?

    override var needsPanelToBecomeKey: Bool { true }

    // Inactive apps' menus miss Command-C.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "c"
        else { return super.performKeyEquivalent(with: event) }
        copy(nil)
        return true
    }

    @objc func copy(_ sender: Any?) {
        var indexes = selectedRowIndexes
        if clickedRow >= 0, !indexes.contains(clickedRow) { indexes = IndexSet(integer: clickedRow) }
        copyPaths?(indexes.compactMap { item(atRow: $0) as? PreviewArchiveRow })
    }

    // Name absorbs the width others leave.
    override func layout() {
        super.layout()
        let available = enclosingScrollView?.contentSize.width ?? bounds.width
        for column in PreviewArchiveColumn.allCases {
            let hidden = available < column.minimumOutlineWidth
            if let tableColumn = tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)),
                tableColumn.isHidden != hidden
            {
                tableColumn.isHidden = hidden
            }
        }
        guard let name = outlineTableColumn,
            let last = tableColumns.indices.last(where: { !tableColumns[$0].isHidden })
        else { return }
        let overflow = rect(ofColumn: last).maxX + rect(ofColumn: 0).minX - available
        let width = max(name.minWidth, name.width - overflow)
        if abs(width - name.width) >= 1 { name.width = width }
    }
}

final class PreviewArchiveCell: NSTableCellView {
    private static let inset: CGFloat = 2
    private static let gap: CGFloat = 6
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let lock = NSImageView()

    init(column: PreviewArchiveColumn) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        var constraints = [label.centerYAnchor.constraint(equalTo: centerYAnchor)]
        if column == .name {
            icon.translatesAutoresizingMaskIntoConstraints = false
            lock.translatesAutoresizingMaskIntoConstraints = false
            lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            lock.contentTintColor = .secondaryLabelColor
            lock.symbolConfiguration = .init(scale: .small)
            imageView = icon
            addSubview(icon)
            addSubview(lock)
            setAccessibilityElement(true)
            setAccessibilityRole(.cell)
            label.setAccessibilityElement(false)
            icon.setAccessibilityElement(false)
            lock.setAccessibilityElement(false)
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: PreviewArchiveKinds.iconSide),
                icon.heightAnchor.constraint(equalToConstant: PreviewArchiveKinds.iconSide),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.gap),
                lock.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Self.inset * 2),
                lock.centerYAnchor.constraint(equalTo: centerYAnchor),
                lock.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset),
            ]
        } else {
            label.textColor = .secondaryLabelColor
            label.alignment = column == .size ? .right : .left
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            ]
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ text: String) {
        label.stringValue = text
    }

    func show(_ name: String, icon image: NSImage, locked: Bool, tooltip: String, accessibility: String) {
        label.stringValue = name
        label.toolTip = tooltip
        icon.image = image
        lock.isHidden = !locked
        setAccessibilityLabel(accessibility)
        setAccessibilityHelp(tooltip)
    }
}
