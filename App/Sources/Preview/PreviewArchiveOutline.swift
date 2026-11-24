import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class PreviewArchiveRow {
    let node: ArchiveNode
    private(set) lazy var name = ArchiveTree.displayText(node.name)
    private(set) lazy var path = ArchiveTree.displayText(node.path)
    lazy var children: [PreviewArchiveRow] = Self.rows(node.children ?? [])

    init(node: ArchiveNode) {
        self.node = node
    }

    static func rows(_ nodes: [ArchiveNode]) -> [PreviewArchiveRow] {
        nodes.map(PreviewArchiveRow.init)
    }

    var fileExtension: String { node.fileExtension }
}

enum PreviewArchiveColumn: String, CaseIterable, Sendable {
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

// Kinds come from extensions, never contents.
enum PreviewArchiveKindDescriptions {
    static func describe(isDirectory: Bool, fileExtension: String) -> String {
        if isDirectory { return String(localized: "Folder") }
        let kind = type(for: fileExtension)
        // Type descriptions start lowercase; Finder's kinds don't.
        return kind == .data
            ? String(localized: "Document")
            : kind.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                ?? String(localized: "Document")
    }

    static func type(for suffix: String) -> UTType {
        suffix.isEmpty ? .data : UTType(filenameExtension: suffix) ?? .data
    }
}

struct PreviewArchiveSort: Equatable, Sendable {
    private static let finderDomain = "com.apple.finder"
    private static let foldersFirstKey = "_FXSortFoldersFirst"
    private static let cancellationCheckMask = 1_023

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
        try PreviewArchiveSort(column: .name, ascending: true, foldersFirst: foldersFirst).sorted(nodes)
    }

    func sorted(
        _ nodes: [ArchiveNode], check: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [ArchiveNode] {
        var kindCache: [String: String] = [:]
        func kind(for node: ArchiveNode) -> String {
            if node.isDirectory { return String(localized: "Folder") }
            let suffix = node.fileExtension
            if let cached = kindCache[suffix] { return cached }
            let described = PreviewArchiveKindDescriptions.describe(isDirectory: false, fileExtension: suffix)
            kindCache[suffix] = described
            return described
        }

        func sortLevel(_ siblings: [ArchiveNode]) throws -> [ArchiveNode] {
            try check()
            var comparisons = 0
            let indexed = Array(siblings.enumerated())
            let ordered = try indexed.sorted { lhs, rhs in
                comparisons += 1
                if comparisons & Self.cancellationCheckMask == 0 { try check() }
                return isOrderedBefore(
                    lhs.element, lhs.offset, rhs.element, rhs.offset, kind: kind)
            }
            return try ordered.map { pair in
                let node = pair.element
                guard let children = node.children else { return node }
                return ArchiveNode(
                    id: node.id, path: node.path, name: node.name, entry: node.entry,
                    children: try sortLevel(children))
            }
        }
        return try sortLevel(nodes)
    }

    func ordered(_ lhs: PreviewArchiveRow, _ rhs: PreviewArchiveRow, kinds: PreviewArchiveKinds) -> Bool {
        isOrderedBefore(lhs.node, 0, rhs.node, 1) { node in
            PreviewArchiveKindDescriptions.describe(isDirectory: node.isDirectory, fileExtension: node.fileExtension)
        }
    }

    private func isOrderedBefore(
        _ lhs: ArchiveNode, _ lhsOrder: Int, _ rhs: ArchiveNode, _ rhsOrder: Int,
        kind: (ArchiveNode) -> String
    ) -> Bool {
        if foldersFirst, column == .name, lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        switch column {
        case .name:
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == (ascending ? .orderedAscending : .orderedDescending) }
            return lhsOrder < rhsOrder
        case .size:
            if let decided = compareOptional(lhs.fileSize, rhs.fileSize) { return decided }
            return breakTie(lhs, lhsOrder, rhs, rhsOrder)
        case .modified:
            if let decided = compareOptional(lhs.entry?.modified, rhs.entry?.modified) { return decided }
            return breakTie(lhs, lhsOrder, rhs, rhsOrder)
        case .kind:
            let order = kind(lhs).localizedStandardCompare(kind(rhs))
            if order != .orderedSame { return order == (ascending ? .orderedAscending : .orderedDescending) }
            return breakTie(lhs, lhsOrder, rhs, rhsOrder)
        }
    }

    // Unknown values stay last in both directions.
    private func compareOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?):
            guard lhs != rhs else { return nil }
            return ascending ? lhs < rhs : lhs > rhs
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        }
    }

    private func breakTie(_ lhs: ArchiveNode, _ lhsOrder: Int, _ rhs: ArchiveNode, _ rhsOrder: Int) -> Bool {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhsOrder < rhsOrder
    }
}

extension ArchiveNode {
    var fileSize: Int64? { isDirectory ? nil : entry?.size }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

final class PreviewArchiveKinds {
    static let iconSide: CGFloat = 16
    private var descriptions: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private lazy var folderIcon = sized(NSWorkspace.shared.icon(for: .folder))

    func description(for row: PreviewArchiveRow) -> String {
        if row.node.isDirectory { return String(localized: "Folder") }
        let suffix = row.fileExtension
        if let known = descriptions[suffix] { return known }
        let described = PreviewArchiveKindDescriptions.describe(isDirectory: false, fileExtension: suffix)
        descriptions[suffix] = described
        return described
    }

    func icon(for row: PreviewArchiveRow) -> NSImage {
        if row.node.isDirectory { return folderIcon }
        let suffix = row.fileExtension
        if let known = icons[suffix] { return known }
        let icon = sized(NSWorkspace.shared.icon(for: PreviewArchiveKindDescriptions.type(for: suffix)))
        icons[suffix] = icon
        return icon
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
    var sortColumn = PreviewArchiveColumn.name
    var sortAscending = true
    var onSortChange: (PreviewArchiveColumn, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        outline.sortDescriptors = [NSSortDescriptor(key: sortColumn.rawValue, ascending: sortAscending)]
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
        context.coordinator.onSortChange = onSortChange
        context.coordinator.syncSort(column: sortColumn, ascending: sortAscending)
        context.coordinator.show(roots, revision: revision, expandsAll: expandsAll)
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: PreviewArchiveOutlineView?
        var onSortChange: ((PreviewArchiveColumn, Bool) -> Void)?
        private var roots: [PreviewArchiveRow] = []
        private var shownRevision: Int?
        private var appliedSort: (PreviewArchiveColumn, Bool) = (.name, true)
        private var syncingSort = false
        private let kinds = PreviewArchiveKinds()

        func syncSort(column: PreviewArchiveColumn, ascending: Bool) {
            guard appliedSort != (column, ascending), let outline else { return }
            appliedSort = (column, ascending)
            syncingSort = true
            outline.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
            syncingSort = false
        }

        func show(_ nodes: [ArchiveNode], revision: Int, expandsAll: Bool) {
            guard revision != shownRevision, let outline else { return }
            shownRevision = revision
            roots = PreviewArchiveRow.rows(nodes)
            outline.reloadData()
            if expandsAll { outline.expandItem(nil, expandChildren: true) }
        }

        func copy(_ rows: [PreviewArchiveRow]) {
            guard !rows.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
        }

        private func children(of row: Any?) -> [PreviewArchiveRow] {
            guard let parent = row as? PreviewArchiveRow else { return roots }
            return parent.children
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
            guard !syncingSort, let descriptor = outlineView.sortDescriptors.first,
                let column = descriptor.key.flatMap(PreviewArchiveColumn.init(rawValue:))
            else { return }
            appliedSort = (column, descriptor.ascending)
            onSortChange?(column, descriptor.ascending)
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

final class PreviewArchiveOutlineView: NSOutlineView, NSMenuItemValidation {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var copyPaths: (([PreviewArchiveRow]) -> Void)?

    override var needsPanelToBecomeKey: Bool { true }

    // Inactive apps' menus miss Command-C.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
            event.modifierFlags.intersection(Self.shortcutModifiers) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "c",
            !selectedRowIndexes.isEmpty
        else { return super.performKeyEquivalent(with: event) }
        copy(nil)
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return false }
        return !targetRowIndexes(fromContextMenu: menuItem.menu === menu).isEmpty
    }

    @objc func copy(_ sender: Any?) {
        let fromContext = (sender as? NSMenuItem)?.menu === menu
        let indexes = targetRowIndexes(fromContextMenu: fromContext)
        guard !indexes.isEmpty else { return }
        copyPaths?(indexes.compactMap { item(atRow: $0) as? PreviewArchiveRow })
    }

    func targetRowIndexes(fromContextMenu: Bool) -> IndexSet {
        if fromContextMenu {
            guard clickedRow >= 0 else { return IndexSet() }
            return selectedRowIndexes.contains(clickedRow) ? selectedRowIndexes : IndexSet(integer: clickedRow)
        }
        return selectedRowIndexes
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
