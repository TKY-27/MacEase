import Foundation

public struct FolderAnalysis: Codable, Hashable, Sendable {
    public struct TypeTotal: Codable, Hashable, Sendable {
        /// Lowercased; empty for files without one.
        public let pathExtension: String
        public let fileCount: Int
        public let bytes: Int64
    }

    public static let largestFileCount = 50
    private static let hashingShare = 0.9

    public let folder: URL
    public let totalBytes: Int64
    public let fileCount: Int
    public let largestFiles: [SizedFile]
    /// Largest share first.
    public let sizeByType: [TypeTotal]
    public let duplicateGroups: [DuplicateGroup]
    public let emptyFolders: [URL]

    public static func scan(_ folder: URL, settings: FolderSettings, progress: (Double) -> Void) throws
        -> FolderAnalysis
    {
        let files = try FolderWalk.regularFiles(in: [folder], excluding: Set(settings.excludedNames), options: [])
        let byType = Dictionary(grouping: files) { $0.url.pathExtension.lowercased() }.map { pathExtension, files in
            TypeTotal(pathExtension: pathExtension, fileCount: files.count, bytes: files.reduce(0) { $0 + $1.bytes })
        }
        let duplicates = try DuplicateScanner.groups(in: [folder], settings: settings) { progress($0 * hashingShare) }
        let empty = try EmptyFolderScanner.folders(in: [folder], settings: settings) { _ in }
        progress(1)
        return FolderAnalysis(
            folder: folder,
            totalBytes: files.reduce(0) { $0 + $1.bytes },
            fileCount: files.count,
            largestFiles: Array(
                files.sorted { ($0.bytes, $1.url.path) > ($1.bytes, $0.url.path) }.prefix(largestFileCount)),
            sizeByType: byType.sorted { ($0.bytes, $1.pathExtension) > ($1.bytes, $0.pathExtension) },
            duplicateGroups: duplicates,
            emptyFolders: empty
        )
    }

    public var markdown: String {
        let reclaimable = duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        var lines = [
            "# \(folder.lastPathComponent)", "",
            "- Total size: \(Self.size(totalBytes))",
            "- Files: \(fileCount)",
            "- Duplicate groups: \(duplicateGroups.count) (\(Self.size(reclaimable)) reclaimable)",
            "- Empty folders: \(emptyFolders.count)", "",
            "## Largest files", "",
            "| File | Size |",
            "| --- | ---: |",
        ]
        lines += largestFiles.map { "| \(Self.cell(relativePath($0.url))) | \(Self.size($0.bytes)) |" }
        lines += ["", "## Size by type", "", "| Type | Files | Size |", "| --- | ---: | ---: |"]
        lines += sizeByType.map { "| \(Self.cell($0.pathExtension)) | \($0.fileCount) | \(Self.size($0.bytes)) |" }
        return lines.joined(separator: "\n") + "\n"
    }

    private func relativePath(_ url: URL) -> String {
        let prefix = folder.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
