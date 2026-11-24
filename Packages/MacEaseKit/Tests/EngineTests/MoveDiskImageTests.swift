import Darwin
import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized, .enabled("Requires disk-image creation", { try TestDiskImage.probe() }))
struct MoveDiskImageTests {
    @Test func exFATMoveVerifiesBytesAndUndoRestoresOriginal() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        let sourceDirectory = try TestVolume.makeFolder()
        let source = sourceDirectory.appending(path: "payload.bin")
        let bytes = Data((0..<100_003).map { UInt8($0 & 0xFF) })
        try bytes.write(to: source)
        let engine = try JobEngine(supportDirectory: sourceDirectory.appending(path: "support"), concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [entry], destination: volume.mount)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let output = volume.mount.appending(path: "payload.bin")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try Data(contentsOf: output) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await engine.undo(outcome.batchID) == [.restored, .restored])
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func exclusiveRenameCapabilityIsMeasured(filesystem: String) throws {
        let volume = try TestDiskImage(filesystem: filesystem)
        defer { #expect(throws: Never.self) { try volume.close() } }
        let source = volume.mount.appending(path: "source.txt")
        let destination = volume.mount.appending(path: "destination.txt")
        try Data("source".utf8).write(to: source)
        #expect(renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == -1)
        #expect(errno == ENOTSUP)
        #expect(try Data(contentsOf: source) == Data("source".utf8))
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func existingTextConversionAndNewFileWorkOnExFAT(mode: Settings.OutputMode) async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        let support = try TestVolume.makeFolder()
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let source = volume.mount.appending(path: "report.txt")
        let original = Data("first\r\nsecond\r\n".utf8)
        try original.write(to: source)
        var settings = Settings()
        settings.outputMode = mode
        let request = OperationRequest(op: .textLineEndings, options: .text(.lineEndings(.lf)), inputs: [source])
        let converted = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let expected = mode == .replace ? source : volume.mount.appending(path: "report_lf.txt")
        #expect(converted.outcomes == [.succeeded(outputs: [expected], warnings: [])])
        #expect(try Data(contentsOf: expected) == Data("first\nsecond\n".utf8))
        #expect(try await engine.undo(converted.batchID) == [.restored])
        #expect(try Data(contentsOf: source) == original)
        let create = OperationRequest(
            op: .folderNewFile,
            options: .folder(.newFile(NewFileTemplate(pathExtension: "txt", defaultBaseName: "Untitled"))),
            inputs: [volume.mount])
        let created = await engine.run(OperationPlanner.batch(for: create, settings: settings), settings: settings) {
            _ in
        }
        let newFile = volume.mount.appending(path: "Untitled.txt")
        #expect(created.outcomes == [.succeeded(outputs: [newFile], warnings: [])])
        #expect(try Data(contentsOf: newFile).isEmpty)
        #expect(try await engine.undo(created.batchID) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: newFile.path))
    }

    @Test func exFATPublicationCollisionKeepsBothFiles() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        let sourceDirectory = try TestVolume.makeFolder()
        let source = sourceDirectory.appending(path: "note.txt")
        let collision = volume.mount.appending(path: "note.txt")
        try Data("original".utf8).write(to: source)
        let presenter = MoveCollisionPresenter(source: source, collision: collision)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let engine = try JobEngine(supportDirectory: sourceDirectory.appending(path: "support"), concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [entry], destination: volume.mount)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let output = volume.mount.appending(path: "note (2).txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try Data(contentsOf: output) == Data("original".utf8))
        #expect(try Data(contentsOf: collision) == Data("concurrent".utf8))
        NSFileCoordinator.removeFilePresenter(presenter)
        #expect(try await engine.undo(outcome.batchID) == [.restored, .restored])
        #expect(try Data(contentsOf: source) == Data("original".utf8))
        #expect(try Data(contentsOf: collision) == Data("concurrent".utf8))
    }

    @Test func unavailableTrashKeepsBothCompleteCopiesAndReportsIt() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        try Data("blocks the volume Trash".utf8).write(to: volume.mount.appending(path: ".Trashes"))
        let destination = try TestVolume.makeFolder()
        let source = volume.mount.appending(path: "keep.txt")
        try Data("keep complete".utf8).write(to: source)
        let engine = try JobEngine(supportDirectory: destination.appending(path: "support"), concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [entry], destination: destination)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let output = destination.appending(path: "keep.txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [.originalKept])])
        #expect(try Data(contentsOf: source) == Data("keep complete".utf8))
        #expect(try Data(contentsOf: output) == Data("keep complete".utf8))
        #expect(try #require(outcome.record).items.count == 1)
        #expect(try await engine.undo(outcome.batchID) == [.restored])
        #expect(try Data(contentsOf: source) == Data("keep complete".utf8))
    }

    @Test func undoWithUnmountedDestinationRemainsRetryableAfterRemount() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        let sourceDirectory = try TestVolume.makeFolder()
        let source = sourceDirectory.appending(path: "original.txt")
        try Data("original content".utf8).write(to: source)
        let support = sourceDirectory.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [entry], destination: volume.mount)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        #expect(outcome.outcomes == [.succeeded(outputs: [volume.mount.appending(path: "original.txt")], warnings: [])])
        try volume.unmount()
        #expect(FileManager.default.fileExists(atPath: volume.mount.path))
        let firstAttempt = try await engine.undo(outcome.batchID)
        #expect(firstAttempt.contains { if case .failed = $0 { true } else { false } })
        #expect((await engine.history.records).first?.undone == false)
        let reopened = try JobEngine(supportDirectory: support, concurrency: 1)
        try volume.attach()
        #expect(try await reopened.undo(outcome.batchID) == [.restored])
        #expect(try Data(contentsOf: source) == Data("original content".utf8))
        #expect(!FileManager.default.fileExists(atPath: volume.mount.appending(path: "original.txt").path))
    }
}

private final class MoveCollisionPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let collision: URL
    private let created = Mutex(false)

    init(source: URL, collision: URL) {
        presentedItemURL = source
        self.collision = collision
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        created.withLock { occupied in
            if !occupied {
                do { try Data("concurrent".utf8).write(to: collision, options: .withoutOverwriting) } catch {
                    Issue.record(error)
                }
                occupied = true
            }
        }
        writer(nil)
    }
}
