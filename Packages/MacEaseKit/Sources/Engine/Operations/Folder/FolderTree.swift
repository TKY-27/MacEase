import Foundation

public enum FolderTree {
    private static let branch = "├── "
    private static let lastBranch = "└── "
    private static let trunk = "│   "
    private static let gap = "    "

    /// Hidden items are skipped, as Finder does.
    public static func text(
        of folder: URL, excluding excludedNames: Set<String>, foldersOnly: Bool = false
    ) throws -> String {
        try text(of: folder, filter: FolderFilter(folderNames: excludedNames), foldersOnly: foldersOnly)
    }

    public static func text(of folder: URL, settings: FolderSettings) throws -> String {
        try text(
            of: folder, filter: FolderFilter(settings: settings, scope: .tree),
            foldersOnly: settings.treeFoldersOnly)
    }

    private static func text(of folder: URL, filter: FolderFilter, foldersOnly: Bool) throws -> String {
        var lines = [folder.lastPathComponent]
        if !filter.excludesFolderOrAncestor(folder) {
            try appendChildren(of: folder, indent: "", filter: filter, foldersOnly: foldersOnly, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendChildren(
        of folder: URL,
        indent: String,
        filter: FolderFilter,
        foldersOnly: Bool,
        to lines: inout [String]
    ) throws {
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: FolderWalk.folderKeys, options: [.skipsHiddenFiles]
        )
        .map { url in (url: url, isFolder: try FolderWalk.isPlainFolder(url)) }
        .filter { !filter.excludes($0.url, isFolder: $0.isFolder) }
        .filter { !foldersOnly || $0.isFolder }
        .sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        for (index, child) in children.enumerated() {
            let isLast = index == children.count - 1
            lines.append(indent + (isLast ? lastBranch : branch) + child.url.lastPathComponent)
            guard child.isFolder else { continue }
            try appendChildren(
                of: child.url, indent: indent + (isLast ? gap : trunk), filter: filter,
                foldersOnly: foldersOnly, to: &lines)
        }
    }
}
