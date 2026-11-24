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

    @Test func hostileNamesStayLiteralAndPreserveRawPaths() throws {
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
        let entries = try ArchiveContents.list(archive).entries
        #expect(
            entries.map(\.path) == [
                "../escape.txt", "etc/passwd", "a/b/c.txt", "bell\u{7}name", "gnp.\u{202E}exe", "same", "same",
                "dup.txt", "dup.txt",
            ])
        #expect(entries[1].rawPath == "/etc/passwd")
        #expect(entries[2].rawPath == "./a//b/./c.txt")
        #expect(entries[3].rawPath == "bell\u{7}name")
    }

    @Test func dotAndRootEntriesAreDroppedWithoutCounting() throws {
        let archive = try tar(
            "rooted.tar",
            members: """
                    add('./', folder=True)
                    add('.', folder=False, size=4)
                    add('/', folder=True)
                    add('/.', folder=False, size=4)
                    add('./keep.txt', size=5)

                """)
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .complete)
        #expect(contents.entries.map(\.path) == ["keep.txt"])
        #expect(contents.entries.first?.rawPath == "./keep.txt")
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

    @Test func deepPathsKeepFileNameAndFullRawPath() throws {
        let archive = try tar("deep.tar", members: "    add('/'.join(['d'] * 299 + ['leaf.txt']))\n")
        let entry = try #require(try ArchiveContents.list(archive).entries.first)
        #expect(entry.path.hasSuffix("/leaf.txt"))
        #expect(entry.rawPath == Array(repeating: "d", count: 299).joined(separator: "/") + "/leaf.txt")
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
        let totalBytes = contents.entries.reduce(0) { $0 + $1.rawPath.utf8.count }
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

    @Test func tarXZBombStopsWithinDecodedBudgetAndTimeLimit() throws {
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
        #expect(contents.ending == .decodedLimit || contents.ending == .timeLimit)
        #expect(contents.entries.map(\.path) == ["zeros.bin"])
        #expect(contents.decodedBytes <= ArchiveContents.maximumDecodedBytes + Int64(ArchiveContents.decodedBlockBytes))
        #expect(elapsed < limit * 4)
    }

    @Test func multiEntryTarXZBombHonorsDecodedBudgetAndCancellation() throws {
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
        #expect(contents.ending == .decodedLimit)
        #expect((8...9).contains(contents.entries.count))
        #expect(contents.decodedBytes <= ArchiveContents.maximumDecodedBytes + Int64(ArchiveContents.decodedBlockBytes))

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

    @Test(arguments: ["bz2", "xz"])
    func paxXattrBombStopsAtDecodedBudgetWithFrequentChecks(compression: String) throws {
        let archive = try folder().appending(path: "xattr-bomb.tar.\(compression)")
        let script = """
            import bz2, lzma, sys, tarfile
            MiB = 1024 * 1024
            def pad(n): return b'\\0' * ((-n) % 512)
            def x_header(body_len):
                member = tarfile.TarInfo('././@PaxHeader')
                member.type = tarfile.XHDTYPE
                member.size = body_len
                member.mtime = 0
                return member.tobuf(format=tarfile.USTAR_FORMAT)
            def reg_header(name, size):
                member = tarfile.TarInfo(name)
                member.size = size
                member.mtime = 1700000000
                return member.tobuf(format=tarfile.USTAR_FORMAT)
            value_len = 16 * MiB - 1
            lines = []
            for number in range(60):
                key = f'SCHILY.xattr.user.a{number:03d}'.encode()
                payload_len = len(key) + value_len + 3
                total = len(str(payload_len)) + payload_len
                while len(str(total)) + payload_len != total:
                    total = len(str(total)) + payload_len
                lines.append((total, key))
            body_len = sum(total for total, _ in lines)
            compressor = bz2.BZ2Compressor(9) if sys.argv[2] == 'bz2' else lzma.LZMACompressor(preset=0)
            chunk = b'a' * value_len
            with open(sys.argv[1], 'wb') as out:
                out.write(compressor.compress(x_header(body_len)))
                for total, key in lines:
                    out.write(compressor.compress(str(total).encode() + b' ' + key + b'='))
                    out.write(compressor.compress(chunk))
                    out.write(compressor.compress(b'\\n'))
                out.write(compressor.compress(pad(body_len)))
                out.write(compressor.compress(reg_header('xattrs.bin', 0)))
                out.write(compressor.compress(b'\\0' * 1024))
                out.write(compressor.flush())
            """
        try run("/usr/bin/python3", ["-c", script, archive.path, compression])
        var lastCheck = ContinuousClock.now
        var longestGap = Duration.zero
        var checkCount = 0
        let contents = try ArchiveContents.list(archive) {
            let now = ContinuousClock.now
            let gap = lastCheck.duration(to: now)
            if gap > longestGap { longestGap = gap }
            lastCheck = now
            checkCount += 1
        }
        #expect(contents.ending == .decodedLimit)
        #expect(contents.entries.isEmpty)
        #expect(contents.decodedBytes <= ArchiveContents.maximumDecodedBytes + Int64(ArchiveContents.decodedBlockBytes))
        #expect(checkCount >= 1_000)
        #expect(longestGap < .milliseconds(100))
    }

    @Test(arguments: ["bz2", "xz"])
    func paxHardlinkBombRespectsDecodedBudget(compression: String) throws {
        let archive = try folder().appending(path: "hardlink-bomb.tar.\(compression)")
        let script = """
            import bz2, lzma, sys, tarfile
            MiB = 1024 * 1024
            def pad(n): return b'\\0' * ((-n) % 512)
            def pax_body(records):
                body = b''
                for key, value in records:
                    payload_len = len(key) + len(value) + 3
                    total = len(str(payload_len)) + payload_len
                    while len(str(total)) + payload_len != total:
                        total = len(str(total)) + payload_len
                    body += str(total).encode() + b' ' + key + b'=' + value + b'\\n'
                return body
            size = 256 * MiB
            body = pax_body([(b'path', b'link.bin'), (b'size', str(size).encode())])
            x_member = tarfile.TarInfo('././@PaxHeader')
            x_member.type = tarfile.XHDTYPE
            x_member.size = len(body)
            link_member = tarfile.TarInfo('link.bin')
            link_member.type = tarfile.LNKTYPE
            link_member.linkname = 'target.bin'
            link_member.size = 0
            after = tarfile.TarInfo('after.txt')
            after.size = 2
            compressor = bz2.BZ2Compressor(9) if sys.argv[2] == 'bz2' else lzma.LZMACompressor(preset=0)
            zeros = b'\\0' * (16 * MiB)
            with open(sys.argv[1], 'wb') as out:
                out.write(compressor.compress(x_member.tobuf(format=tarfile.USTAR_FORMAT) + body + pad(len(body))))
                out.write(compressor.compress(link_member.tobuf(format=tarfile.USTAR_FORMAT)))
                remaining = size
                while remaining > 0:
                    take = min(remaining, len(zeros))
                    out.write(compressor.compress(zeros[:take]))
                    remaining -= take
                out.write(compressor.compress(after.tobuf(format=tarfile.USTAR_FORMAT) + b'ok' + pad(2) + b'\\0' * 1024))
                out.write(compressor.flush())
            """
        try run("/usr/bin/python3", ["-c", script, archive.path, compression])
        var lastCheck = ContinuousClock.now
        var longestGap = Duration.zero
        let contents = try ArchiveContents.list(archive) {
            let now = ContinuousClock.now
            let gap = lastCheck.duration(to: now)
            if gap > longestGap { longestGap = gap }
            lastCheck = now
        }
        #expect(contents.ending == .decodedLimit)
        #expect(contents.entries.map(\.path) == ["link.bin"])
        #expect(contents.decodedBytes <= ArchiveContents.maximumDecodedBytes + Int64(ArchiveContents.decodedBlockBytes))
        #expect(longestGap < .milliseconds(100))
    }

    @Test func hugeDictionaryXZTarRespectsDecodedBudget() throws {
        let directory = try folder()
        let script = """
            import binascii, io, lzma, struct, sys, tarfile
            MiB = 1024 * 1024
            def build(path, size_mib):
                raw = io.BytesIO()
                with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                    member = tarfile.TarInfo('zeros.bin')
                    member.size = size_mib * MiB
                    archive.addfile(member, io.BytesIO(b'\\0' * member.size))
                xz = bytearray(lzma.compress(
                    raw.getvalue(), format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32,
                    filters=[{'id': lzma.FILTER_LZMA2, 'dict_size': 1 << 20, 'preset': 0}]))
                hsize = (xz[12] + 1) * 4
                block = xz[12:12 + hsize]
                block[4] = 40
                block[-4:] = struct.pack('<I', binascii.crc32(bytes(block[:-4])) & 0xffffffff)
                xz[12:12 + hsize] = block
                open(path, 'wb').write(xz)
            build(sys.argv[1], 60)
            build(sys.argv[2], 80)
            """
        let withinBudget = directory.appending(path: "hugedict-60m.tar.xz")
        let overBudget = directory.appending(path: "hugedict-80m.tar.xz")
        try run("/usr/bin/python3", ["-c", script, withinBudget.path, overBudget.path])

        let ok = try ArchiveContents.list(withinBudget)
        #expect(ok.ending == .complete)
        #expect(ok.entries.map(\.path) == ["zeros.bin"])
        #expect(ok.decodedBytes <= ArchiveContents.maximumDecodedBytes)

        let stopped = try ArchiveContents.list(overBudget)
        #expect(stopped.ending == .decodedLimit)
        #expect(stopped.entries.map(\.path) == ["zeros.bin"])
        #expect(stopped.decodedBytes <= ArchiveContents.maximumDecodedBytes + Int64(ArchiveContents.decodedBlockBytes))
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

    @Test func singleMemberGzipBombAndZeroLeadingSingleFileListTheirMember() throws {
        let directory = try folder()
        let bomb = directory.appending(path: "bomb.bin.gz")
        let bombScript = """
            import gzip, sys
            chunk = b'A' * (1024 * 1024)
            with gzip.open(sys.argv[1], 'wb', compresslevel=1) as out:
                for _ in range(400):
                    out.write(chunk)
            """
        try run("/usr/bin/python3", ["-c", bombScript, bomb.path])
        let start = ContinuousClock.now
        let bombContents = try ArchiveContents.list(bomb, maximumDuration: .milliseconds(50))
        #expect(bombContents.ending == .complete)
        #expect(bombContents.entries.map(\.path) == ["bomb.bin"])
        #expect(bombContents.decodedBytes <= Int64(ArchiveContents.decodedBlockBytes))
        #expect(start.duration(to: .now) < .milliseconds(200))

        let isoGZ = directory.appending(path: "image.iso.gz")
        let emptyTarGZ = directory.appending(path: "empty.tar.gz")
        let zeroScript = """
            import gzip, sys
            iso = b'\\0' * 32768 + b'\\x01CD001\\x01' + b'\\0' * 2041
            with gzip.open(sys.argv[1], 'wb') as out:
                out.write(iso)
            with gzip.open(sys.argv[2], 'wb') as out:
                out.write(b'\\0' * 10240)
            """
        try run("/usr/bin/python3", ["-c", zeroScript, isoGZ.path, emptyTarGZ.path])
        let isoContents = try ArchiveContents.list(isoGZ)
        #expect(isoContents.ending == .complete)
        #expect(isoContents.entries.map(\.path) == ["image.iso"])

        let emptyContents = try ArchiveContents.list(emptyTarGZ)
        #expect(emptyContents.ending == .complete)
        #expect(emptyContents.entries.isEmpty)
    }

    @Test func corruptMiddleHeaderAndTrailingGarbageReportDamaged() throws {
        let directory = try folder()
        let corruptMiddle = directory.appending(path: "corrupt-middle.tar")
        let garbageTail = directory.appending(path: "garbage-tail.tar")
        let script = """
            import sys, tarfile
            def member(name, size):
                entry = tarfile.TarInfo(name)
                entry.size = size
                entry.mtime = 1700000000
                return entry.tobuf(format=tarfile.USTAR_FORMAT) + b'x' * size + b'\\0' * ((-size) % 512)
            a, b, c = member('a.txt', 10), bytearray(member('b.bin', 8192)), member('c.txt', 3)
            b[148:156] = b'0000000\\0'
            open(sys.argv[1], 'wb').write(a + bytes(b) + c + b'\\0' * 1024)
            with open(sys.argv[2], 'wb') as out:
                out.write(member('first.txt', 5))
                out.write(b'\\xAA' * (4 * 1024 * 1024))
            """
        try run("/usr/bin/python3", ["-c", script, corruptMiddle.path, garbageTail.path])

        let middleContents = try ArchiveContents.list(corruptMiddle)
        #expect(middleContents.ending == .damaged)
        #expect(middleContents.entries.map(\.path) == ["a.txt"])

        var tailChecks = 0
        let tailContents = try ArchiveContents.list(garbageTail) { tailChecks += 1 }
        #expect(tailContents.ending == .damaged)
        #expect(tailContents.entries.map(\.path) == ["first.txt"])
        #expect(tailChecks < 100)
    }

    @Test func overlappingEntriesZIPIsRefusedAsDamagedLikeBrowser() throws {
        let archive = try folder().appending(path: "macext-bomb.zip")
        let script = """
            import struct, sys, zlib
            payload = b'\\0' * 1024
            compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
            deflated = compressor.compress(payload) + compressor.flush()
            crc = zlib.crc32(payload) & 0xffffffff
            lname = b'__MACOSX/._f0'
            local = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, 8, 0, 0, crc, len(deflated), len(payload), len(lname), 0) + lname + deflated
            plain_name = b'f0'
            plain_offset = len(local)
            plain = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, 0, 0, 0, 0, 0, 0, len(plain_name), 0) + plain_name
            cd = bytearray()
            count = 0
            for number in range(2_000):
                for name, offset, method, csize, usize, ccrc in (
                    (f'f{number}'.encode(), plain_offset, 0, 0, 0, 0),
                    (f'__MACOSX/._f{number}'.encode(), 0, 8, len(deflated), len(payload), crc)):
                    cd += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, 0, method, 0, 0, ccrc, csize, usize, len(name), 0, 0, 0, 0, 0, offset) + name
                    count += 1
            cd_offset = len(local) + len(plain)
            eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, count, count, len(cd), cd_offset, 0)
            open(sys.argv[1], 'wb').write(local + plain + bytes(cd) + eocd)
            """
        try run("/usr/bin/python3", ["-c", script, archive.path])
        #expect(throws: ZIPBrowserError.invalidZIP) { try ArchiveBrowserZIP.list(archive) }
        #expect(throws: ArchiveContents.Failure.damaged) { try ArchiveContents.list(archive) }
    }

    @Test func prependedZIPListsSameAsBrowser() throws {
        let archive = try folder().appending(path: "prepended.zip")
        let script = """
            import io, sys, zipfile
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, 'w') as z:
                z.writestr('inside.txt', b'hello')
            open(sys.argv[1], 'wb').write(b'#!/bin/sh\\necho self-extract\\n' + buf.getvalue())
            """
        try run("/usr/bin/python3", ["-c", script, archive.path])
        #expect(try ArchiveBrowserZIP.list(archive).map(\.path) == ["inside.txt"])
        let contents = try ArchiveContents.list(archive)
        #expect(contents.ending == .complete)
        #expect(contents.entries.map(\.path) == ["inside.txt"])
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
