import Engine
import Foundation

enum ArchiveTreeError: LocalizedError {
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            String(localized: "Archive folder paths exceed the 32 MiB display limit.", comment: "Archive tree limit")
        }
    }
}

struct ArchiveNode: Identifiable, Sendable {
    let id: String
    let path: String
    let name: String
    let entry: ArchiveEntry?
    let children: [ArchiveNode]?

    var isDirectory: Bool { children != nil }
}

enum ArchiveTree {
    static func normalized(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }).dropLast(path.hasSuffix("/") ? 1 : 0))
    }

    static func filtered(_ nodes: [ArchiveNode], query search: String) -> [ArchiveNode] {
        let query = search.localizedLowercase
        func matching(_ node: ArchiveNode) -> ArchiveNode? {
            let children = node.children?.compactMap(matching)
            guard node.path.localizedLowercase.contains(query) || !(children?.isEmpty ?? true) else { return nil }
            return ArchiveNode(
                id: node.id, path: node.path, name: node.name, entry: node.entry,
                children: node.children == nil ? nil : children)
        }
        return nodes.compactMap(matching)
    }

    static func nodes(_ entries: [ArchiveEntry]) throws -> [ArchiveNode] {
        let pathLimit = 32 * 1024 * 1024
        var retainedPathBytes = 0
        var folders: [String: Set<String>] = [:]
        var directoryEntries: [String: [ArchiveEntry]] = [:]
        var files: [String: [ArchiveEntry]] = [:]
        func retain(_ path: String) throws {
            let bytes = path.utf8.count
            guard bytes <= pathLimit - retainedPathBytes else { throw ArchiveTreeError.tooLarge }
            retainedPathBytes += bytes
        }
        for entry in entries {
            try Task.checkCancellation()
            let path = normalized(entry.path)
            let components = path.split(separator: "/")
            var parent = ""
            for component in components.prefix(entry.isDirectory ? components.count : max(components.count - 1, 0)) {
                let child = parent.isEmpty ? String(component) : parent + "/" + component
                if folders[parent, default: []].insert(child).inserted { try retain(child) }
                parent = child
            }
            if entry.isDirectory {
                if !(directoryEntries[path] ?? []).isEmpty { try retain(path) }
                directoryEntries[path, default: []].append(entry)
                if folders[path] == nil { folders[path] = [] }
            } else {
                try retain(path)
                files[parent, default: []].append(entry)
            }
        }
        func nodes(in parent: String) -> [ArchiveNode] {
            let directories = (folders[parent] ?? []).sorted { lhs, rhs in
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }.flatMap { path -> [ArchiveNode] in
                let records = directoryEntries[path] ?? []
                let name = String(path.split(separator: "/").last ?? "")
                let owner = ArchiveNode(
                    id: records.first.map { "entry:\($0.id)" } ?? ("folder:" + path),
                    path: path, name: name, entry: records.first, children: nodes(in: path))
                let duplicates = records.dropFirst().map { entry in
                    ArchiveNode(id: "entry:\(entry.id)", path: path, name: name, entry: entry, children: [])
                }
                return [owner] + duplicates
            }
            let leaves = (files[parent] ?? []).sorted { lhs, rhs in
                let order = lhs.path.localizedStandardCompare(rhs.path)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }.map { entry in
                ArchiveNode(
                    id: "entry:\(entry.id)", path: normalized(entry.path),
                    name: String(normalized(entry.path).split(separator: "/").last ?? ""),
                    entry: entry, children: nil)
            }
            return directories + leaves
        }
        return nodes(in: "")
    }
}
