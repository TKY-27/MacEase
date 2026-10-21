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
        var lines = [folder.lastPathComponent]
        try appendChildren(of: folder, indent: "", excluding: excludedNames, foldersOnly: foldersOnly, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendChildren(
        of folder: URL,
        indent: String,
        excluding excludedNames: Set<String>,
        foldersOnly: Bool,
        to lines: inout [String]
    ) throws {
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: FolderWalk.folderKeys, options: [.skipsHiddenFiles]
        )
        .filter { !excludedNames.contains($0.lastPathComponent) }
        .map { url in (url: url, isFolder: try FolderWalk.isPlainFolder(url)) }
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
                of: child.url, indent: indent + (isLast ? gap : trunk), excluding: excludedNames,
                foldersOnly: foldersOnly, to: &lines)
        }
    }
}
