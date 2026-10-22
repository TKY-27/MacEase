import Foundation

public struct SizedFile: Codable, Hashable, Sendable {
    public let url: URL
    public let bytes: Int64
}

enum FolderWalk {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    static let folderKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]

    /// Packages and links count as files.
    static func isPlainFolder(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: Set(folderKeys))
        return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
    }

    /// URLs keep the caller's path form.
    static func regularFiles(
        in folders: [URL],
        excluding exclusions: FolderFilter,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [SizedFile] {
        var files: [SizedFile] = []
        var seen = Set<String>()
        for folder in folders {
            if exclusions.excludesFolderOrAncestor(folder) { continue }
            var walkError: (any Error)?
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: options.union(.producesRelativePathURLs)
            ) { _, error in
                walkError = error
                return false
            }
            while let relative = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try relative.resourceValues(forKeys: Set(keys))
                let isFolder = values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
                if exclusions.excludes(relative, isFolder: isFolder) {
                    enumerator?.skipDescendants()
                    continue
                }
                let url = folder.appending(path: relative.relativePath)
                guard values.isRegularFile == true, seen.insert(url.path).inserted else { continue }
                guard let size = values.fileSize else { throw EngineError.decodeFailed("file size") }
                files.append(SizedFile(url: url, bytes: Int64(size)))
            }
            if let walkError { throw walkError }
        }
        return files
    }
}

public struct DuplicateGroup: Codable, Hashable, Sendable {
    public let bytesPerFile: Int64
    /// Sorted by path.
    public let files: [URL]

    public var reclaimableBytes: Int64 { bytesPerFile * Int64(files.count - 1) }
}

public enum DuplicateScanner {
    /// Size, SHA-256, then bytes; biggest savings first.
    public static func groups(
        in folders: [URL],
        settings: FolderSettings,
        progress: (Double) -> Void
    ) throws -> [DuplicateGroup] {
        try groups(in: folders, settings: settings, scope: .duplicates, progress: progress)
    }

    static func groups(
        in folders: [URL], settings: FolderSettings, scope: FolderExclusionScope, progress: (Double) -> Void
    ) throws -> [DuplicateGroup] {
        guard settings.duplicateMinimumBytes >= 0 else {
            throw EngineError.invalidInput(.malformed("duplicate minimum bytes"))
        }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if settings.duplicatesIgnoreHidden { options.insert(.skipsHiddenFiles) }
        let files = try FolderWalk.regularFiles(
            in: folders, excluding: FolderFilter(settings: settings, scope: scope), options: options)
        let filtered = files.filter {
            $0.bytes >= settings.duplicateMinimumBytes && (!settings.duplicatesIgnoreEmpty || $0.bytes > 0)
        }
        let candidates = try Dictionary(
            grouping: filtered.map { file -> (SizedFile, CandidateKey) in
                let values = try file.url.resourceValues(forKeys: [.contentModificationDateKey])
                let second: Int64?
                if settings.duplicatesMatchModificationSecond {
                    guard let date = values.contentModificationDate else {
                        throw EngineError.decodeFailed("modification date")
                    }
                    guard let wholeSecond = Int64(exactly: date.timeIntervalSince1970.rounded(.down)) else {
                        throw EngineError.decodeFailed("modification date")
                    }
                    second = wholeSecond
                } else {
                    second = nil
                }
                return (
                    file,
                    CandidateKey(
                        bytes: file.bytes,
                        name: settings.duplicatesMatchNames ? file.url.lastPathComponent.lowercased() : nil,
                        second: second)
                )
            }, by: { $0.1 }
        ).values.map { $0.map(\.0) }.filter { $0.count > 1 }
        let total = Double(max(1, candidates.joined().reduce(Int64(0)) { $0 + $1.bytes }))
        var hashed: Int64 = 0
        var groups: [DuplicateGroup] = []
        for sameSize in candidates {
            var byDigest: [String: [URL]] = [:]
            for file in sameSize {
                let digest = try Checksum.digest(of: file.url, algorithm: .sha256) { fraction in
                    progress((Double(hashed) + fraction * Double(file.bytes)) / total)
                }
                hashed += file.bytes
                byDigest[digest, default: []].append(file.url)
            }
            for sameDigest in byDigest.values where sameDigest.count > 1 {
                for identical in try byteIdenticalSets(sameDigest) {
                    groups.append(DuplicateGroup(bytesPerFile: sameSize[0].bytes, files: identical))
                }
            }
        }
        return groups.sorted { ($0.reclaimableBytes, $1.files[0].path) > ($1.reclaimableBytes, $0.files[0].path) }
    }

    private struct CandidateKey: Hashable {
        let bytes: Int64
        let name: String?
        let second: Int64?
    }

    private static func byteIdenticalSets(_ urls: [URL]) throws -> [[URL]] {
        var remaining = urls.sorted { $0.path < $1.path }
        var sets: [[URL]] = []
        while let first = remaining.first {
            try Task.checkCancellation()
            let identical = remaining.filter {
                $0 == first || FileManager.default.contentsEqual(atPath: first.path, andPath: $0.path)
            }
            remaining.removeAll { identical.contains($0) }
            if identical.count > 1 { sets.append(identical) }
        }
        return sets
    }
}

public enum EmptyFolderScanner {
    private static let finderMetadataName = ".DS_Store"

    /// Outermost empty folders, sorted by path.
    public static func folders(in roots: [URL], settings: FolderSettings, progress: (Double) -> Void) throws -> [URL] {
        try folders(in: roots, settings: settings, scope: .empty, progress: progress)
    }

    static func folders(
        in roots: [URL], settings: FolderSettings, scope: FolderExclusionScope, progress: (Double) -> Void
    ) throws -> [URL] {
        var found: [URL] = []
        let filter = FolderFilter(settings: settings, scope: scope)
        for (index, root) in roots.enumerated() {
            if !filter.excludesFolderOrAncestor(root) {
                _ = try visit(root, settings: settings, filter: filter, isRoot: true, found: &found)
            }
            progress(Double(index + 1) / Double(roots.count))
        }
        return found.sorted { $0.path < $1.path }
    }

    static func isEmpty(_ folder: URL, settings: FolderSettings) throws -> Bool {
        var ignored: [URL] = []
        let filter = FolderFilter(settings: settings, scope: .empty)
        if filter.excludesFolderOrAncestor(folder) { return false }
        return try visit(
            folder, settings: settings, filter: filter,
            isRoot: false, found: &ignored)
    }

    private static func visit(
        _ folder: URL, settings: FolderSettings, filter: FolderFilter, isRoot: Bool, found: inout [URL]
    ) throws -> Bool {
        try Task.checkCancellation()
        var empty = true
        var emptyChildren: [URL] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
            let child = folder.appending(path: name)
            let isFolder = try FolderWalk.isPlainFolder(child)
            let isCandidate = isFolder && !filter.excludes(child, isFolder: true)
            if isCandidate, try visit(child, settings: settings, filter: filter, isRoot: false, found: &found) {
                emptyChildren.append(child)
            } else {
                let type = try child.resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType
                if !(settings.emptyIgnoresDSStore && name == finderMetadataName && type == .regular
                    && !filter.excludes(child, isFolder: false))
                {
                    empty = false
                }
            }
        }
        if !empty || isRoot { found += emptyChildren }
        return empty
    }
}
