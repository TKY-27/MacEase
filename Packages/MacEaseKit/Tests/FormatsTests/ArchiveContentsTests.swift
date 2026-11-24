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
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.currentDirectoryURL = directory
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
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
        ("sample.zip", ["--format", "zip"]),
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

    @Test func dotAndRootEntriesAreDroppedWithoutCounting() throws {
        let archive = try tar(
            "rooted.tar",
            members: """
                    add('./', folder=True)
                    add('.', folder=False, size=4)
                    add('/', folder=False, size=4)
                    add('./keep.txt', size=5)

                """)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .complete)
        #expect(contents.entries.map(\.path) == ["keep.txt"])
    }

    @Test func tarStartingWithPKListsAsTar() throws {
        let archive = try tar("pk.tar", members: "    add('PK-notes.txt', size=5)\n    add('second.txt', size=3)\n")
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .complete)
        #expect(contents.entries.map(\.path) == ["PK-notes.txt", "second.txt"])
    }

    @Test func emptyZIPAndEmptyTARListAsCompleteAndEmpty() throws {
        let directory = try folder()
        let emptyZIP = directory.appending(path: "empty.zip")
        try run(
            "/usr/bin/python3",
            ["-c", "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w'): pass\n", emptyZIP.path])
        let zipContents = try ArchiveContents.list(emptyZIP)
        #expect(zipContents.ending == .complete)
        #expect(zipContents.entries.isEmpty)

        let emptyTAR = directory.appending(path: "empty.tar")
        try run(
            "/usr/bin/python3",
            ["-c", "import sys, tarfile\nwith tarfile.open(sys.argv[1], 'w'): pass\n", emptyTAR.path])
        let tarContents = try ArchiveContents.list(emptyTAR)
        #expect(tarContents.ending == .complete)
        #expect(tarContents.entries.isEmpty)
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

    @Test func stopsAtTheNameBytesLimitInTAR() throws {
        let archive = try tar(
            "long-names.tar",
            members: """
                    part = 'a' * 100
                    prefix = '/'.join([part] * 50) + '/'
                    for number in range(6_700):
                        add(f'{prefix}{number:05d}')

                """)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .nameLimit)
        #expect(!contents.entries.isEmpty)
        let totalBytes = contents.entries.reduce(0) { $0 + $1.path.utf8.count }
        #expect(totalBytes <= ArchiveContents.maximumNameBytes)
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

    @Test func zipOverTheNameBytesLimitIsNamesTooLarge() throws {
        let archive = try folder().appending(path: "long-names.zip")
        try run(
            "/usr/bin/python3",
            [
                "-c",
                "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w', allowZip64=True) as archive:\n"
                    + "    for number in range(517):\n"
                    + "        archive.writestr('x' * 65000 + str(number), b'')\n",
                archive.path,
            ])
        #expect(throws: ArchiveContents.Failure.namesTooLarge) { try ArchiveContents.list(archive) }
    }

    @Test func spentTimeBudgetReturnsWhatWasRead() throws {
        let archive = try tar("slow.tar", members: "    add('first.txt')\n")
        let contents = try ArchiveContents.list(archive, maximumDuration: .zero)
        #expect(contents.ending == .timeLimit)
        #expect(contents.entries.isEmpty)
    }

    @Test func zipPreflightRespectsTheDeadline() throws {
        let archive = try folder().appending(path: "preflight.zip")
        try run(
            "/usr/bin/python3",
            [
                "-c",
                "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w') as archive:\n"
                    + "    for number in range(2_000):\n"
                    + "        archive.writestr(f'f{number}.txt', b'x')\n",
                archive.path,
            ])
        var checks = 0
        let contents = try ArchiveContents.list(archive, maximumDuration: .zero) {
            checks += 1
        }
        #expect(contents.ending == .timeLimit)
        #expect(contents.entries.isEmpty)
        #expect(checks <= 2)
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

    @Test func tarXZBombStopsWithinSkipBudgetAndTimeLimit() throws {
        let archive = try folder().appending(path: "bomb.tar.xz")
        let script = """
            import io, lzma, sys, tarfile
            chunk = b'\\0' * (1024 * 1024)
            class Zeros(io.RawIOBase):
                def __init__(self, remaining):
                    self.remaining = remaining
                def read(self, size=-1):
                    if self.remaining <= 0:
                        return b''
                    take = self.remaining if size is None or size < 0 else min(self.remaining, size)
                    self.remaining -= take
                    return chunk[:take] if take <= len(chunk) else b'\\0' * take
            with lzma.open(sys.argv[1], 'wb', preset=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w|') as archive:
                    first = tarfile.TarInfo('zeros.bin')
                    first.size = 400 * 1024 * 1024
                    archive.addfile(first, Zeros(first.size))
                    second = tarfile.TarInfo('after.txt')
                    second.size = 2
                    archive.addfile(second, io.BytesIO(b'ok'))
            """
        try run("/usr/bin/python3", ["-c", script, archive.path])
        let limit: Duration = .milliseconds(50)
        let start = ContinuousClock.now
        let contents = try ArchiveContents.list(archive, maximumDuration: limit)
        let elapsed = start.duration(to: .now)
        #expect(contents.ending == .skipLimit || contents.ending == .timeLimit)
        #expect(contents.entries.map(\.path) == ["zeros.bin"])
        #expect(elapsed < limit * 4)
    }

    @Test func multiEntryTarXZBombHonorsSkipBudgetAndCancellation() throws {
        let archive = try folder().appending(path: "chunked-bomb.tar.xz")
        let script = """
            import io, lzma, sys, tarfile
            chunk = b'\\0' * (1024 * 1024)
            class Zeros(io.RawIOBase):
                def __init__(self, remaining):
                    self.remaining = remaining
                def read(self, size=-1):
                    if self.remaining <= 0:
                        return b''
                    take = self.remaining if size is None or size < 0 else min(self.remaining, size)
                    self.remaining -= take
                    return chunk[:take] if take <= len(chunk) else b'\\0' * take
            with lzma.open(sys.argv[1], 'wb', preset=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w|') as archive:
                    for number in range(12):
                        member = tarfile.TarInfo(f'part-{number:02d}.bin')
                        member.size = 8 * 1024 * 1024
                        archive.addfile(member, Zeros(member.size))
            """
        try run("/usr/bin/python3", ["-c", script, archive.path])
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .skipLimit)
        #expect(contents.entries.count == 9)

        var checks = 0
        let cancelStart = ContinuousClock.now
        #expect(throws: CancellationError.self) {
            try ArchiveContents.list(archive) {
                checks += 1
                if checks >= 6 { throw CancellationError() }
            }
        }
        #expect(cancelStart.duration(to: .now) < .milliseconds(250))
    }

    @Test func doublyCompressedTarIsRefusedQuickly() throws {
        let archive = try folder().appending(path: "double.tar.xz.gz")
        let script = """
            import gzip, io, lzma, sys, tarfile
            raw = io.BytesIO()
            with tarfile.open(fileobj=raw, mode='w') as archive:
                member = tarfile.TarInfo('nested.txt')
                member.size = 5
                archive.addfile(member, io.BytesIO(b'hello'))
            xz_bytes = lzma.compress(raw.getvalue(), preset=0)
            with gzip.open(sys.argv[1], 'wb', compresslevel=1) as outer:
                outer.write(xz_bytes)
            """
        try run("/usr/bin/python3", ["-c", script, archive.path])
        let start = ContinuousClock.now
        #expect(throws: ArchiveContents.Failure.unsupported) {
            try ArchiveContents.list(archive, maximumDuration: .milliseconds(50))
        }
        #expect(start.duration(to: .now) < .milliseconds(200))
    }

    @Test func multiGigabyteSparseTarListsQuickly() throws {
        let directory = try folder()
        let sparseFile = directory.appending(path: "sparse.bin")
        let trailing = directory.appending(path: "after.txt")
        try Data("ok".utf8).write(to: trailing)
        try run(
            "/usr/bin/python3",
            [
                "-c",
                "import sys\nwith open(sys.argv[1], 'wb') as out:\n"
                    + "    out.seek(10 * 1024 * 1024 * 1024 - 1)\n    out.write(b'\\0')\n",
                sparseFile.path,
            ])
        let expectedSize: Int64 = 10 * 1024 * 1024 * 1024
        for (name, extra) in [("sparse.tar", []), ("sparse.tar.xz", ["--xz"])] {
            let archive = directory.appending(path: name)
            try run(
                "/usr/bin/bsdtar", ["-c", "-f", archive.path] + extra + ["sparse.bin", "after.txt"], in: directory)
            let start = ContinuousClock.now
            let contents = try ArchiveContents.list(archive, maximumDuration: .milliseconds(50))
            let elapsed = start.duration(to: .now)
            #expect(contents.ending == .complete)
            #expect(contents.entries.map(\.path) == ["sparse.bin", "after.txt"])
            #expect(contents.entries.first?.size == expectedSize)
            #expect(elapsed < .milliseconds(200))
        }
    }

    @Test func singleMemberGzipBombListsQuickly() throws {
        let archive = try folder().appending(path: "bomb.bin.gz")
        let script = """
            import gzip, sys
            chunk = b'A' * (1024 * 1024)
            with gzip.open(sys.argv[1], 'wb', compresslevel=1) as out:
                for _ in range(400):
                    out.write(chunk)
            """
        try run("/usr/bin/python3", ["-c", script, archive.path])
        let start = ContinuousClock.now
        let contents = try ArchiveContents.list(archive, maximumDuration: .milliseconds(50))
        let elapsed = start.duration(to: .now)
        #expect(contents.ending == .complete)
        #expect(contents.entries.map(\.path) == ["bomb.bin"])
        #expect(elapsed < .milliseconds(200))
    }

    @Test func sevenZipAndRARAreUnsupported() throws {
        let source = try sampleFolder()
        let directory = source.deletingLastPathComponent()
        let sevenZip = directory.appending(path: "sample.7z")
        try run("/usr/bin/bsdtar", ["-c", "-f", sevenZip.path, "--format", "7zip", "readme.txt"], in: source)
        #expect(throws: ArchiveContents.Failure.unsupported) { try ArchiveContents.list(sevenZip) }

        let rar = directory.appending(path: "sample.rar")
        let marker: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let mainHeader: [UInt8] = [0x00, 0x00, 0x73, 0x80, 0x00, 0x0D, 0x00] + [UInt8](repeating: 0, count: 6)
        try Data(marker + mainHeader).write(to: rar)
        #expect(throws: ArchiveContents.Failure.unsupported) { try ArchiveContents.list(rar) }
    }

    @Test func encryptedZIPEntriesAreListedAndMarked() throws {
        let source = try sampleFolder()
        let archive = source.deletingLastPathComponent().appending(path: "locked.zip")
        try run("/usr/bin/zip", ["-q", "-P", "secret", archive.path, "readme.txt"], in: source)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.entries.map(\.path) == ["readme.txt"])
        #expect(contents.entries.first?.isEncrypted == true)
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

    @Test func damagedCompressedArchiveAfterMagicReportsDamaged() throws {
        let directory = try folder()
        let cases: [(String, [UInt8])] = [
            ("cut.gz", [0x1F, 0x8B, 0x08, 0x00]),
            ("broken.tar.gz", [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xEE, 0xDD]),
            ("broken.bz2", [0x42, 0x5A, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0xFF, 0xEE]),
            ("broken.xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA]),
        ]
        for (name, bytes) in cases {
            let archive = directory.appending(path: name)
            try Data(bytes).write(to: archive)
            #expect(throws: ArchiveContents.Failure.damaged, "\(name)") { try ArchiveContents.list(archive) }
        }
    }

    @Test func brokenZIPIsDamaged() throws {
        let archive = try folder().appending(path: "broken.zip")
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0xEE, count: 200)).write(to: archive)
        #expect(throws: ArchiveContents.Failure.damaged) { try ArchiveContents.list(archive) }
    }

    @Test func unknownBytesAreUnsupported() throws {
        let archive = try folder().appending(path: "noise.tar")
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

    @Test func longZIPCommentListsInPreview() throws {
        let archive = try folder().appending(path: "commented.zip")
        try run(
            "/usr/bin/python3",
            [
                "-c",
                "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w') as archive:\n"
                    + "    archive.writestr('note.txt', b'hello')\n    archive.comment = b'c' * 60000\n",
                archive.path,
            ])
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .complete)
        #expect(contents.entries.map(\.path) == ["note.txt"])
    }
}
