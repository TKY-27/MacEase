import CArchive
import Foundation
import Testing

@testable import Formats

@Suite struct ArchiveExtractorTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = try #require(realpath(folder.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    @Test func zipBombsStopAtTheExpansionLimit() throws {
        let folder = try temporaryFolder()
        let source = folder.appending(path: "zeros", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(count: 4_000_000).write(to: source.appending(path: "zeros.bin"))
        let bomb = folder.appending(path: "bomb.zip")
        try ArchiveWriter.write([source], to: bomb, format: .zip, progress: { _ in }, skipping: { _ in false })
        let bombBytes = Int64(try #require(try bomb.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let limits = ExtractionLimits(maximumExpansionRatio: 100, allowanceBytes: 1_000)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        #expect(throws: ArchiveError.expandsTooMuch(limitBytes: bombBytes * 100)) {
            try ArchiveExtractor.extract(bomb, into: output, rawName: "bomb", password: nil, limits: limits) { _ in }
        }

        let generous = folder.appending(path: "generous", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: generous, withIntermediateDirectories: true)
        let layout = try ArchiveExtractor.extract(bomb, into: generous, rawName: "bomb", password: nil) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: generous.appending(path: "zeros/zeros.bin")).count == 4_000_000)
    }

    @Test func trailingSparseHoleCountsTowardExpansionLimit() throws {
        let folder = try temporaryFolder()
        let source = folder.appending(path: "sparse.tar")
        let writer = try #require(archive_write_new())
        defer { archive_write_free(writer) }
        #expect(archive_write_set_format_pax(writer) == ARCHIVE_OK)
        #expect(archive_write_open_filename(writer, source.path) == ARCHIVE_OK)
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, "sparse.bin")
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_size(entry, 4_000_000)
        archive_entry_sparse_add_entry(entry, 0, 1)
        #expect(archive_write_header(writer, entry) == ARCHIVE_OK)
        let byte: [UInt8] = [42]
        #expect(byte.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) } == 1)
        #expect(archive_write_close(writer) == ARCHIVE_OK)
        let archiveBytes = Int64(try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        #expect(archiveBytes < 4_000_000)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        #expect(throws: ArchiveError.expandsTooMuch(limitBytes: archiveBytes)) {
            try ArchiveExtractor.extract(
                source, into: output, rawName: "sparse", password: nil,
                limits: ExtractionLimits(maximumExpansionRatio: 1, allowanceBytes: 1)
            ) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.appending(path: "sparse.bin").path))
    }

    @Test func sameNamedRootsAreRejectedBeforeCreatingArchive() throws {
        let folder = try temporaryFolder()
        let first = folder.appending(path: "first/shared", directoryHint: .isDirectory)
        let second = folder.appending(path: "second/shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: first.appending(path: "file.txt"))
        try Data("second".utf8).write(to: second.appending(path: "file.txt"))
        let output = folder.appending(path: "shared.zip")

        #expect(throws: ArchiveError.duplicateRootName("shared")) {
            try ArchiveWriter.write(
                [first, second], to: output, format: .zip, progress: { _ in },
                skipping: {
                    _ in false
                })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func hardlinksOutsideTheArchiveAreRefused() throws {
        let folder = try temporaryFolder()
        let tar = folder.appending(path: "link.tar")
        let writer = try #require(archive_write_new())
        defer { archive_write_free(writer) }
        archive_write_set_format_pax_restricted(writer)
        #expect(archive_write_open_filename(writer, tar.path) == ARCHIVE_OK)
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, "inside")
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_hardlink(entry, "../outside")
        #expect(archive_write_header(writer, entry) == ARCHIVE_OK)
        #expect(archive_write_close(writer) == ARCHIVE_OK)
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        #expect(throws: ArchiveError.unsafePath("../outside")) {
            try ArchiveExtractor.extract(tar, into: output, rawName: "link", password: nil) { _ in }
        }
    }

    @Test func plainFilesAreNotArchives() throws {
        let folder = try temporaryFolder()
        let text = folder.appending(path: "fake.gz")
        try Data("not compressed".utf8).write(to: text)

        #expect(throws: FormatError.self) {
            try ArchiveExtractor.extract(text, into: folder, rawName: "fake", password: nil) { _ in }
        }
    }
}
