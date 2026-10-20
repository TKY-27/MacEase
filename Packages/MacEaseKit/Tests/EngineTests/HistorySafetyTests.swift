import Foundation
import MenuCatalog
import Testing

@testable import Engine

struct HistorySafetyTests {
    @Test func derivedDirectoryUndoSkipsEditedChildWithUnchangedRootDate() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let child = output.appending(path: "child.txt")
        try Data("old".utf8).write(to: child)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: output.path)
        let childDate = try FileStamp(of: child).modified
        let stamp = try FileStamp(of: output)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([.derived(output: output.path, stamp: stamp)], batch: id, operation: .folderRename)

        try Data("new".utf8).write(to: child)
        try FileManager.default.setAttributes(
            [.modificationDate: childDate.addingTimeInterval(2)], ofItemAtPath: child.path)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp.modified], ofItemAtPath: output.path)

        #expect(try FileStamp(of: output).modified == stamp.modified)
        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(try String(contentsOf: child, encoding: .utf8) == "new")
    }

    @Test(arguments: ["added", "removed", "retyped"])
    func derivedDirectoryUndoSkipsChangedDescendants(change: String) async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let child = output.appending(path: "child.txt")
        try Data("old".utf8).write(to: child)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: output.path)
        let stamp = try FileStamp(of: output)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([.derived(output: output.path, stamp: stamp)], batch: id, operation: .folderRename)

        switch change {
        case "added":
            try Data("added".utf8).write(to: output.appending(path: "extra.txt"))
        case "removed":
            try FileManager.default.removeItem(at: child)
        case "retyped":
            try FileManager.default.removeItem(at: child)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        default:
            Issue.record("unknown change")
            return
        }
        try FileManager.default.setAttributes(
            [.modificationDate: stamp.modified], ofItemAtPath: output.path)

        #expect(try FileStamp(of: output).modified == stamp.modified)
        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func directoryStampDoesNotFollowSymbolicLinks() throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        let target = folder.appending(path: "target")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: output.appending(path: "link"), withDestinationURL: target)
        let stamp = try FileStamp(of: output)

        try Data("outside".utf8).write(to: target.appending(path: "new.txt"))

        #expect(try FileStamp(of: output) == stamp)
    }

    @Test func renamedFileUndoSkipsEditedDestination() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "before.txt")
        let destination = folder.appending(path: "after.txt")
        try Data("old".utf8).write(to: destination)
        let stamp = try FileStamp(of: destination, includingIdentity: true)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record(
            [.renamed(from: original.path, to: destination.path, stamp: stamp)],
            batch: id, operation: .folderRename)

        try Data("edited".utf8).write(to: destination)

        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: destination.path)])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "edited")
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func renamedFileUndoSkipsRecreatedDestinationWithMatchingSizeAndDate() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "before.txt")
        let destination = folder.appending(path: "after.txt")
        let replacement = folder.appending(path: "replacement.txt")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: destination.path)
        let stamp = try FileStamp(of: destination, includingIdentity: true)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record(
            [.renamed(from: original.path, to: destination.path, stamp: stamp)],
            batch: id, operation: .folderRename)

        try Data("new".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        let current = try FileStamp(of: destination)
        #expect(current.size == stamp.size)
        #expect(current.modified == stamp.modified)

        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: destination.path)])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func legacyHistoryLoadsButUnsafeUndoSkips() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        let original = folder.appending(path: "before.txt")
        let destination = folder.appending(path: "after.txt")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: output.appending(path: "child.txt"))
        try Data("keep".utf8).write(to: destination)
        let batch = BatchRecord(
            id: UUID(), operation: .folderRename, date: Date(),
            items: [
                .derived(output: output.path, stamp: try FileStamp(of: output)),
                .renamed(from: original.path, to: destination.path),
            ], undone: false)
        var batchJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        var items = try #require(batchJSON["items"] as? [[String: Any]])
        var derived = try #require(items[0]["derived"] as? [String: Any])
        var stamp = try #require(derived["stamp"] as? [String: Any])
        stamp.removeValue(forKey: "descendants")
        derived["stamp"] = stamp
        items[0]["derived"] = derived
        var renamed = try #require(items[1]["renamed"] as? [String: Any])
        renamed.removeValue(forKey: "stamp")
        items[1]["renamed"] = renamed
        batchJSON["items"] = items
        let support = folder.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["version": 1, "batches": [batchJSON]])
            .write(to: support.appending(path: "history.json"))

        let store = HistoryStore(supportDirectory: support)
        #expect(await store.records.count == 1)
        #expect(await store.setAsideFile == nil)
        #expect(
            try await store.undo(batch.id) == [
                .skipped(.undoOutputChanged, path: destination.path),
                .skipped(.undoOutputChanged, path: output.path),
            ])
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: output.appending(path: "child.txt").path))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}
