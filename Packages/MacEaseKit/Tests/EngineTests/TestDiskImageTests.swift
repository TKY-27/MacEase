import Darwin
import Foundation
import Testing

@Suite(.serialized, .enabled("Requires disk-image creation", { try TestDiskImage.probe() }))
struct TestDiskImageTests {
    private func device(of url: URL) throws -> dev_t {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return metadata.st_dev
    }

    @Test func processExitDetachesAndRemovesItsImage() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let volume = try TestDiskImage()
            try Data("owned fixture".utf8).write(to: volume.mount.appending(path: "owned.txt"))
            FileHandle.standardOutput.write(Data(volume.directory.path.utf8))
            exit(EXIT_SUCCESS)
        }
        let path = String(decoding: result.standardOutputContent, as: UTF8.self)
        try #require(!path.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func abruptExitLeavesAnImageForTheNextFamilySweep() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let volume = try TestDiskImage()
            try Data("owned fixture".utf8).write(to: volume.mount.appending(path: "owned.txt"))
            FileHandle.standardOutput.write(Data(volume.directory.path.utf8))
            _exit(EXIT_SUCCESS)
        }
        let path = String(decoding: result.standardOutputContent, as: UTF8.self)
        try #require(!path.isEmpty)
        let root = URL(fileURLWithPath: path)
        let mount = root.appending(path: "mount")
        let hostDevice = try device(of: root)
        #expect(try device(of: mount) != hostDevice)
        let diagnostics = FileManager.default.temporaryDirectory.appending(
            path: "MacEaseImageSweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: diagnostics) } }
        try TestDiskImage.removeStale(using: diagnostics)
        #expect(try device(of: mount) != hostDevice)
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-TestDiskImage.staleAge - 1)], ofItemAtPath: root.path)
        try TestDiskImage.removeStale(using: diagnostics)
        let unmounted = try device(of: mount) == hostDevice
        try #require(unmounted)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "volume.sparseimage").path))
        try FileManager.default.removeItem(at: root)
    }

    @Test func staleSweepPreservesAnOlderImageOwnedByTheCurrentProcess() throws {
        let volume = try TestDiskImage()
        defer { #expect(throws: Never.self) { try volume.close() } }
        let payload = volume.mount.appending(path: "owned.txt")
        try Data("active fixture".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-TestDiskImage.staleAge - 1)], ofItemAtPath: volume.directory.path
        )
        try TestDiskImage.removeStale(using: volume.directory)
        #expect(try Data(contentsOf: payload) == Data("active fixture".utf8))
    }

    @Test func throwingScopeDetachesAndRemovesItsImage() throws {
        var directory: URL?
        do {
            let volume = try TestDiskImage()
            directory = volume.directory
            try withExtendedLifetime(volume) { throw CancellationError() }
        } catch is CancellationError {}
        let root = try #require(directory)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
