import Foundation
import ImageIO
import MenuCatalog
import Testing

@testable import Engine

func folderURL(_ parent: URL, _ name: String) -> URL {
    parent.appending(path: name, directoryHint: .isDirectory)
}

/// A trailing slash makes a folder.
func makeTree(_ entries: [String: String], in root: URL) throws {
    for (path, text) in entries {
        let url = root.appending(path: path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            continue
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

func runOperation(
    _ op: OperationID,
    _ options: OperationOptions,
    inputs: [URL],
    settings: Settings = Settings()
) async throws -> BatchOutcome {
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
    TestTemporaryFolders.register(support)
    let engine = try JobEngine(supportDirectory: support, concurrency: 2)
    let batch = OperationPlanner.batch(
        for: OperationRequest(op: op, options: options, inputs: inputs), settings: settings)
    return await engine.run(batch, settings: settings) { _ in }
}

func listing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

@Suite struct FolderPlanningTests {
    @Test func everyMenuPresetMapsAndPanelsReturnNil() throws {
        let settings = Settings()
        for op in OperationID.allCases where op.kind == .folder || op.kind == .archive {
            for preset in op.presets {
                #expect(OperationPlanner.options(for: op, preset: preset, settings: settings) != nil, "\(op) \(preset)")
            }
        }
        #expect(OperationPlanner.options(for: .folderTree, preset: "md", settings: settings) == .folder(.tree(.md)))
        #expect(
            OperationPlanner.options(for: .folderCompress, preset: "tar.gz", settings: settings)
                == .folder(.compress(.tarGzip)))
        #expect(
            OperationPlanner.options(for: .archiveExtract, preset: nil, settings: settings)
                == .archive(.extract(password: nil)))
        let panelOnly: [OperationID] = [
            .folderRemoveDuplicates, .folderRemoveEmpty, .folderRename, .folderAnalyze, .folderTree, .folderCompress,
        ]
        for op in panelOnly {
            #expect(OperationPlanner.options(for: op, preset: nil, settings: settings) == nil, "\(op)")
        }
    }
}

@Suite(.serialized) struct FolderTests {
    @Test func duplicatesAreGroupedExactly() throws {
        let root = try TestVolume.makeFolder()
        try makeTree(
            [
                "a.txt": "hello world", "sub/b.txt": "hello world", "c.txt": "hello worle", "d.txt": "unique",
                "e1.txt": "", "e2.txt": "", ".hidden.txt": "hello world", "node_modules/x.txt": "hello world",
                "Tool.app/Contents/x.txt": "hello world", "f/c copy.txt": "hello worle",
            ], in: root)
        var settings = FolderSettings()

        let groups = try DuplicateScanner.groups(in: [root, root], settings: settings) { _ in }

        #expect(groups.map(\.files.count) == [2, 2])
        let paths = Set(groups.map { $0.files.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } })
        #expect(paths == [["a.txt", "sub/b.txt"], ["c.txt", "f/c copy.txt"]])
        #expect(groups[0].reclaimableBytes == 11)

        settings.duplicatesIgnoreHidden = false
        let withHidden = try DuplicateScanner.groups(in: [root], settings: settings) { _ in }
        #expect(withHidden.map(\.files.count).sorted() == [2, 3])
    }

    @Test func onlyConfirmedDuplicatesGoToTheTrash() async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["keep.txt": "same", "copy1.txt": "same", "copy2.txt": "same", "edited.txt": "same"], in: root)
        let removals = [
            DuplicateRemoval(
                kept: root.appending(path: "keep.txt"),
                removed: [root.appending(path: "copy1.txt"), root.appending(path: "edited.txt")])
        ]
        try Data("diff".utf8).write(to: root.appending(path: "edited.txt"))

        let outcome = try await runOperation(
            .folderRemoveDuplicates, .folder(.removeDuplicates(removals, permanently: true)), inputs: [root])

        #expect(outcome.outcomes == [.succeeded(outputs: [], warnings: []), .skipped(.changedSinceScan)])
        #expect(try listing(root) == ["copy2.txt", "edited.txt", "keep.txt"])
        let record = try #require(outcome.record)
        guard case .removed(let original, let trashed, _) = try #require(record.items.first) else {
            Issue.record("expected a Trash record despite the permanent request")
            return
        }
        #expect(original.hasSuffix("/copy1.txt"))
        #expect(FileManager.default.fileExists(atPath: trashed))
    }

    @Test func permanentDeletionNeedsTheSettingAndKeepsTheSameFile() async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["keep.txt": "same", "copy.txt": "same"], in: root)
        let keep = root.appending(path: "keep.txt")
        let sameFileOtherPath = URL(fileURLWithPath: root.path + "/./keep.txt")
        var settings = Settings()
        settings.permanentDelete = true
        let removal = DuplicateRemoval(kept: keep, removed: [root.appending(path: "copy.txt"), sameFileOtherPath])

        let outcome = try await runOperation(
            .folderRemoveDuplicates, .folder(.removeDuplicates([removal], permanently: true)), inputs: [root],
            settings: settings)

        #expect(outcome.outcomes == [.succeeded(outputs: [], warnings: []), .skipped(.changedSinceScan)])
        #expect(try listing(root) == ["keep.txt"])
        #expect(outcome.record == nil)
    }

    @Test func emptyFoldersRecurseAndHonorTheDSStoreRule() async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(
            [
                "A/B/": "", "C/.DS_Store": "x", "D/file.txt": "x", "D/E/": "", "D/G/.hidden": "x",
                ".git/refs/": "", "H/.git/": "", "Bundle.app/Contents/": "",
            ], in: root)
        var settings = Settings()

        let found = try EmptyFolderScanner.folders(in: [root], settings: settings.folder) { _ in }
        #expect(found.map(\.lastPathComponent) == ["A", "C", "E"])
        settings.folder.emptyIgnoresDSStore = false
        #expect(try EmptyFolderScanner.folders(in: [root], settings: settings.folder) { _ in }.count == 2)

        try makeTree(["C/late.txt": "x"], in: root)
        let confirmed = found + [folderURL(root, "A/B")]
        let outcome = try await runOperation(
            .folderRemoveEmpty, .folder(.removeEmpty(confirmed, permanently: false)), inputs: [root])

        #expect(outcome.outcomes.count == 3)
        #expect(outcome.outcomes.filter { $0 == .skipped(.changedSinceScan) }.count == 1)
        #expect(try listing(root) == [".git", "Bundle.app", "C", "D", "H"])
        #expect(try listing(root.appending(path: "D")) == ["G", "file.txt"])
    }

    @Test func treeTextIsExactAndSortedLikeFinder() async throws {
        let root = folderURL(try TestVolume.makeFolder(), "プロジェクト")
        try makeTree(
            [
                "file10.txt": "", "file2.txt": "", "写真/b.png": "", "写真/a.png": "", "Docs/メモ.md": "",
                "Docs/z/": "", "node_modules/x.js": "", ".hidden": "", "Zeta.txt": "", "App.app/Contents/x": "",
            ], in: root)
        let expected = """
            プロジェクト
            ├── Docs
            │   ├── z
            │   └── メモ.md
            ├── 写真
            │   ├── a.png
            │   └── b.png
            ├── App.app
            ├── file2.txt
            ├── file10.txt
            └── Zeta.txt
            """

        #expect(try FolderTree.text(of: root, excluding: Set(FolderSettings.defaultExcludedNames)) == expected)

        let copied = try await runOperation(.folderTree, .folder(.tree(.copy)), inputs: [root])
        #expect(copied.clipboardText == expected)
        let saved = try await runOperation(.folderTree, .folder(.tree(.md)), inputs: [root])
        guard case .succeeded(let outputs, _) = try #require(saved.outcomes.first), let output = outputs.first else {
            Issue.record("expected a Markdown file")
            return
        }
        #expect(output.lastPathComponent == "プロジェクト tree.md")
        #expect(try String(contentsOf: output, encoding: .utf8) == "```text\n\(expected)\n```\n")
    }

    @Test(arguments: [OperationID.folderRename, .folderAIRename])
    func renamePreviewMatchesTheAppliedNames(operation: OperationID) async throws {
        let root = folderURL(try TestVolume.makeFolder(), "Photos")
        try makeTree(["a.txt": "1", "ax.txt": "2", "IMG_2.jpg": "3", "IMG_10.jpg": "4", ".hidden": "5"], in: root)
        let rules = RenameRules(
            prefix: "Trip-", find: "x", replacement: "", numbering: .init(start: 1, step: 2, digits: 3))

        let preview = try rules.plans(for: RenameRules.targets(for: [root]))
        #expect(
            preview.map(\.newName) == [
                "Trip-a 001.txt", "Trip-a 003.txt", "Trip-IMG_2 005.jpg", "Trip-IMG_10 007.jpg",
            ])

        let collide = RenameRules(find: "x", replacement: "")
        let collisionPreview = try collide.plans(for: RenameRules.targets(for: [root]))
        #expect(collisionPreview.map(\.newName) == ["a.txt", "a (2).txt", "IMG_2.jpg", "IMG_10.jpg"])

        let outcome = try await runOperation(operation, .rename(collisionPreview), inputs: [root])

        #expect(outcome.outcomes == [.succeeded(outputs: [root.appending(path: "a (2).txt")], warnings: [])])
        #expect(try listing(root) == [".hidden", "IMG_10.jpg", "IMG_2.jpg", "a (2).txt", "a.txt"])
        #expect(try String(contentsOf: root.appending(path: "a (2).txt"), encoding: .utf8) == "2")
    }

    @Test(arguments: [OperationID.folderRename, .folderAIRename])
    func unchangedRenamePlansProduceNoOutcomes(operation: OperationID) async throws {
        let root = folderURL(try TestVolume.makeFolder(), "Unchanged")
        try makeTree(["a.txt": "original"], in: root)
        let original = root.appending(path: "a.txt")
        let plans = [RenamePlan(url: original, newName: "a.txt")]

        let outcome = try await runOperation(operation, .rename(plans), inputs: [root])

        #expect(outcome.outcomes.isEmpty)
        #expect(outcome.record == nil)
        #expect(try listing(root) == ["a.txt"])
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }

    @Test func confirmedRenameKeepsExcludedNumberingAndTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseRename-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try makeTree(["a.txt": "excluded", "b.txt": "confirmed"], in: root)
        var settings = Settings()
        settings.folder.renameExclusions.files = "a.txt"
        let rules = RenameRules(numbering: .init(start: 1, step: 1, digits: 1))
        let targets = try RenameRules.targets(for: [root], settings: settings.folder)
        let plans = try rules.plans(for: targets)
        #expect(targets.map(\.lastPathComponent) == ["b.txt"])
        #expect(plans.map(\.newName) == ["b 1.txt"])

        settings.folder.renameExclusions.files = "b.txt"
        try makeTree(["c.txt": "arrived later"], in: root)
        let outcome = try await runOperation(.folderRename, .rename(plans), inputs: targets, settings: settings)

        #expect(outcome.outcomes == [.succeeded(outputs: [root.appending(path: "b 1.txt")], warnings: [])])
        #expect(try listing(root) == ["a.txt", "b 1.txt", "c.txt"])
        #expect(try String(contentsOf: root.appending(path: "b 1.txt"), encoding: .utf8) == "confirmed")
        #expect(try String(contentsOf: root.appending(path: "a.txt"), encoding: .utf8) == "excluded")
    }

    @Test func confirmedRenameRefusesAnOccupiedDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseRename-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try makeTree(["note.txt": "original"], in: root)
        let original = root.appending(path: "note.txt")
        let plans = try RenameRules(prefix: "Trip-").plans(for: [original])
        #expect(plans.map(\.newName) == ["Trip-note.txt"])
        try makeTree(["Trip-note.txt": "arrived later"], in: root)

        let outcome = try await runOperation(.folderRename, .rename(plans), inputs: [original])

        let occupiedError = EngineError.commitFailed("\(NSCocoaErrorDomain) \(CocoaError.fileWriteFileExists.rawValue)")
        #expect(outcome.outcomes == [.failed(occupiedError)])
        #expect(outcome.record == nil)
        #expect(try listing(root) == ["Trip-note.txt", "note.txt"])
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOf: root.appending(path: "Trip-note.txt"), encoding: .utf8) == "arrived later")
    }

    @Test func renameDatesComeFromCreationOrEXIF() throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["note.txt": "x"], in: root)
        let note = root.appending(path: "note.txt")
        var components = DateComponents(year: 2021, month: 3, day: 4, hour: 12)
        components.timeZone = .current
        let created = try #require(Calendar(identifier: .gregorian).date(from: components))
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: note.path)

        let photo = root.appending(path: "photo.jpg")
        let destination = try #require(
            CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil))
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let exif = [kCGImagePropertyExifDateTimeOriginal: "2019:07:08 10:00:00"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let plans = try RenameRules(date: .exif).plans(for: [note, photo])

        #expect(plans.map(\.newName) == ["2021-03-04 note.txt", "2019-07-08 photo.jpg"])
    }

    @Test func analysisSummarizesAndExportsMarkdown() async throws {
        let root = folderURL(try TestVolume.makeFolder(), "Data")
        try makeTree(
            [
                "big.bin": String(repeating: "x", count: 300), "a/one.txt": "dup", "b/two.txt": "dup", "c/": "",
                "x|y.md": "m",
            ],
            in: root)

        let analysis = try FolderAnalysis.scan(root, settings: FolderSettings()) { _ in }

        #expect(analysis.totalBytes == 307)
        #expect(analysis.fileCount == 4)
        #expect(analysis.largestFiles.first?.url.lastPathComponent == "big.bin")
        #expect(analysis.sizeByType.map(\.pathExtension) == ["bin", "txt", "md"])
        #expect(analysis.duplicateGroups.count == 1)
        #expect(analysis.emptyFolders.map(\.lastPathComponent) == ["c"])
        #expect(analysis.markdown.contains("| x\\|y.md |"))

        let outcome = try await runOperation(.folderAnalyze, .folder(.exportAnalysis(analysis)), inputs: [root])
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first), let output = outputs.first else {
            Issue.record("expected a Markdown export")
            return
        }
        #expect(output.lastPathComponent == "Data analysis.md")
        #expect(try String(contentsOf: output, encoding: .utf8) == analysis.markdown)
    }
}
