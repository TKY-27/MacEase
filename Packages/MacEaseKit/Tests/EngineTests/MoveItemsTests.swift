import Darwin
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct MoveItemsTests {
    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "MacEaseMove-\(UUID().uuidString)", directoryHint: .isDirectory)
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeEngine(in folder: URL) throws -> JobEngine {
        try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 2)
    }

    private func runMove(_ items: [MoveItem], to destination: URL, engine: JobEngine) async -> BatchOutcome {
        let settings = Settings()
        let request = OperationRequest(
            op: .filesMove, options: .move(MovePlan(items: items, destination: destination)), inputs: items.map(\.url))
        let batch = OperationPlanner.batch(for: request, settings: settings)
        return await engine.run(batch, settings: settings) { _ in }
    }

    private func entryStat(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata
    }

    @Test func sameVolumeMovesRenameFilesAndFoldersPreservingInodesAndUndoRestores() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destDir = workspace.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let file = sourceDir.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)
        let subfolder = sourceDir.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let nested = subfolder.appending(path: "readme.md")
        try Data("# Readme".utf8).write(to: nested)

        let fileInode = try entryStat(file).st_ino
        let folderInode = try entryStat(subfolder).st_ino
        let cutItems = try [MoveItem.capture(file), MoveItem.capture(subfolder)]
        let engine = try makeEngine(in: workspace)

        let outcome = await runMove(cutItems, to: destDir, engine: engine)

        let movedFile = destDir.appending(path: "note.txt")
        let movedFolder = destDir.appending(path: "project")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [movedFile], warnings: []),
                .succeeded(outputs: [movedFolder], warnings: []),
            ])
        #expect(try entryStat(movedFile).st_ino == fileInode)
        #expect(try entryStat(movedFolder).st_ino == folderInode)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: subfolder.path))
        #expect(try String(contentsOf: movedFolder.appending(path: "readme.md"), encoding: .utf8) == "# Readme")

        let record = try #require(outcome.record)
        #expect(record.operation == .filesMove)
        #expect(record.items.count == 2)

        let reopened = try makeEngine(in: workspace)
        #expect(try await reopened.undo(record.id) == [.restored, .restored])
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
        #expect(try String(contentsOf: nested, encoding: .utf8) == "# Readme")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path).isEmpty)
    }

    @Test func collisionsUseNumberedNamingAndUndoRestoresOriginalName() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destDir = workspace.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let sourceFile = sourceDir.appending(path: "report.txt")
        let existing = destDir.appending(path: "report.txt")
        try Data("from source".utf8).write(to: sourceFile)
        try Data("keep existing".utf8).write(to: existing)

        let engine = try makeEngine(in: workspace)
        let outcome = await runMove([try MoveItem.capture(sourceFile)], to: destDir, engine: engine)

        let numbered = destDir.appending(path: "report (2).txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [numbered], warnings: [])])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep existing")
        #expect(try String(contentsOf: numbered, encoding: .utf8) == "from source")
        #expect(!FileManager.default.fileExists(atPath: sourceFile.path))

        let record = try #require(outcome.record)
        #expect(try await engine.undo(record.id) == [.restored])
        #expect(try String(contentsOf: sourceFile, encoding: .utf8) == "from source")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep existing")
        #expect(!FileManager.default.fileExists(atPath: numbered.path))
    }

    @Test func refusesFolderIntoItselfOrDescendantsAndTreatsSameParentAsNoOp() async throws {
        let workspace = try TestVolume.makeFolder()
        let parent = workspace.appending(path: "parent", directoryHint: .isDirectory)
        let child = parent.appending(path: "child", directoryHint: .isDirectory)
        let grandchild = child.appending(path: "grandchild", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
        let sibling = parent.appending(path: "sibling.txt")
        try Data("stay".utf8).write(to: sibling)
        let engine = try makeEngine(in: workspace)

        let selfOutcome = await runMove([try MoveItem.capture(parent)], to: parent, engine: engine)
        if case .failed(.invalidInput(.malformed)) = selfOutcome.outcomes.first {
        } else {
            Issue.record("Expected failure moving folder into itself")
        }
        #expect(selfOutcome.record == nil)

        let descendantOutcome = await runMove([try MoveItem.capture(parent)], to: grandchild, engine: engine)
        if case .failed(.invalidInput(.malformed)) = descendantOutcome.outcomes.first {
        } else {
            Issue.record("Expected failure moving folder into descendant")
        }
        #expect(descendantOutcome.record == nil)

        let noOpOutcome = await runMove(
            [try MoveItem.capture(sibling), try MoveItem.capture(child)], to: parent, engine: engine)
        #expect(noOpOutcome.outcomes == [.skipped(.alreadyDone), .skipped(.alreadyDone)])
        #expect(noOpOutcome.record == nil)
        #expect(try String(contentsOf: sibling, encoding: .utf8) == "stay")
        #expect(FileManager.default.fileExists(atPath: grandchild.path))
    }

    @Test func skipsItemsChangedReplacedOrDeletedSinceCut() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destDir = workspace.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let edited = sourceDir.appending(path: "edited.txt")
        let replaced = sourceDir.appending(path: "replaced.txt")
        let deleted = sourceDir.appending(path: "deleted.txt")
        let folder = sourceDir.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("old".utf8).write(to: edited)
        try Data("abc".utf8).write(to: replaced)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: replaced.path)
        try Data("gone".utf8).write(to: deleted)
        try Data("v1".utf8).write(to: folder.appending(path: "child.txt"))

        let cutItems = try [
            MoveItem.capture(edited), MoveItem.capture(replaced),
            MoveItem.capture(deleted), MoveItem.capture(folder),
        ]

        try Data("modified".utf8).write(to: edited)
        let tempReplacement = sourceDir.appending(path: "temp.txt")
        try Data("xyz".utf8).write(to: tempReplacement)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: tempReplacement.path)
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.moveItem(at: tempReplacement, to: replaced)
        try FileManager.default.removeItem(at: deleted)
        try Data("added".utf8).write(to: folder.appending(path: "extra.txt"))

        let engine = try makeEngine(in: workspace)
        let outcome = await runMove(cutItems, to: destDir, engine: engine)

        #expect(outcome.outcomes == Array(repeating: .skipped(.changedSinceScan), count: 4))
        #expect(outcome.record == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path).isEmpty)
        #expect(try String(contentsOf: edited, encoding: .utf8) == "modified")
        #expect(try String(contentsOf: replaced, encoding: .utf8) == "xyz")
    }

    @Test func symlinksMoveAsLinksNeverFollowedIncludingDanglingAndTargetDirectoryLinks() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destDir = workspace.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let targetFile = workspace.appending(path: "real.txt")
        try Data("real content".utf8).write(to: targetFile)
        let fileLink = sourceDir.appending(path: "file-link")
        let dirLink = sourceDir.appending(path: "dir-link")
        let danglingLink = sourceDir.appending(path: "dangling-link")
        try FileManager.default.createSymbolicLink(atPath: fileLink.path, withDestinationPath: targetFile.path)
        try FileManager.default.createSymbolicLink(atPath: dirLink.path, withDestinationPath: destDir.path)
        try FileManager.default.createSymbolicLink(atPath: danglingLink.path, withDestinationPath: "/nonexistent/item")

        let cutItems = try [MoveItem.capture(fileLink), MoveItem.capture(dirLink), MoveItem.capture(danglingLink)]
        let engine = try makeEngine(in: workspace)
        let outcome = await runMove(cutItems, to: destDir, engine: engine)

        let movedFileLink = destDir.appending(path: "file-link")
        let movedDirLink = destDir.appending(path: "dir-link")
        let movedDangling = destDir.appending(path: "dangling-link")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [movedFileLink], warnings: []),
                .succeeded(outputs: [movedDirLink], warnings: []),
                .succeeded(outputs: [movedDangling], warnings: []),
            ])
        for (url, expectedTarget) in [
            (movedFileLink, targetFile.path), (movedDirLink, destDir.path), (movedDangling, "/nonexistent/item"),
        ] {
            #expect(try entryStat(url).st_mode & S_IFMT == S_IFLNK)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == expectedTarget)
        }
        #expect(try String(contentsOf: targetFile, encoding: .utf8) == "real content")

        let record = try #require(outcome.record)
        #expect(try await engine.undo(record.id) == [.restored, .restored, .restored])
        #expect(try entryStat(danglingLink).st_mode & S_IFMT == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path) == "/nonexistent/item")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path).isEmpty)
    }

    @Test func partialFailureRecordsCompletedMovesAndLeavesOthersUntouched() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destDir = workspace.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let goodFile = sourceDir.appending(path: "good.txt")
        let staleFile = sourceDir.appending(path: "stale.txt")
        let alreadyThere = destDir.appending(path: "already.txt")
        let goodFolder = sourceDir.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: goodFolder, withIntermediateDirectories: true)
        try Data("good".utf8).write(to: goodFile)
        try Data("before".utf8).write(to: staleFile)
        try Data("here".utf8).write(to: alreadyThere)
        try Data("inside".utf8).write(to: goodFolder.appending(path: "a.txt"))

        let cutItems = try [
            MoveItem.capture(goodFile),
            MoveItem.capture(staleFile),
            MoveItem.capture(alreadyThere),
            MoveItem.capture(destDir),
            MoveItem.capture(goodFolder),
        ]
        try Data("changed".utf8).write(to: staleFile)

        let engine = try makeEngine(in: workspace)
        let outcome = await runMove(cutItems, to: destDir, engine: engine)

        #expect(outcome.outcomes.count == 5)
        #expect(outcome.outcomes[0] == .succeeded(outputs: [destDir.appending(path: "good.txt")], warnings: []))
        #expect(outcome.outcomes[1] == .skipped(.changedSinceScan))
        #expect(outcome.outcomes[2] == .skipped(.alreadyDone))
        if case .failed(.invalidInput(.malformed)) = outcome.outcomes[3] {
        } else {
            Issue.record("Expected failure moving destination into itself")
        }
        #expect(outcome.outcomes[4] == .succeeded(outputs: [destDir.appending(path: "folder")], warnings: []))
        #expect(try String(contentsOf: staleFile, encoding: .utf8) == "changed")
        #expect(try String(contentsOf: alreadyThere, encoding: .utf8) == "here")

        let record = try #require(outcome.record)
        #expect(record.items.count == 2)
        #expect(try await engine.undo(record.id) == [.restored, .restored])
        #expect(try String(contentsOf: goodFile, encoding: .utf8) == "good")
        #expect(try String(contentsOf: goodFolder.appending(path: "a.txt"), encoding: .utf8) == "inside")
    }

    @Test func undoSkipsModifiedMovedItemAndOccupiedOriginalIncludingDanglingLink() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destDir = workspace.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let first = sourceDir.appending(path: "first.txt")
        let second = sourceDir.appending(path: "second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let engine = try makeEngine(in: workspace)
        let outcome = await runMove(
            [try MoveItem.capture(first), try MoveItem.capture(second)], to: destDir, engine: engine)
        let record = try #require(outcome.record)

        try Data("edited after move".utf8).write(to: destDir.appending(path: "first.txt"))
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "/missing/occupier")

        let undoOutcomes = try await engine.undo(record.id)
        #expect(undoOutcomes.count == 2)
        #expect(undoOutcomes.contains(.skipped(.undoOutputChanged, path: destDir.appending(path: "first.txt").path)))
        #expect(undoOutcomes.contains(.skipped(.undoOriginalOccupied, path: second.path)))
        #expect(try String(contentsOf: destDir.appending(path: "first.txt"), encoding: .utf8) == "edited after move")
        #expect(try String(contentsOf: destDir.appending(path: "second.txt"), encoding: .utf8) == "two")
    }

    @Test func crossVolumeMovesVerifyCopyBeforeRemovingSourceAndUndoAcrossVolumes() async throws {
        let bootWorkspace = try makeTempFolder()
        let diskWorkspace = try TestVolume.makeFolder()
        let sourceDir = bootWorkspace.appending(path: "src", directoryHint: .isDirectory)
        let destDir = diskWorkspace.appending(path: "dst", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        #expect(try entryStat(sourceDir).st_dev != entryStat(destDir).st_dev)

        let file = sourceDir.appending(path: "payload.bin")
        let payload = Data((0..<8192).map { UInt8($0 & 0xFF) })
        try payload.write(to: file)

        let folder = sourceDir.appending(path: "bundle", directoryHint: .isDirectory)
        let nestedDir = folder.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nestedDir.appending(path: "doc.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appending(path: "rel-link").path, withDestinationPath: "sub/doc.txt")
        try FileManager.default.createSymbolicLink(
            atPath: folder.appending(path: "broken-link").path, withDestinationPath: "/missing/cross-target")

        let topLink = sourceDir.appending(path: "top-dangling")
        try FileManager.default.createSymbolicLink(atPath: topLink.path, withDestinationPath: "/missing/top")

        let existingCollision = destDir.appending(path: "payload.bin")
        try Data("preexisting".utf8).write(to: existingCollision)

        let cutItems = try [MoveItem.capture(file), MoveItem.capture(folder), MoveItem.capture(topLink)]
        let engine = try makeEngine(in: bootWorkspace)
        let outcome = await runMove(cutItems, to: destDir, engine: engine)

        let movedFile = destDir.appending(path: "payload (2).bin")
        let movedFolder = destDir.appending(path: "bundle")
        let movedLink = destDir.appending(path: "top-dangling")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [movedFile], warnings: []),
                .succeeded(outputs: [movedFolder], warnings: []),
                .succeeded(outputs: [movedLink], warnings: []),
            ])
        #expect(try Data(contentsOf: movedFile) == payload)
        #expect(try Data(contentsOf: existingCollision) == Data("preexisting".utf8))
        #expect(try String(contentsOf: movedFolder.appending(path: "sub/doc.txt"), encoding: .utf8) == "nested")
        #expect(try entryStat(movedFolder.appending(path: "rel-link")).st_mode & S_IFMT == S_IFLNK)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: movedFolder.appending(path: "rel-link").path)
                == "sub/doc.txt")
        #expect(try entryStat(movedFolder.appending(path: "broken-link")).st_mode & S_IFMT == S_IFLNK)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: movedFolder.appending(path: "broken-link").path)
                == "/missing/cross-target")
        #expect(try entryStat(movedLink).st_mode & S_IFMT == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: movedLink.path) == "/missing/top")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sourceDir.path).isEmpty)

        let record = try #require(outcome.record)
        let reopened = try makeEngine(in: bootWorkspace)
        #expect(try await reopened.undo(record.id) == [.restored, .restored, .restored])
        #expect(try Data(contentsOf: file) == payload)
        #expect(try String(contentsOf: nestedDir.appending(path: "doc.txt"), encoding: .utf8) == "nested")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: "broken-link").path)
                == "/missing/cross-target")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: topLink.path) == "/missing/top")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path) == ["payload.bin"])
    }

    @Test func refusesReadOnlyOrNonDirectoryDestinationAndEmptyPlan() async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDir = workspace.appending(path: "source", directoryHint: .isDirectory)
        let readOnlyDest = workspace.appending(path: "readonly", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readOnlyDest, withIntermediateDirectories: true)
        let file = sourceDir.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: file)
        let notAFolder = workspace.appending(path: "file.txt")
        try Data("not folder".utf8).write(to: notAFolder)
        let entry = try MoveItem.capture(file)
        let engine = try makeEngine(in: workspace)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDest.path) }
        let denied = await runMove([entry], to: readOnlyDest, engine: engine)
        #expect(denied.outcomes == [.failed(.permissionDenied(PermissionLocation(path: file.path)))])
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")

        let badDest = await runMove([entry], to: notAFolder, engine: engine)
        if case .failed(.invalidInput(.malformed)) = badDest.outcomes.first {
        } else {
            Issue.record("Expected failure when destination is not a directory")
        }

        let emptyOutcome = await runMove([], to: sourceDir, engine: engine)
        #expect(emptyOutcome.outcomes == [.failed(.invalidInput(.tooFewFiles(minimum: 1)))])
        #expect(!OperationID.menuOrder.contains(.filesMove))
    }
    @Test func lockedDescendantsCannotDestroyMovedOrRestoredFolders() async throws {
        let boot = try makeTempFolder()
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "project")
        let destination = disk.appending(path: "destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data("payload-\(index)".utf8).write(to: source.appending(path: "\(index).txt"))
        }
        let lockedName = "10.txt"
        #expect(chflags(source.appending(path: lockedName).path, UInt32(UF_IMMUTABLE)) == 0)
        let engine = try makeEngine(in: boot)
        let registry = boot.appending(path: "support/staging.json")
        defer {
            let paths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: registry))) ?? []
            for root in [source, destination.appending(path: "project")] + paths.map({ URL(fileURLWithPath: $0) }) {
                if let entries = FileManager.default.enumerator(atPath: root.path) {
                    while let name = entries.nextObject() as? String { _ = chflags(root.appending(path: name).path, 0) }
                }
            }
            engine.staging.removeStale()
        }
        let outcome = await runMove([try MoveItem.capture(source)], to: destination, engine: engine)
        let moved = destination.appending(path: "project")
        #expect(outcome.outcomes == [.succeeded(outputs: [moved], warnings: [])])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        for index in 0..<20 {
            #expect(
                try String(contentsOf: moved.appending(path: "\(index).txt"), encoding: .utf8) == "payload-\(index)")
        }
        let record = try #require(outcome.record)
        #expect(record.items.count == 1)
        let moveStaging = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        #expect(!moveStaging.isEmpty)
        let retiredMove = try #require(
            moveStaging.first {
                FileManager.default.fileExists(atPath: $0 + "/project/" + lockedName)
            })
        #expect(try FileManager.default.contentsOfDirectory(atPath: retiredMove + "/project").count < 20)
        let reopened = try makeEngine(in: boot)
        #expect(try await reopened.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        for index in 0..<20 {
            #expect(
                try String(contentsOf: source.appending(path: "\(index).txt"), encoding: .utf8) == "payload-\(index)")
        }
        let undoStaging = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        #expect(undoStaging.count > moveStaging.count)
        for path in undoStaging where !moveStaging.contains(path) {
            let remaining = try FileManager.default.contentsOfDirectory(atPath: path + "/project")
            #expect(remaining.contains(lockedName))
            #expect(remaining.count < 20)
        }
        let startup = StagingArea(supportDirectory: boot.appending(path: "support"))
        startup.removeStale()
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).count == undoStaging.count)
        for path in undoStaging {
            #expect(chflags(path + "/project/" + lockedName, 0) == 0)
        }
        startup.removeStale()
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
        #expect((await reopened.history.records).first?.undone == true)
    }

    @Test(arguments: [ItemPhase.preparing, .verifying, .saving])
    func cancelledCrossVolumeMoveLeavesOriginalAndNoPublishedOutput(stage: ItemPhase) async throws {
        let boot = try makeTempFolder()
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "keep.txt")
        try Data("keep original".utf8).write(to: source)
        let entry = try MoveItem.capture(source)
        try FileManager.default.createDirectory(at: boot.appending(path: "support"), withIntermediateDirectories: true)
        let staging = StagingArea(supportDirectory: boot.appending(path: "support"))
        let task = Task {
            try FileCommitter().move(entry, to: disk, staging: staging) { phase in
                if phase == stage { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: source, encoding: .utf8) == "keep original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.path).isEmpty)
    }

    @Test func verificationFailureKeepsSourceAndNeverPublishes() async throws {
        let boot = try makeTempFolder()
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "keep.txt")
        try Data("keep original".utf8).write(to: source)
        let entry = try MoveItem.capture(source)
        let support = boot.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let staging = StagingArea(supportDirectory: support)
        let failure = Mutex<(any Error)?>(nil)
        #expect(throws: EngineError.self) {
            try FileCommitter().move(entry, to: disk, staging: staging) { phase in
                guard phase == .verifying else { return }
                do {
                    let registered = try JSONDecoder().decode(
                        [String].self, from: Data(contentsOf: support.appending(path: "staging.json")))
                    let copied = try #require(
                        registered.map { URL(fileURLWithPath: $0).appending(path: "keep.txt") }
                            .first { FileManager.default.fileExists(atPath: $0.path) })
                    try Data("corrupt staged copy".utf8).write(to: copied)
                } catch { failure.withLock { $0 = error } }
            }
        }
        #expect(failure.withLock { $0 == nil })
        #expect(try String(contentsOf: source, encoding: .utf8) == "keep original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.path).isEmpty)
    }

    @Test func metadataChangedAfterCopyIsRefusedBeforePublication() throws {
        let boot = try makeTempFolder()
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "keep.txt")
        try Data("keep original".utf8).write(to: source)
        let entry = try MoveItem.capture(source)
        try FileManager.default.createDirectory(at: boot.appending(path: "support"), withIntermediateDirectories: true)
        let staging = StagingArea(supportDirectory: boot.appending(path: "support"))
        #expect(throws: EngineError.self) {
            try FileCommitter().move(entry, to: disk, staging: staging) { phase in
                if phase == .saving { #expect(chmod(source.path, 0o600) == 0) }
            }
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "keep original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.path).isEmpty)
    }

    @Test func symlinkDestinationIntoDescendantIsRefused() async throws {
        let workspace = try TestVolume.makeFolder()
        let source = workspace.appending(path: "source")
        let child = source.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = workspace.appending(path: "alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: source.path)
        let engine = try makeEngine(in: workspace)
        let outcome = await runMove([try MoveItem.capture(source)], to: alias.appending(path: "child"), engine: engine)
        if case .failed(.invalidInput(.malformed)) = outcome.outcomes.first {
        } else {
            Issue.record("Expected descendant refusal")
        }
        #expect(FileManager.default.fileExists(atPath: child.path))
        #expect(outcome.record == nil)
    }

    @Test(arguments: ["REPORT.txt", "cafe\u{301}.txt"])
    func filesystemNameCollisionsPreserveBothFiles(existingName: String) async throws {
        let workspace = try TestVolume.makeFolder()
        let sourceDirectory = workspace.appending(path: "source")
        let destination = workspace.appending(path: "destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = existingName == "REPORT.txt" ? "report.txt" : "café.txt"
        let source = sourceDirectory.appending(path: name)
        let existing = destination.appending(path: existingName)
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)
        let engine = try makeEngine(in: workspace)
        let outcome = await runMove([try MoveItem.capture(source)], to: destination, engine: engine)
        #expect(outcome.record?.items.count == 1)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2)
        #expect(try await engine.undo(outcome.batchID) == [.restored])
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
    }

    @Test func abandonedCopyStagingIsRecoveredWithoutTouchingOriginal() throws {
        let boot = try makeTempFolder()
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "original.txt")
        try Data("complete original".utf8).write(to: source)
        let engine = try makeEngine(in: boot)
        let directory = try engine.staging.makeDirectory(for: disk)
        let partial = directory.appending(path: "original.txt")
        try Data("partial".utf8).write(to: partial)
        let registry = boot.appending(path: "support/staging.json")
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)) == [directory.path])
        engine.staging.removeStale()
        #expect(FileManager.default.fileExists(atPath: partial.path))
        StagingArea(supportDirectory: boot.appending(path: "support")).removeStale()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "complete original")
    }

    @Test func destinationReplacedBySymlinkBeforePublicationIsRefused() throws {
        let boot = try makeTempFolder()
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "original.txt")
        try Data("original".utf8).write(to: source)
        let destination = disk.appending(path: "destination")
        let displaced = disk.appending(path: "displaced")
        let redirected = disk.appending(path: "redirected")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        let engine = try makeEngine(in: boot)
        let entry = try MoveItem.capture(source)
        let replacementFailure = Mutex<(any Error)?>(nil)
        #expect(throws: FileCommitter.Failure.changedSinceScan) {
            try FileCommitter().move(entry, to: destination, staging: engine.staging) { phase in
                guard phase == .saving else { return }
                do {
                    try FileManager.default.moveItem(at: destination, to: displaced)
                    try FileManager.default.createSymbolicLink(
                        atPath: destination.path, withDestinationPath: redirected.path)
                } catch { replacementFailure.withLock { $0 = error } }
            }
        }
        #expect(replacementFailure.withLock { $0 == nil })
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
    }

    @Test func firmlinkDescendantIsRefusedByFilesystemIdentity() async throws {
        let workspace = try makeTempFolder().resolvingSymlinksInPath()
        let source = workspace.appending(path: "source")
        let child = source.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let resolved = try #require(realpath(child.path, nil))
        defer { free(resolved) }
        let aliasedChild = URL(fileURLWithPath: "/System/Volumes/Data" + String(cString: resolved))
        #expect(try entryStat(child).st_ino == entryStat(aliasedChild).st_ino)
        let engine = try makeEngine(in: workspace)
        let outcome = await runMove([try MoveItem.capture(source)], to: aliasedChild, engine: engine)
        if case .failed(.invalidInput(.malformed)) = outcome.outcomes.first {
        } else {
            Issue.record("Expected firmlink descendant refusal")
        }
        #expect(FileManager.default.fileExists(atPath: child.path))
        #expect(outcome.record == nil)
    }

}
