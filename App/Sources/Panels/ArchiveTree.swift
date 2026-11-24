import Engine
import Formats
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
    static let maximumDisplayLength = 1_024
    private static let replacement: Unicode.Scalar = "\u{FFFD}"
    private static let hiddenCategories: Set<Unicode.GeneralCategory> = [
        .control, .lineSeparator, .paragraphSeparator,
    ]
    private static let bidirectionalControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]

    // Untrusted names: keep them inert and short.
    static func displayText(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let hidden =
                hiddenCategories.contains(scalar.properties.generalCategory)
                || bidirectionalControls.contains(scalar.value)
            scalars.append(hidden ? replacement : scalar)
        }
        guard scalars.count > maximumDisplayLength else { return String(scalars) }
        let half = maximumDisplayLength / 2
        let tail = scalars.suffix(half).drop(while: { $0.properties.isGraphemeExtend })
        return String(scalars.prefix(half)) + "…" + String(tail)
    }

    static func count(_ nodes: [ArchiveNode]) -> Int {
        nodes.reduce(nodes.count) { $0 + count($1.children ?? []) }
    }

    static func normalized(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }).dropLast(path.hasSuffix("/") ? 1 : 0))
    }

    static func filtered(_ nodes: [ArchiveNode], query search: String) -> [ArchiveNode] {
        filtered(nodes, query: search) {}
    }

    static func filtered(
        _ nodes: [ArchiveNode], query search: String, check: () throws -> Void
    ) rethrows -> [ArchiveNode] {
        let query = search.localizedLowercase
        func matching(_ node: ArchiveNode) throws -> ArchiveNode? {
            try check()
            let children = try node.children?.compactMap(matching)
            guard node.path.localizedLowercase.contains(query) || !(children?.isEmpty ?? true) else { return nil }
            return ArchiveNode(
                id: node.id, path: node.path, name: node.name, entry: node.entry,
                children: node.children == nil ? nil : children)
        }
        return try nodes.compactMap(matching)
    }

    static func nodes(_ entries: [ArchiveEntry], foldersFirst: Bool = true) throws -> [ArchiveNode] {
        let pathLimit = ArchiveContents.maximumNameBytes
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
            let components = normalized(entry.path).split(separator: "/").filter { $0 != "." }
            guard !components.isEmpty else { continue }
            let path = components.joined(separator: "/")
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
        func nodes(in parent: String) throws -> [ArchiveNode] {
            try Task.checkCancellation()
            let directories = try (folders[parent] ?? []).sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }.flatMap { path -> [ArchiveNode] in
                let records = directoryEntries[path] ?? []
                let name = String(path.split(separator: "/").last ?? "")
                let owner = ArchiveNode(
                    id: records.first.map { "entry:\($0.id)" } ?? ("folder:" + path),
                    path: path, name: name, entry: records.first, children: try nodes(in: path))
                let duplicates = records.dropFirst().map { entry in
                    ArchiveNode(id: "entry:\(entry.id)", path: path, name: name, entry: entry, children: [])
                }
                return [owner] + duplicates
            }
            let leaves = (files[parent] ?? []).sorted { lhs, rhs in
                let order = lhs.path.localizedStandardCompare(rhs.path)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }.map { entry in
                let path = normalized(entry.path).split(separator: "/").filter { $0 != "." }.joined(separator: "/")
                return ArchiveNode(
                    id: "entry:\(entry.id)", path: path,
                    name: String(path.split(separator: "/").last ?? ""),
                    entry: entry, children: nil)
            }
            let combined = directories + leaves
            guard !foldersFirst else { return combined }
            return combined.sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return try nodes(in: "")
    }
}
