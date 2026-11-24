import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct MoveScopeTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseScope-\(UUID().uuidString.prefix(8))")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test(arguments: [false, true])
    func legacyDerivedPublicationCopiesWhenStagingIsOnAnotherVolume(readingSource: Bool) async throws {
        let root = try workspace()
        let destination = try TestVolume.makeFolder()
        let source = destination.appending(path: "source.txt")
        try Data("source".utf8).write(to: source)
        let staged = root.appending(path: "staged.txt")
        try Data("converted".utf8).write(to: staged)
        let output = try await FileCommitter().derive(
            StagedFile(url: staged, name: "converted.txt", check: .text(.utf8)), nextTo: source,
            expectedStamp: readingSource ? try FileStamp(of: source) : nil)
        #expect(try Data(contentsOf: output.output) == Data("converted".utf8))
        #expect(try Data(contentsOf: source) == Data("source".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(await FileCommitter().undo(.derived(output: output.output.path, stamp: output.stamp)) == .restored)
    }

    @Test func differentNameReplacePreservesCrossVolumeStagingBehavior() async throws {
        let root = try workspace()
        let destination = try TestVolume.makeFolder()
        let source = destination.appending(path: "original.txt")
        try Data("original bytes".utf8).write(to: source)
        let staged = root.appending(path: "staged.txt")
        try Data("converted bytes".utf8).write(to: staged)
        let replacement = try await FileCommitter().replace(
            original: source,
            with: StagedFile(url: staged, name: "converted.txt", check: .text(.utf8)),
            cloneDirectory: root, expectedStamp: FileStamp(of: source))
        let trashed = try #require(replacement.trashed)
        #expect(try Data(contentsOf: replacement.output) == Data("converted bytes".utf8))
        let undo = await FileCommitter().undo(
            .replaced(
                original: source.path, trashed: trashed.url.path,
                output: replacement.output.path, stamp: replacement.stamp, trashStamp: trashed.stamp))
        #expect(undo == .restored)
        #expect(try Data(contentsOf: source) == Data("original bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: replacement.output.path))
    }

    @Test func crossVolumeCopyPreservesSparseAllocation() async throws {
        let root = try workspace()
        let destination = try TestVolume.makeFolder()
        let source = root.appending(path: "sparse.bin")
        let logicalSize = 32 * 1024 * 1024
        let descriptor = open(source.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        try #require(ftruncate(descriptor, off_t(logicalSize)) == 0)
        let marker = Data("sparse marker".utf8)
        try #require(marker.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == marker.count)
        var original = stat()
        try #require(lstat(source.path, &original) == 0)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .filesMove, options: .move(MovePlan(items: [try MoveItem.capture(source)], destination: destination)),
            inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let copy = destination.appending(path: "sparse.bin")
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [copy], warnings: [.copiedAcrossVolumes(original: source, destination: copy)])
            ])
        var copied = stat()
        try #require(lstat(copy.path, &copied) == 0)
        #expect(copied.st_size == logicalSize)
        #expect(copied.st_blocks <= original.st_blocks)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
        #expect(try await engine.undo(outcome.batchID) == [.restored])
    }

    @Test(arguments: [false, true], ["fifo", "socket"])
    func specialFilesAreRefusedWithoutOpening(crossVolume: Bool, kind: String) async throws {
        let root = try workspace()
        let source = root.appending(path: "special")
        let destination = crossVolume ? try TestVolume.makeFolder() : root.appending(path: "destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let socketDescriptor: Int32
        if kind == "fifo" {
            try #require(mkfifo(source.path, S_IRUSR | S_IWUSR) == 0)
            socketDescriptor = -1
        } else {
            socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(socketDescriptor >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = source.path.utf8CString
            try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
        }
        defer { if socketDescriptor >= 0 { Darwin.close(socketDescriptor) } }
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .filesMove, options: .move(MovePlan(items: [try MoveItem.capture(source)], destination: destination)),
            inputs: [source])
        let started = ContinuousClock.now
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        #expect(started.duration(to: .now) < .seconds(30))
        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(outcome.record == nil)
        var original = stat()
        #expect(lstat(source.path, &original) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
