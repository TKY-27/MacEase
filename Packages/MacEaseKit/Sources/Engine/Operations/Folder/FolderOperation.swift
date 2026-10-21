import Formats
import Foundation
import MenuCatalog

/// Visible to hosts that import only Engine.
public typealias ArchiveFormat = Formats.ArchiveFormat

public enum TreeOutput: String, Codable, CaseIterable, Sendable {
    case copy
    case txt
    case md
}

/// One group as confirmed in the panel.
public struct DuplicateRemoval: Codable, Hashable, Sendable {
    public let kept: URL
    public let removed: [URL]

    public init(kept: URL, removed: [URL]) {
        self.kept = kept
        self.removed = removed
    }
}

public enum FolderOperation: Codable, Hashable, Sendable {
    case automaticDuplicates
    case removeDuplicates([DuplicateRemoval], permanently: Bool)
    case removeEmpty([URL], permanently: Bool)
    case tree(TreeOutput)
    case rename(RenameRules)
    case exportAnalysis(FolderAnalysis, format: AnalysisExportFormat = .markdown)
    case compress(ArchiveFormat)
}

enum FolderPlanner {
    private static let macMetadataNames: Set<String> = [".DS_Store", "__MACOSX"]
    private static let appleDoublePrefix = "._"

    static func options(for op: OperationID, preset: String?, settings: FolderSettings) -> FolderOperation? {
        switch op {
        case .folderRemoveDuplicates where settings.duplicateKeepPolicy != .ask: .automaticDuplicates
        case .folderTree: preset.flatMap(TreeOutput.init(rawValue:)).map(FolderOperation.tree)
        case .folderCompress: preset.flatMap(ArchiveFormat.init(rawValue:)).map(FolderOperation.compress)
        default: nil
        }
    }

    static func batch(_ operation: FolderOperation, op: OperationID, folders: [URL], settings: Settings) -> Batch {
        switch operation {
        case .automaticDuplicates:
            let work = OperationPlanner.validated(folders, kind: .folder) { context in
                guard context.settings.folder.duplicateKeepPolicy != .ask else {
                    throw EngineError.invalidInput(.malformed("automatic duplicate keep policy"))
                }
                let groups = try DuplicateScanner.groups(in: folders, settings: context.settings.folder) {
                    context.progress($0)
                }
                guard !groups.isEmpty else { return .skipped(.nothingToRemove) }
                let removals = try groups.map { group -> DuplicateRemoval in
                    let dated = try group.files.map { url -> (URL, Date) in
                        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                        guard let modified = values.contentModificationDate else {
                            throw EngineError.decodeFailed("modification date")
                        }
                        return (url, modified)
                    }
                    let oldest = context.settings.folder.duplicateKeepPolicy == .oldest
                    let sorted = dated.sorted { left, right in
                        if left.1 != right.1 { return oldest ? left.1 < right.1 : left.1 > right.1 }
                        return left.0.standardizedFileURL.path < right.0.standardizedFileURL.path
                    }
                    let kept = sorted[0].0
                    return DuplicateRemoval(kept: kept, removed: sorted.dropFirst().map(\.0))
                }
                return .trashDuplicates(removals)
            }
            return Batch(operation: op, items: [work])
        case .removeDuplicates(let removals, let permanently):
            let items = removals.flatMap { removal in
                removal.removed.map { duplicate in
                    removalItem(
                        duplicate, kind: .any, permanently: permanently && settings.permanentDelete,
                        condition: .duplicate(of: removal.kept))
                }
            }
            return Batch(operation: op, items: items)
        case .removeEmpty(let candidates, let permanently):
            let items = outermost(candidates).map { folder in
                removalItem(
                    folder, kind: .folder, permanently: permanently && settings.permanentDelete,
                    condition: .emptyFolder(settings.folder))
            }
            return Batch(operation: op, items: items)
        case .tree(let output):
            return Batch(operation: op, items: folders.map { treeItem($0, output: output) })
        case .rename(let rules):
            return Batch(operation: op, items: folders.isEmpty ? [] : [renameItem(folders, rules: rules)])
        case .exportAnalysis(let analysis, let format):
            return Batch(operation: op, items: [analysisItem(analysis, format: format)])
        case .compress(let format):
            return Batch(operation: op, items: folders.isEmpty ? [] : [compressItem(folders, format: format)])
        }
    }

    private static func removalItem(
        _ url: URL,
        kind: FileKind,
        permanently: Bool,
        condition: RemovalCondition
    ) -> WorkItem {
        OperationPlanner.validated(url, kind: kind) { _ in
            .trash([url], permanently: permanently, condition: condition)
        }
    }

    /// Trashing an ancestor already removes its descendants.
    private static func outermost(_ folders: [URL]) -> [URL] {
        let paths = Set(folders.map(\.path))
        return folders.filter { folder in
            !paths.contains { folder.path.hasPrefix($0 + "/") }
        }
    }

    private static func treeItem(_ folder: URL, output: TreeOutput) -> WorkItem {
        OperationPlanner.validated(folder, kind: .folder) { context in
            let tree = try FolderTree.text(of: folder, settings: context.settings.folder)
            let name = "\(folder.lastPathComponent) tree.\(output.rawValue)"
            switch output {
            case .copy: return .text(tree, .clipboard)
            case .txt: return try derivedText(tree + "\n", name: name, nextTo: folder, context: context)
            case .md: return try derivedText("```text\n\(tree)\n```\n", name: name, nextTo: folder, context: context)
            }
        }
    }

    private static func analysisItem(_ analysis: FolderAnalysis, format: AnalysisExportFormat) -> WorkItem {
        OperationPlanner.validated(analysis.folder, kind: .folder) { context in
            let name = "\(analysis.folder.lastPathComponent) analysis.\(format.pathExtension)"
            return try derivedText(
                analysis.serialized(as: format), name: name, nextTo: analysis.folder, context: context)
        }
    }

    private static func derivedText(_ text: String, name: String, nextTo url: URL, context: ItemContext) throws
        -> ItemResult
    {
        let staged = try context.stagingURL(for: url, name: name)
        try Data(text.utf8).write(to: staged)
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
    }

    private static func renameItem(_ selection: [URL], rules: RenameRules) -> WorkItem {
        WorkItem(inputs: selection) { context in
            for folder in selection where try !ContentSniffer.matches(folder, kind: .folder) {
                return .skipped(.notADirectory)
            }
            return .rename(try rules.plans(for: RenameRules.targets(for: selection, settings: context.settings.folder)))
        }
    }

    /// Several folders share one parent-named archive.
    private static func compressItem(_ folders: [URL], format: ArchiveFormat) -> WorkItem {
        WorkItem(inputs: folders) { context in
            for folder in folders where try !ContentSniffer.matches(folder, kind: .folder) {
                return .skipped(.notADirectory)
            }
            let anchor = folders[0]
            let title = folders.count == 1 ? anchor : anchor.deletingLastPathComponent()
            let name = "\(title.lastPathComponent).\(format.rawValue)"
            let staged = try context.stagingURL(for: anchor, name: name)
            let excludesMetadata = context.settings.folder.archiveExcludesMacMetadata
            do {
                try ArchiveWriter.write(folders, to: staged, format: format, progress: context.progress) { name in
                    excludesMetadata && (macMetadataNames.contains(name) || name.hasPrefix(appleDoublePrefix))
                }
            } catch let error as FormatError {
                throw ArchivePlanner.engineError(error)
            }
            return .derived(nextTo: anchor, outputs: [StagedFile(url: staged, name: name, check: .archive)])
        }
    }
}
