import Foundation

public indirect enum MenuNode: Equatable, Sendable {
    case submenu(title: String, children: [MenuNode])
    case action(title: String, entryIndex: Int)
    case separator
}

public enum MenuLayout {
    public static func nodes(for file: MenuFile, selection: [URL]) -> [MenuNode] {
        let summary = SelectionSummary(selection)
        var primary: [FileKind: [(Int, MenuEntry)]] = [:]
        var more: [FileKind: [(Int, MenuEntry)]] = [:]
        for (index, entry) in file.entries.enumerated() where entry.op != .folderDownloadMedia {
            if entry.resolvedPlacement == .primary {
                primary[entry.kind, default: []].append((index, entry))
            } else {
                more[entry.kind, default: []].append((index, entry))
            }
        }
        let selectedKinds = FileKind.menuOrder.filter { $0 != .any && summary.count(for: $0) > 0 }
        let singleKind =
            selectedKinds.count == 1 && selectedKinds.first.map { summary.count(for: $0) } == selection.count
        var nodes: [MenuNode] = []
        var moreNodes: [MenuNode] = []
        for kind in FileKind.menuOrder {
            let title = "\(file.kindTitle(kind)) (\(summary.count(for: kind)))"
            let ordered = (primary[kind] ?? []).sorted {
                let left = $0.1.op.primaryMenuRank
                let right = $1.1.op.primaryMenuRank
                return left == right ? $0.0 < $1.0 : left < right
            }
            let children = operationNodes(ordered, summary: summary)
            if !children.isEmpty {
                if singleKind { nodes += children } else { nodes.append(.submenu(title: title, children: children)) }
            }
            var overflow = operationNodes(more[kind] ?? [], summary: summary)
            if !singleKind, !selectedKinds.isEmpty {
                overflow = overflow.map { node in
                    switch node {
                    case .action(let operation, let index): .action(title: "\(title): \(operation)", entryIndex: index)
                    case .submenu(let operation, let children):
                        .submenu(title: "\(title): \(operation)", children: children)
                    case .separator: .separator
                    }
                }
            }
            if !overflow.isEmpty {
                if !moreNodes.isEmpty { moreNodes.append(.separator) }
                moreNodes += overflow
            }
        }
        if !moreNodes.isEmpty {
            if !nodes.isEmpty { nodes.append(.separator) }
            nodes.append(.submenu(title: file.moreTitle ?? "More", children: moreNodes))
        }
        return nodes
    }

    public static func isApplicable(_ entry: MenuEntry, selection: [URL]) -> Bool {
        SelectionSummary(selection).allows(entry)
    }

    private static func operationNodes(_ entries: [(Int, MenuEntry)], summary: SelectionSummary) -> [MenuNode] {
        var nodes: [MenuNode] = []
        var openTitle: String?
        var openGroup: String?
        var openChildren: [MenuNode] = []
        var pendingBoundaries: Set<String> = []
        let rootLevel = ""
        var operationBoundary = false

        func closeSubmenu() {
            if let title = openTitle, !openChildren.isEmpty {
                nodes.append(.submenu(title: title, children: openChildren))
            }
            openTitle = nil
            openGroup = nil
            openChildren = []
        }

        for (index, entry) in entries {
            guard let title = entry.path.first else { continue }
            let parent = entry.path.count > 1 ? entry.resolvedGroupID : rootLevel
            if entry.separatorBefore { pendingBoundaries.insert(parent) }
            if entry.operationSeparatorBefore { operationBoundary = true }
            guard summary.allows(entry) else { continue }
            if entry.path.count == 1 || openGroup != entry.resolvedGroupID {
                closeSubmenu()
                if operationBoundary, !nodes.isEmpty, nodes.last != .separator { nodes.append(.separator) }
                operationBoundary = false
            }
            if entry.path.count == 1 {
                if pendingBoundaries.remove(parent) != nil, !nodes.isEmpty, nodes.last != .separator {
                    nodes.append(.separator)
                }
                nodes.append(.action(title: title, entryIndex: index))
            } else if let leafTitle = entry.path.last {
                if openGroup != entry.resolvedGroupID {
                    closeSubmenu()
                    openTitle = title
                    openGroup = entry.resolvedGroupID
                }
                if pendingBoundaries.remove(parent) != nil, !openChildren.isEmpty {
                    openChildren.append(.separator)
                }
                openChildren.append(.action(title: leafTitle, entryIndex: index))
            }
        }
        closeSubmenu()
        return nodes
    }
}

private struct SelectionSummary {
    private var counts: [FileKind: Int] = [:]
    private var formats: [FileKind: Set<String>] = [:]
    private let totalCount: Int

    init(_ selection: [URL]) {
        totalCount = selection.count
        for url in selection {
            let kind = FileKind(fileURL: url)
            let format = FileKind.canonicalFormat(for: url)
            if let kind {
                counts[kind, default: 0] += 1
                formats[kind, default: []].insert(format)
            }
            if kind != .folder {
                counts[.any, default: 0] += 1
                formats[.any, default: []].insert(format)
            }
        }
    }

    func count(for kind: FileKind) -> Int { counts[kind] ?? 0 }

    func allows(_ entry: MenuEntry) -> Bool {
        if entry.op == .folderDownloadMedia { return totalCount == 1 && count(for: .folder) == 1 }
        let count = count(for: entry.kind)
        guard count >= entry.minimumSelection, entry.maximumSelection.map({ count <= $0 }) ?? true else {
            return false
        }
        if let accepted = entry.acceptedKinds {
            let supportedCount = accepted.reduce(0) { $0 + self.count(for: $1) }
            guard supportedCount == totalCount else { return false }
        }
        let sources = formats[entry.kind] ?? []
        if entry.requiresSingleSourceFormat, sources.count != 1 { return false }
        if let allowed = entry.sourceFormats, !sources.isSubset(of: allowed) { return false }
        if let target = entry.targetFormat, sources == [target] { return false }
        return true
    }
}
