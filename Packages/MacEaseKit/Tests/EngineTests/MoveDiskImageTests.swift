import Darwin
import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized, .enabled("Requires disk-image creation", { try TestDiskImage.probe() }))
struct MoveDiskImageTests {
    @Test func exFATCopyVerifiesBytesAndUndoKeepsOriginal() async throws {
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
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [output], warnings: [.copiedAcrossVolumes(original: source, destination: output)])
            ])
        #expect(try Data(contentsOf: output) == bytes)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await engine.undo(outcome.batchID) == [.restored])
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
        try presenter.register()
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let engine = try JobEngine(supportDirectory: sourceDirectory.appending(path: "support"), concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [entry], destination: volume.mount)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { progress in
            if progress.itemPhases.contains(.saving) { presenter.beginPublication() }
        }
        let output = volume.mount.appending(path: "note (2).txt")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [output], warnings: [.copiedAcrossVolumes(original: source, destination: output)])
            ])
        #expect(try Data(contentsOf: output) == Data("original".utf8))
        #expect(try Data(contentsOf: collision) == Data("concurrent".utf8))
        NSFileCoordinator.removeFilePresenter(presenter)
        #expect(try await engine.undo(outcome.batchID) == [.restored])
        #expect(try Data(contentsOf: source) == Data("original".utf8))
        #expect(try Data(contentsOf: collision) == Data("concurrent".utf8))
    }

    @Test func readOnlySourceNeedsNoTrashOrWriteAccess() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        try Data("blocks the volume Trash".utf8).write(to: volume.mount.appending(path: ".Trashes"))
        let destination = try TestVolume.makeFolder()
        let source = volume.mount.appending(path: "keep.txt")
        try Data("keep complete".utf8).write(to: source)
        try volume.unmount()
        try volume.attach(readOnly: true)
        let engine = try JobEngine(supportDirectory: destination.appending(path: "support"), concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [entry], destination: destination)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let output = destination.appending(path: "keep.txt")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [output], warnings: [.copiedAcrossVolumes(original: source, destination: output)])
            ])
        #expect(try Data(contentsOf: source) == Data("keep complete".utf8))
        #expect(try Data(contentsOf: output) == Data("keep complete".utf8))
        #expect(try #require(outcome.record).items.count == 1)
        #expect(try await engine.undo(outcome.batchID) == [.restored])
        #expect(try Data(contentsOf: source) == Data("keep complete".utf8))
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"], [false, true])
    func directoryCopiesAndPublicationCollisionsPreserveBothTrees(filesystem: String, collision: Bool) async throws {
        let volume = try TestDiskImage(filesystem: filesystem)
        defer { #expect(throws: Never.self) { try volume.close() } }
        let sourceDirectory = try TestVolume.makeFolder()
        let source = sourceDirectory.appending(path: "project")
        try FileManager.default.createDirectory(
            at: source.appending(path: "nested/empty"), withIntermediateDirectories: true)
        try Data("nested payload".utf8).write(to: source.appending(path: "nested/contents.txt"))
        let occupied = volume.mount.appending(path: "project")
        let presenter = MoveCollisionPresenter(source: source, collision: occupied, directory: true)
        if collision { try presenter.register() }
        defer { if collision { NSFileCoordinator.removeFilePresenter(presenter) } }
        let engine = try JobEngine(supportDirectory: sourceDirectory.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [try MoveItem.capture(source)], destination: volume.mount)), inputs: [source]
        )
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { progress in
            if progress.itemPhases.contains(.saving) { presenter.beginPublication() }
        }
        let output = volume.mount.appending(path: collision ? "project (2)" : "project")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [output], warnings: [.copiedAcrossVolumes(original: source, destination: output)])
            ])
        #expect(try Data(contentsOf: output.appending(path: "nested/contents.txt")) == Data("nested payload".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: output.appending(path: "nested/empty").path).isEmpty)
        #expect(try Data(contentsOf: source.appending(path: "nested/contents.txt")) == Data("nested payload".utf8))
        if collision {
            #expect(try Data(contentsOf: occupied.appending(path: "concurrent.txt")) == Data("concurrent".utf8))
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        #expect(try await engine.undo(outcome.batchID) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        if collision { #expect(FileManager.default.fileExists(atPath: occupied.path)) }
        #expect(try Data(contentsOf: source.appending(path: "nested/contents.txt")) == Data("nested payload".utf8))
    }

    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func symbolicLinkCopiesKeepTheirTargetsOnPortableFilesystems(filesystem: String) async throws {
        let volume = try TestDiskImage(filesystem: filesystem)
        defer { #expect(throws: Never.self) { try volume.close() } }
        let sourceDirectory = try TestVolume.makeFolder()
        let source = sourceDirectory.appending(path: "link")
        let target = "/missing/target"
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: target)
        let engine = try JobEngine(supportDirectory: sourceDirectory.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [try MoveItem.capture(source)], destination: volume.mount)), inputs: [source]
        )
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let output = volume.mount.appending(path: "link")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [output], warnings: [.copiedAcrossVolumes(original: source, destination: output)])
            ])
        var metadata = stat()
        #expect(lstat(output.path, &metadata) == 0)
        #expect(metadata.st_mode & S_IFMT == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.path) == target)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path) == target)
        #expect(try await engine.undo(outcome.batchID) == [.restored])
    }

    @Test func readOnlyPublicationReportsTheDestinationLocation() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        let staged = volume.mount.appending(path: "staged.txt")
        try Data().write(to: staged)
        let destination = volume.mount.appending(path: ".Trashes/output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try volume.unmount()
        try volume.attach(readOnly: true)
        do {
            _ = try await FileCommitter().create(
                [StagedFile(url: staged, name: "Untitled.txt", check: .newFile(.empty))], in: destination)
            Issue.record("Expected read-only destination refusal")
        } catch let failure as FileCommitter.CreationFailure {
            #expect(failure.reason == .permissionDenied(.trash))
            #expect(failure.retained.isEmpty)
        } catch let failure as EngineError {
            #expect(failure == .permissionDenied(.trash))
        }
        #expect(try Data(contentsOf: staged).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func undoWithUnmountedDestinationKeepsOriginalAndSkipsMissingCopy() async throws {
        let volume = try TestDiskImage(filesystem: "ExFAT")
        defer { #expect(throws: Never.self) { try volume.close() } }
        let sourceDirectory = try TestVolume.makeFolder()
        let source = sourceDirectory.appending(path: "original.txt")
        try Data("original content".utf8).write(to: source)
        let engine = try JobEngine(supportDirectory: sourceDirectory.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [try MoveItem.capture(source)], destination: volume.mount)), inputs: [source]
        )
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let output = volume.mount.appending(path: "original.txt")
        try volume.unmount()
        #expect(try await engine.undo(outcome.batchID) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect((await engine.history.records).first?.undone == true)
        #expect(try Data(contentsOf: source) == Data("original content".utf8))
        try volume.attach()
        #expect(try Data(contentsOf: output) == Data("original content".utf8))
    }

}

private final class MoveCollisionPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let collision: URL
    private let directory: Bool
    private let created = Mutex(false)
    private let publishing = Mutex(false)
    private let observedRelinquish = Mutex(false)
    private static let registrationAttempts = 20
    private static let registrationRetryInterval: TimeInterval = 0.02

    init(source: URL, collision: URL, directory: Bool = false) {
        presentedItemURL = source
        self.collision = collision
        self.directory = directory
    }

    /// Blocks until filecoordinationd delivers a relinquish callback.
    func register() throws {
        guard let source = presentedItemURL else { throw POSIXError(.EINVAL) }
        NSFileCoordinator.addFilePresenter(self)
        for _ in 0..<Self.registrationAttempts {
            var coordinationFailure: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: source, options: [], error: &coordinationFailure
            ) { _ in }
            if let coordinationFailure { throw coordinationFailure }
            if observedRelinquish.withLock({ $0 }) { return }
            Thread.sleep(forTimeInterval: Self.registrationRetryInterval)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func beginPublication() { publishing.withLock { $0 = true } }

    func relinquishPresentedItem(toReader reader: @Sendable ((@Sendable () -> Void)?) -> Void) {
        observedRelinquish.withLock { $0 = true }
        createCollision()
        reader(nil)
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        observedRelinquish.withLock { $0 = true }
        createCollision()
        writer(nil)
    }

    private func createCollision() {
        guard publishing.withLock({ $0 }) else { return }
        created.withLock { occupied in
            if !occupied {
                do {
                    if directory {
                        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
                        try Data("concurrent".utf8).write(to: collision.appending(path: "concurrent.txt"))
                    } else {
                        try Data("concurrent".utf8).write(to: collision, options: .withoutOverwriting)
                    }
                } catch {
                    Issue.record(error)
                }
                occupied = true
            }
        }
    }
}
