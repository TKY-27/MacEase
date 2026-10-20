import Foundation

public indirect enum MenuNode: Equatable, Sendable {
    case submenu(title: String, children: [MenuNode])
    case action(title: String, entryIndex: Int)
    case separator
}

public enum MenuLayout {
    /// Empty when no entry applies.
    public static func nodes(for file: MenuFile, selection: [URL]) -> [MenuNode] {
        var counts: [FileKind: Int] = [:]
        var fileCount = 0
        for url in selection {
            let kind = FileKind(fileURL: url)
            if let kind { counts[kind, default: 0] += 1 }
            if kind != .folder { fileCount += 1 }
        }
        if fileCount > 0 { counts[.any] = fileCount }

        let kinds = FileKind.menuOrder.filter { kind in
            guard let count = counts[kind] else { return false }
            return file.entries.contains { $0.kind == kind && count >= $0.op.minimumSelection }
        }
        let specificKinds = kinds.filter { $0 != .any }
        let classifiedCount = specificKinds.reduce(0) { $0 + (counts[$1] ?? 0) }

        if specificKinds.count == 1, let kind = specificKinds.first, classifiedCount == selection.count {
            var nodes = operationNodes(for: kind, count: counts[kind] ?? 0, in: file)
            if kinds.contains(.any) {
                nodes.append(.separator)
                nodes += operationNodes(for: .any, count: fileCount, in: file)
            }
            return nodes
        }
        if specificKinds.isEmpty, kinds.contains(.any) {
            return operationNodes(for: .any, count: fileCount, in: file)
        }
        return kinds.map { kind in
            let count = counts[kind] ?? 0
            return .submenu(
                title: "\(file.kindTitle(kind)) (\(count))",
                children: operationNodes(for: kind, count: count, in: file)
            )
        }
    }

    private static func operationNodes(for kind: FileKind, count: Int, in file: MenuFile) -> [MenuNode] {
        var nodes: [MenuNode] = []
        var openTitle: String?
        var openChildren: [MenuNode] = []

        func closeSubmenu() {
            if let title = openTitle { nodes.append(.submenu(title: title, children: openChildren)) }
            openTitle = nil
            openChildren = []
        }

        for (index, entry) in file.entries.enumerated()
        where entry.kind == kind && count >= entry.op.minimumSelection {
            guard let title = entry.path.first else { continue }
            guard entry.path.count > 1, let leafTitle = entry.path.last else {
                closeSubmenu()
                nodes.append(.action(title: title, entryIndex: index))
                continue
            }
            if openTitle != title {
                closeSubmenu()
                openTitle = title
            }
            if entry.isCustom { openChildren.append(.separator) }
            openChildren.append(.action(title: leafTitle, entryIndex: index))
        }
        closeSubmenu()
        return nodes
    }
}
