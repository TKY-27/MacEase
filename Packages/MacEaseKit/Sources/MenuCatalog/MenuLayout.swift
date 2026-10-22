import Foundation

public indirect enum MenuNode: Equatable, Sendable {
    case submenu(title: String, children: [MenuNode])
    case action(title: String, entryIndex: Int)
    case separator
}

public enum MenuLayout {
    public static func nodes(for file: MenuFile, selection: [URL]) -> [MenuNode] {
        let summary = SelectionSummary(selection)
        let sections = FileKind.menuOrder.compactMap { kind -> (FileKind, [MenuNode])? in
            let children = operationNodes(for: kind, summary: summary, in: file)
            return children.isEmpty ? nil : (kind, children)
        }
        let specificKinds = sections.filter { $0.0 != .any }
        let classifiedCount = specificKinds.reduce(0) { $0 + summary.count(for: $1.0) }
        if specificKinds.count == 1, let section = specificKinds.first, classifiedCount == selection.count {
            var nodes = section.1
            if let allFiles = sections.first(where: { $0.0 == .any }) {
                nodes.append(.separator)
                nodes += allFiles.1
            }
            return nodes
        }
        if specificKinds.isEmpty { return sections.first?.1 ?? [] }
        return sections.map { kind, children in
            .submenu(title: "\(file.kindTitle(kind)) (\(summary.count(for: kind)))", children: children)
        }
    }

    public static func isApplicable(_ entry: MenuEntry, selection: [URL]) -> Bool {
        SelectionSummary(selection).allows(entry)
    }

    private static func operationNodes(for kind: FileKind, summary: SelectionSummary, in file: MenuFile) -> [MenuNode] {
        var nodes: [MenuNode] = []
        var openTitle: String?
        var openChildren: [MenuNode] = []
        var pendingBoundaries: Set<String> = []
        let rootLevel = ""
        var operationBoundary = false

        func closeSubmenu() {
            if let title = openTitle, !openChildren.isEmpty {
                nodes.append(.submenu(title: title, children: openChildren))
            }
            openTitle = nil
            openChildren = []
        }

        for (index, entry) in file.entries.enumerated() where entry.kind == kind {
            guard let title = entry.path.first else { continue }
            let parent = entry.path.count > 1 ? title : rootLevel
            if entry.separatorBefore { pendingBoundaries.insert(parent) }
            if entry.operationSeparatorBefore { operationBoundary = true }
            guard summary.allows(entry) else { continue }
            if entry.path.count == 1 || openTitle != title {
                closeSubmenu()
                if operationBoundary, !nodes.isEmpty, nodes.last != .separator { nodes.append(.separator) }
                operationBoundary = false
            }
            if entry.path.count == 1 {
                if pendingBoundaries.remove(parent) != nil, !nodes.isEmpty { nodes.append(.separator) }
                nodes.append(.action(title: title, entryIndex: index))
            } else if let leafTitle = entry.path.last {
                if openTitle != title {
                    closeSubmenu()
                    openTitle = title
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

    init(_ selection: [URL]) {
        for url in selection {
            let kind = FileKind(fileURL: url)
            let format = FileKind.canonicalFormat(url.pathExtension)
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
        let count = count(for: entry.kind)
        guard count >= entry.minimumSelection, entry.maximumSelection.map({ count <= $0 }) ?? true else {
            return false
        }
        let sources = formats[entry.kind] ?? []
        if entry.requiresSingleSourceFormat, sources.count != 1 { return false }
        if let allowed = entry.sourceFormats, !sources.isSubset(of: allowed) { return false }
        if let target = entry.targetFormat, sources == [target] { return false }
        return true
    }
}
