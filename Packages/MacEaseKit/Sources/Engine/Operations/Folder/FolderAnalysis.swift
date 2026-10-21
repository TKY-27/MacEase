import Foundation

public struct FolderAnalysis: Codable, Hashable, Sendable {
    public struct Root: Codable, Hashable, Sendable {
        public let requested: URL
        public let canonical: URL
        public let coveredBy: URL?

        var relationship: String {
            if let coveredBy { return "covered by \(coveredBy.path)" }
            if requested.standardizedFileURL != canonical { return "alias of \(canonical.path)" }
            return "scanned"
        }
    }

    public enum ScanError: Error {
        case noRoots
        case notFileURL(URL)
        case notFolder(URL)
        case missingFileIdentity(URL)
    }

    private struct FileIdentity: Hashable {
        let volume: UInt64
        let number: UInt64
    }

    public struct TypeTotal: Codable, Hashable, Sendable {
        /// Lowercased; empty for files without one.
        public let pathExtension: String
        public let fileCount: Int
        public let bytes: Int64
    }

    public static let largestFileCount = 50
    private static let hashingShare = 0.9

    public let folder: URL
    public let roots: [Root]
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
        try scan([folder], settings: settings, progress: progress)
    }

    public static func scan(_ requestedRoots: [URL], settings: FolderSettings, progress: (Double) -> Void) throws
        -> FolderAnalysis
    {
        guard let folder = requestedRoots.first else { throw ScanError.noRoots }
        for root in requestedRoots where !root.isFileURL { throw ScanError.notFileURL(root) }
        let canonicalRoots = requestedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        for root in canonicalRoots {
            guard try FolderWalk.isPlainFolder(root) else { throw ScanError.notFolder(root) }
        }
        let rootIdentities = try canonicalRoots.map(fileIdentity)
        let representatives = canonicalRoots.indices.filter { rootIdentities.firstIndex(of: rootIdentities[$0]) == $0 }
        var parentIdentities: [Set<FileIdentity>] = []
        for root in canonicalRoots {
            parentIdentities.append(try ancestorIdentities(of: root))
        }
        let scannedIndices = representatives.filter { index in
            !representatives.contains { other in
                other != index
                    && (isDescendant(canonicalRoots[index], of: canonicalRoots[other])
                        || parentIdentities[index].contains(rootIdentities[other]))
            }
        }
        let scanned = scannedIndices.map { canonicalRoots[$0] }
        let roots = requestedRoots.enumerated().map { index, requested in
            let canonical = canonicalRoots[index]
            let covering = scannedIndices.first { selected in
                selected != index
                    && (rootIdentities[selected] == rootIdentities[index]
                        || isDescendant(canonical, of: canonicalRoots[selected])
                        || parentIdentities[index].contains(rootIdentities[selected]))
            }
            return Root(
                requested: requested, canonical: canonical, coveredBy: covering.map { canonicalRoots[$0] })
        }
        let walked = try FolderWalk.regularFiles(
            in: scanned, excluding: FolderFilter(settings: settings, scope: .analyze),
            options: [.skipsPackageDescendants]
        ).sorted { $0.url.path < $1.url.path }
        var seen = Set<FileIdentity>()
        var files: [SizedFile] = []
        for file in walked {
            try Task.checkCancellation()
            if try seen.insert(fileIdentity(of: file.url)).inserted { files.append(file) }
        }
        let byType = Dictionary(grouping: files) { $0.url.pathExtension.lowercased() }.map { pathExtension, files in
            TypeTotal(pathExtension: pathExtension, fileCount: files.count, bytes: files.reduce(0) { $0 + $1.bytes })
        }
        let rawDuplicates = try DuplicateScanner.groups(in: scanned, settings: settings, scope: .analyze) {
            progress($0 * hashingShare)
        }
        var duplicates: [DuplicateGroup] = []
        for group in rawDuplicates {
            var groupIdentities = Set<FileIdentity>()
            var distinct: [URL] = []
            for url in group.files {
                try Task.checkCancellation()
                if try groupIdentities.insert(fileIdentity(of: url)).inserted { distinct.append(url) }
            }
            if distinct.count > 1 {
                duplicates.append(DuplicateGroup(bytesPerFile: group.bytesPerFile, files: distinct))
            }
        }
        let walkedEmpty = try EmptyFolderScanner.folders(in: scanned, settings: settings, scope: .analyze) { _ in }
        var seenEmpty = Set<FileIdentity>()
        var empty: [URL] = []
        for url in walkedEmpty {
            try Task.checkCancellation()
            if try seenEmpty.insert(fileIdentity(of: url)).inserted { empty.append(url) }
        }
        progress(1)
        return FolderAnalysis(
            folder: folder, roots: roots,
            totalBytes: files.reduce(0) { $0 + $1.bytes },
            fileCount: files.count,
            largestFiles: Array(
                files.sorted { ($0.bytes, $1.url.path) > ($1.bytes, $0.url.path) }.prefix(largestFileCount)),
            sizeByType: byType.sorted { ($0.bytes, $1.pathExtension) > ($1.bytes, $0.pathExtension) },
            duplicateGroups: duplicates,
            emptyFolders: empty
        )
    }

    private static func fileIdentity(of url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
            let number = attributes[.systemFileNumber] as? NSNumber
        else { throw ScanError.missingFileIdentity(url) }
        return FileIdentity(volume: volume.uint64Value, number: number.uint64Value)
    }

    private static func ancestorIdentities(of url: URL) throws -> Set<FileIdentity> {
        var identities = Set<FileIdentity>()
        var current = url
        while current.pathComponents.count > 1 {
            try Task.checkCancellation()
            let parent = current.deletingLastPathComponent().standardizedFileURL
            identities.insert(try fileIdentity(of: parent))
            current = parent
        }
        return identities
    }

    static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateParts = candidate.pathComponents
        let ancestorParts = ancestor.pathComponents
        return candidateParts.count > ancestorParts.count && candidateParts.starts(with: ancestorParts)
    }

    public var markdown: String {
        let reclaimable = duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        var lines = [
            "# \(folder.lastPathComponent)", "",
            "- Total size: \(Self.size(totalBytes))",
            "- Files: \(fileCount)",
            "- Duplicate groups: \(duplicateGroups.count) (\(Self.size(reclaimable)) reclaimable)",
            "- Empty folders: \(emptyFolders.count)", "",
            "## Roots", "",
        ]
        lines += roots.map { root in
            "- \(Self.cell(root.requested.path)) (\(Self.cell(root.relationship)))"
        }
        lines += [
            "", "## Largest files", "",
            "| File | Size |",
            "| --- | ---: |",
        ]
        lines += largestFiles.map { "| \(Self.cell(relativePath($0.url))) | \(Self.size($0.bytes)) |" }
        lines += ["", "## Size by type", "", "| Type | Files | Size |", "| --- | ---: | ---: |"]
        lines += sizeByType.map { "| \(Self.cell($0.pathExtension)) | \($0.fileCount) | \(Self.size($0.bytes)) |" }
        return lines.joined(separator: "\n") + "\n"
    }

    func relativePath(_ url: URL) -> String {
        guard let root = roots.first(where: { $0.coveredBy == nil && Self.isDescendant(url, of: $0.canonical) })
        else { return url.path }
        let relative = url.pathComponents.dropFirst(root.canonical.pathComponents.count).joined(separator: "/")
        return roots.count == 1 ? relative : root.requested.path + "/" + relative
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}
