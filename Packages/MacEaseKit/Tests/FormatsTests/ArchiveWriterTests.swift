import Darwin
import Foundation
import Testing

@testable import Formats

@Suite struct ArchiveWriterTests {
    private static let sourceBytes = 2 * 1024 * 1024

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "archive-writer-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = try #require(realpath(folder.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func writeChanging(
        _ roots: [URL], to archive: URL, format: ArchiveFormat, change: () throws -> Void
    ) throws -> (any Error)? {
        var changed = false
        var changeError: (any Error)?
        var writeError: (any Error)?
        do {
            try ArchiveWriter.write(
                roots, to: archive, format: format,
                progress: { _ in
                    guard !changed else { return }
                    changed = true
                    do { try change() } catch { changeError = error }
                }, skipping: { _ in false })
        } catch {
            writeError = error
        }
        try #require(changed)
        if let changeError { throw changeError }
        return writeError
    }

    @Test(arguments: ArchiveFormat.allCases)
    func unchangedFilesAndLinksRoundTrip(format: ArchiveFormat) throws {
        let folder = try temporaryFolder()
        let source = folder.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data(repeating: 42, count: Self.sourceBytes)
        try payload.write(to: source.appending(path: "payload"))
        try Data().write(to: source.appending(path: "empty"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appending(path: "link").path, withDestinationPath: "payload")
        let archive = folder.appending(path: "output.\(format.rawValue)")
        try ArchiveWriter.write([source], to: archive, format: format, progress: { _ in }, skipping: { _ in false })
        let output = folder.appending(path: "extracted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try ArchiveExtractor.extract(archive, into: output, rawName: "output", password: nil) { _ in }
        #expect(try Data(contentsOf: output.appending(path: "source/payload")) == payload)
        #expect(try Data(contentsOf: output.appending(path: "source/empty")).isEmpty)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: output.appending(path: "source/link").path)
                == "payload")
    }

    @Test(arguments: ArchiveFormat.allCases)
    func shrinkingFileIsRejected(format: ArchiveFormat) throws {
        let folder = try temporaryFolder()
        let source = folder.appending(path: "source")
        try Data(repeating: 42, count: Self.sourceBytes).write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        let archive = folder.appending(path: "output")
        let failure = try writeChanging([source], to: archive, format: format) {
            try writer.truncate(atOffset: 0)
        }
        #expect(failure as? FormatError == .io("archive source changed: source"))
        #expect(try Data(contentsOf: source).isEmpty)
        if format == .tar {
            let archiveBytes = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(archiveBytes < Self.sourceBytes)
        }
    }

    @Test func growingFileIsRejected() throws {
        let folder = try temporaryFolder()
        let source = folder.appending(path: "source")
        try Data(repeating: 42, count: Self.sourceBytes).write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        let failure = try writeChanging([source], to: folder.appending(path: "output"), format: .tar) {
            try writer.seekToEnd()
            try writer.write(contentsOf: Data([43]))
        }
        #expect(failure as? FormatError == .io("archive source changed: source"))
    }

    @Test func sameSizeEditWithRestoredModificationTimeIsRejected() throws {
        let folder = try temporaryFolder()
        let source = folder.appending(path: "source")
        try Data(repeating: 42, count: Self.sourceBytes).write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        var original = stat()
        try #require(fstat(writer.fileDescriptor, &original) == 0)
        let failure = try writeChanging([source], to: folder.appending(path: "output"), format: .tar) {
            try writer.write(contentsOf: Data([43]))
            var times = [original.st_atimespec, original.st_mtimespec]
            try #require(futimens(writer.fileDescriptor, &times) == 0)
        }
        #expect(failure as? FormatError == .io("archive source changed: source"))
    }

    @Test func unreadFileReplacedBySymlinkIsRejected() throws {
        let folder = try temporaryFolder()
        let first = folder.appending(path: "first")
        let second = folder.appending(path: "second")
        let outside = folder.appending(path: "outside")
        for path in [first, second, outside] { try Data([42]).write(to: path) }
        let failure = try writeChanging([first, second], to: folder.appending(path: "output"), format: .tar) {
            try FileManager.default.removeItem(at: second)
            try FileManager.default.createSymbolicLink(at: second, withDestinationURL: outside)
        }
        #expect((failure as? POSIXError)?.code == .ELOOP)
        #expect(try Data(contentsOf: outside) == Data([42]))
    }

    @Test func unreadFileReplacedWithSameSizeIsRejected() throws {
        let folder = try temporaryFolder()
        let first = folder.appending(path: "first")
        let second = folder.appending(path: "second")
        let replacement = folder.appending(path: "replacement")
        for path in [first, second] { try Data([42]).write(to: path) }
        try Data([43]).write(to: replacement)
        var original = stat()
        try #require(lstat(second.path, &original) == 0)
        var times = [original.st_atimespec, original.st_mtimespec]
        try #require(utimensat(AT_FDCWD, replacement.path, &times, 0) == 0)
        let failure = try writeChanging([first, second], to: folder.appending(path: "output"), format: .tar) {
            try #require(rename(replacement.path, second.path) == 0)
        }
        #expect(failure as? FormatError == .io("archive source changed: second"))
        #expect(try Data(contentsOf: second) == Data([43]))
    }

    @Test func unreadFileReplacedByFIFOIsRejected() throws {
        let folder = try temporaryFolder()
        let first = folder.appending(path: "first")
        let second = folder.appending(path: "second")
        for path in [first, second] { try Data([42]).write(to: path) }
        let failure = try writeChanging([first, second], to: folder.appending(path: "output"), format: .tar) {
            try FileManager.default.removeItem(at: second)
            try #require(mkfifo(second.path, 0o600) == 0)
        }
        #expect(failure as? FormatError == .io("archive source changed: second"))
    }
}
