import Darwin
import Foundation

enum FolderExclusionScope {
    case duplicates
    case empty
    case tree
    case analyze
    case rename
}

struct FolderFilter {
    private let literalFolderNames: Set<String>
    private let folderPatterns: [String]
    private let filePatterns: [String]
    private let extensionPatterns: [String]

    init(settings: FolderSettings, scope: FolderExclusionScope) {
        let specific: FolderExclusions
        switch scope {
        case .duplicates: specific = settings.duplicateExclusions
        case .empty: specific = settings.emptyExclusions
        case .tree: specific = settings.treeExclusions
        case .analyze: specific = settings.analyzeExclusions
        case .rename: specific = settings.renameExclusions
        }
        literalFolderNames = Set(settings.excludedNames.map { $0.lowercased() })
        folderPatterns = Self.patterns(settings.scanExclusions.folders) + Self.patterns(specific.folders)
        filePatterns = Self.patterns(settings.scanExclusions.files) + Self.patterns(specific.files)
        extensionPatterns = (Self.patterns(settings.scanExclusions.extensions) + Self.patterns(specific.extensions))
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
    }

    init(folderNames: Set<String>) {
        literalFolderNames = Set(folderNames.map { $0.lowercased() })
        folderPatterns = []
        filePatterns = []
        extensionPatterns = []
    }

    func excludes(_ url: URL, isFolder: Bool) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if isFolder { return literalFolderNames.contains(name) || folderPatterns.contains { Self.matches($0, name) } }
        if filePatterns.contains(where: { Self.matches($0, name) }) { return true }
        let pathExtension = url.pathExtension.lowercased()
        return extensionPatterns.contains { Self.matches($0, pathExtension) }
    }

    func excludesFolderOrAncestor(_ folder: URL) -> Bool {
        for candidate in [folder.standardizedFileURL, folder.resolvingSymlinksInPath().standardizedFileURL] {
            var current = candidate
            while current.pathComponents.count > 1 {
                if excludes(current, isFolder: true) { return true }
                current = current.deletingLastPathComponent()
            }
        }
        return false
    }

    private static func patterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
