import Foundation

public indirect enum MenuNode: Equatable, Sendable {
    case submenu(title: String, children: [MenuNode])
    case action(title: String, entryIndex: Int)
    case command(HostCommand, title: String)
    case separator
}

/// Finder-level items and MacEase submenu items.
public struct MenuTree: Equatable, Sendable {
    public let finder: [MenuNode]
    public let macEase: [MenuNode]
}

public enum MenuLayout {
    public static func tree(for file: MenuFile, selection: [URL]) -> MenuTree {
        let summary = SelectionSummary(selection)
        let commandGroups = Set(file.commands.map(\.group.rawValue))
        let indexed = Array(file.entries.enumerated())
        func commands(_ placement: MenuPlacement) -> [MenuNode] {
            file.commands.filter { $0.placement == placement }.flatMap { item -> [MenuNode] in
                if let command = item.command { return [.command(command, title: item.title)] }
                return operationNodes(indexed.filter { $0.1.resolvedGroupID == item.group.rawValue }, summary: summary)
            }
        }
        var primary: [FileKind: [(Int, MenuEntry)]] = [:]
        var more: [FileKind: [(Int, MenuEntry)]] = [:]
        for (index, entry) in indexed where !commandGroups.contains(entry.resolvedGroupID) {
            switch entry.placement {
            case .primary: primary[entry.kind, default: []].append((index, entry))
            case .more: more[entry.kind, default: []].append((index, entry))
            case .finder: break
            }
        }
        var macEase = commands(.primary)
        let nodes = kindNodes(
            primary: primary, more: more, trailingMore: commands(.more), moreTitle: file.moreTitle ?? "More",
            kindTitle: file.kindTitle, summary: summary)
        if !macEase.isEmpty, !nodes.isEmpty { macEase.append(.separator) }
        return MenuTree(finder: commands(.finder), macEase: macEase + nodes)
    }

    private static func kindNodes(
        primary: [FileKind: [(Int, MenuEntry)]], more: [FileKind: [(Int, MenuEntry)]], trailingMore: [MenuNode],
        moreTitle: String, kindTitle: (FileKind) -> String, summary: SelectionSummary
    ) -> [MenuNode] {
        let selectedKinds = FileKind.menuOrder.filter { $0 != .any && summary.count(for: $0) > 0 }
        let singleKind =
            selectedKinds.count == 1 && selectedKinds.first.map { summary.count(for: $0) } == summary.totalCount
        var nodes: [MenuNode] = []
        var moreNodes: [MenuNode] = []
        for kind in FileKind.menuOrder {
            let title = "\(kindTitle(kind)) (\(summary.count(for: kind)))"
            let children = operationNodes(primary[kind] ?? [], summary: summary)
            if kind == .any, !children.isEmpty {
                if !nodes.isEmpty { nodes.append(.separator) }
                nodes += children
            } else if !children.isEmpty {
                if singleKind { nodes += children } else { nodes.append(.submenu(title: title, children: children)) }
            }
            var overflow = operationNodes(more[kind] ?? [], summary: summary)
            if !singleKind, !selectedKinds.isEmpty {
                overflow = overflow.map { node in
                    switch node {
                    case .action(let operation, let index): .action(title: "\(title): \(operation)", entryIndex: index)
                    case .submenu(let operation, let children):
                        .submenu(title: "\(title): \(operation)", children: children)
                    case .command, .separator: node
                    }
                }
            }
            if !overflow.isEmpty {
                if !moreNodes.isEmpty { moreNodes.append(.separator) }
                moreNodes += overflow
            }
        }
        if !trailingMore.isEmpty {
            if !moreNodes.isEmpty { moreNodes.append(.separator) }
            moreNodes += trailingMore
        }
        if !moreNodes.isEmpty {
            if !nodes.isEmpty { nodes.append(.separator) }
            nodes.append(.submenu(title: moreTitle, children: moreNodes))
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

struct SelectionSummary {
    private var counts: [FileKind: Int] = [:]
    private var formats: [FileKind: Set<String>] = [:]
    let totalCount: Int

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
