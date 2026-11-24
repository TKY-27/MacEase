import Foundation
import Testing

@testable import Formats

@Suite(.serialized) struct ArchiveContentsTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "archive-contents-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    // Python's tarfile writes any member name verbatim.
    private func tar(_ name: String, mode: String = "w", members body: String) throws -> URL {
        let archive = try folder().appending(path: name)
        let script =
            "import io, sys, tarfile\nwith tarfile.open(sys.argv[1], '\(mode)') as archive:\n"
            + "    def add(name, size=0, folder=False, mtime=1700000000):\n"
            + "        info = tarfile.TarInfo(name)\n        info.mtime = mtime\n"
            + "        info.type = tarfile.DIRTYPE if folder else tarfile.REGTYPE\n"
            + "        info.size = 0 if folder else size\n"
            + "        archive.addfile(info, None if folder else io.BytesIO(b'x' * size))\n" + body
        try run("/usr/bin/python3", ["-c", script, archive.path])
        return archive
    }

    private func sampleFolder() throws -> URL {
        let source = try folder().appending(path: "source")
        try FileManager.default.createDirectory(
            at: source.appending(path: "Photos/2026"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1_234).write(to: source.appending(path: "Photos/2026/beach.jpg"))
        try Data("notes".utf8).write(to: source.appending(path: "readme.txt"))
        return source
    }

    @Test(arguments: [
        ("sample.zip", ["--format", "zip"]), ("sample.7z", ["--format", "7zip"]),
        ("sample.tar", ["--format", "ustar"]), ("sample.tar.gz", ["--format", "ustar", "--gzip"]),
        ("sample.tar.bz2", ["--format", "ustar", "--bzip2"]), ("sample.tar.xz", ["--format", "ustar", "--xz"]),
    ])
    func listsEveryFormatTheEngineReads(name: String, options: [String]) throws {
        let source = try sampleFolder()
        let archive = source.deletingLastPathComponent().appending(path: name)
        try run("/usr/bin/bsdtar", ["-c", "-f", archive.path] + options + ["Photos", "readme.txt"], in: source)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .complete)
        let byPath = Dictionary(contents.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byPath["Photos/2026/beach.jpg"]?.size == 1_234)
        #expect(byPath["readme.txt"]?.size == 5)
        #expect(byPath["Photos/2026"]?.isDirectory == true)
        #expect(byPath["readme.txt"]?.modified != nil)
        #expect(contents.entries.allSatisfy { !$0.isEncrypted })
    }

    @Test func hostileNamesStayLiteralExceptEmptyAndDotComponents() throws {
        let archive = try tar(
            "names.tar",
            members: """
                    add('../escape.txt')
                    add('/etc/passwd')
                    add('./a//b/./c.txt')
                    add('bell\\x07name')
                    add('gnp.\\u202eexe')
                    add('same')
                    add('same', folder=True)
                    add('dup.txt')
                    add('dup.txt')

                """)
        let paths = try ArchiveContents.list(archive).entries.map(\.path)
        #expect(
            paths == [
                "../escape.txt", "etc/passwd", "a/b/c.txt", "bell\u{7}name", "gnp.\u{202E}exe", "same", "same",
                "dup.txt", "dup.txt",
            ])
    }

    @Test func deepPathsAreCappedAtTheDepthLimit() throws {
        let archive = try tar("deep.tar", members: "    add('/'.join(['d'] * 300))\n")
        let path = try #require(try ArchiveContents.list(archive).entries.first).path
        #expect(path.split(separator: "/").count == ArchiveContents.maximumPathDepth)
    }

    @Test func stopsAtTheEntryLimitWithTheFirstEntries() throws {
        let archive = try tar(
            "many.tar",
            members: "    for number in range(\(ArchiveContents.maximumEntries + 1)):\n        add(str(number))\n")
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .entryLimit)
        #expect(contents.entries.count == ArchiveContents.maximumEntries)
        #expect(contents.entries.first?.path == "0")
    }

    @Test func zipOverTheEntryLimitIsTooLarge() throws {
        let archive = try folder().appending(path: "many.zip")
        try run(
            "/usr/bin/python3",
            [
                "-c",
                "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w', allowZip64=True) as archive:\n"
                    + "    for number in range(\(ArchiveContents.maximumEntries + 1)):\n"
                    + "        archive.writestr(str(number), b'')\n",
                archive.path,
            ])
        #expect(throws: ArchiveContents.Failure.tooLarge) { try ArchiveContents.list(archive) }
    }

    @Test func spentTimeBudgetReturnsWhatWasRead() throws {
        let archive = try tar("slow.tar", members: "    add('first.txt')\n")
        let contents = try ArchiveContents.list(archive, maximumDuration: .zero)
        #expect(contents.ending == .timeLimit)
        #expect(contents.entries.isEmpty)
    }

    @Test func cancellationInterruptsALongCompressedEntry() throws {
        let archive = try tar(
            "big.tar.gz", mode: "w:gz", members: "    add('big.bin', size=64 * 1024 * 1024)\n    add('after.txt')\n")
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ArchiveContents.list(archive) {
                checks += 1
                if checks > 3 { throw CancellationError() }
            }
        }
        #expect(checks < 64)
    }

    @Test func encryptedZIPEntriesAreListedAndMarked() throws {
        let source = try sampleFolder()
        let archive = source.deletingLastPathComponent().appending(path: "locked.zip")
        try run("/usr/bin/zip", ["-q", "-P", "secret", archive.path, "readme.txt"], in: source)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.entries.map(\.path) == ["readme.txt"])
        #expect(contents.entries.first?.isEncrypted == true)
    }

    @Test func encryptedRARHeadersArePasswordProtected() throws {
        let archive = try folder().appending(path: "locked.rar")
        let marker: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let passwordFlag: [UInt8] = [0x80, 0x00]
        let mainHeader: [UInt8] = [0x00, 0x00, 0x73] + passwordFlag + [0x0D, 0x00] + [UInt8](repeating: 0, count: 6)
        try Data(marker + mainHeader).write(to: archive)
        #expect(throws: ArchiveContents.Failure.passwordProtected) { try ArchiveContents.list(archive) }
    }

    @Test func truncatedArchiveKeepsTheReadableEntries() throws {
        let archive = try tar(
            "cut.tar",
            members: "    add('first.txt', size=10)\n    add('second.bin', size=8192)\n    add('third.txt')\n")
        let bytes = try Data(contentsOf: archive)
        try bytes.prefix(512 * 4).write(to: archive)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .damaged)
        #expect(contents.entries.map(\.path) == ["first.txt", "second.bin"])
    }

    @Test func brokenZIPIsDamaged() throws {
        let archive = try folder().appending(path: "broken.zip")
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0xEE, count: 200)).write(to: archive)
        #expect(throws: ArchiveContents.Failure.damaged) { try ArchiveContents.list(archive) }
    }

    @Test func unknownBytesAreUnsupported() throws {
        let archive = try folder().appending(path: "noise.7z")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: archive)
        #expect(throws: ArchiveContents.Failure.unsupported) { try ArchiveContents.list(archive) }
    }

    @Test func loneCompressedFileListsItsExpandedName() throws {
        let directory = try folder()
        let file = directory.appending(path: "server.log")
        try Data(repeating: 65, count: 4_000).write(to: file)
        try run("/usr/bin/gzip", [file.path])
        let contents = try ArchiveContents.list(directory.appending(path: "server.log.gz"))
        #expect(contents.entries.map(\.path) == ["server.log"])
        #expect(contents.entries.first?.isDirectory == false)
    }
}
