import AppKit
import Engine
import Formats
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import MacEase

final class PreviewArchiveTests: XCTestCase {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PreviewArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
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
        XCTAssertEqual(command.terminationStatus, 0, executable)
    }

    private func tar(_ archive: URL, members body: String) throws {
        let script =
            "import io, sys, tarfile\nwith tarfile.open(sys.argv[1], 'w') as archive:\n"
            + "    def add(name, size=0):\n        info = tarfile.TarInfo(name)\n        info.size = size\n"
            + "        archive.addfile(info, io.BytesIO(b'x' * size))\n" + body
        try run("/usr/bin/python3", ["-c", script, archive.path])
    }

    private func zip(in directory: URL, password: String? = nil) throws -> URL {
        let source = directory.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: "Docs"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: source.appending(path: "Docs/notes.txt"))
        try Data(repeating: 1, count: 2_048).write(to: source.appending(path: "photo.png"))
        let archive = directory.appending(path: "sample.zip")
        try run(
            "/usr/bin/zip", ["-q", "-r"] + (password.map { ["-P", $0] } ?? []) + [archive.path, "Docs", "photo.png"],
            in: source)
        return archive
    }

    private func entry(
        _ id: Int, _ path: String, directory: Bool = false, size: Int64? = nil, modified: Date? = nil
    ) -> ArchiveEntry {
        ArchiveEntry(id: id, path: path, isDirectory: directory, size: size, isEncrypted: false, modified: modified)
    }

    func testSupportedArchiveExtensionsRouteToTheContentsListAnd7zRARUseSystemPreview() {
        for suffix in ["zip", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz", "ZIP"] {
            let type = UTType(filenameExtension: suffix)
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix), .archive, suffix)
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix, disabled: [.archive]), .quickLook, suffix)
            XCTAssertEqual(
                PreviewKind.resolve(type: type, extension: suffix, disabled: [.text, .image]), .archive, suffix)
        }
        for suffix in ["7z", "rar", "7Z", "RAR", "docx"] {
            let type = UTType(filenameExtension: suffix)
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix), .quickLook, suffix)
        }
    }

    func testRealArchiveAndEmptyTARMatchWhileMisnamedOneShowsMismatch() throws {
        let directory = try folder()
        let archive = try zip(in: directory)
        let (kind, detected) = try PreviewKind.inspectContent(archive)
        XCTAssertEqual(kind, .archive)
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .archive, detected: try XCTUnwrap(detected)), .matches)

        let emptyTAR = directory.appending(path: "empty.tar")
        try tar(emptyTAR, members: "    pass\n")
        XCTAssertEqual(
            ContentSniffer.identify(header: [UInt8](repeating: 0, count: 4_096)),
            DetectedContent(family: .binary, displayName: "Binary file"))
        XCTAssertEqual(
            try ContentSniffer.identify(emptyTAR),
            DetectedContent(family: .binary, displayName: "Binary file"))
        let emptyResult = try PreviewKind.inspectContent(emptyTAR)
        XCTAssertEqual(emptyResult.kind, .archive)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: .archive, detected: try XCTUnwrap(emptyResult.detected)), .matches)

        let isoAsTAR = directory.appending(path: "image.tar")
        var isoBytes = Data(repeating: 0, count: 32_768)
        isoBytes.append(contentsOf: [0x01, 0x43, 0x44, 0x30, 0x30, 0x31, 0x01])
        isoBytes.append(Data(repeating: 0, count: 2_041))
        try isoBytes.write(to: isoAsTAR)
        let isoDetected = try XCTUnwrap(PreviewKind.inspectContent(isoAsTAR).detected)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: .archive, detected: isoDetected),
            .mismatch(detectedName: "Binary file"))

        let oddZeroTAR = directory.appending(path: "odd.tar")
        try Data(repeating: 0, count: 1_500).write(to: oddZeroTAR)
        let oddDetected = try XCTUnwrap(PreviewKind.inspectContent(oddZeroTAR).detected)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: .archive, detected: oddDetected),
            .mismatch(detectedName: "Binary file"))

        let fake = directory.appending(path: "fake.tar")
        try Data("plain words".utf8).write(to: fake)
        let fakeDetected = try XCTUnwrap(PreviewKind.inspectContent(fake).detected)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: .archive, detected: fakeDetected), .mismatch(detectedName: "Text"))
    }

    @MainActor
    func testArchivesToggleDefaultsOnForOldSettingsAndPersists() throws {
        let old = try FinderPreviewSettings.decode(Data(#"{"disabledKinds":["svg"]}"#.utf8))
        XCTAssertFalse(old.disabledKinds.contains(.archive))
        XCTAssertTrue(FinderPreviewFileType.allCases.contains(.archive))
        XCTAssertFalse(FinderPreviewFileType.archive.title.isEmpty)

        let suite = "PreviewArchiveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.finderPreview.disabledKinds.insert(.archive)
        XCTAssertEqual(SettingsStore(defaults: defaults).finderPreview.disabledKinds, [.archive])
    }

    func testTreeImpliesFoldersDropsEmptyEntriesAndKeepsDuplicatesAndSameNamedFileAndFolder() throws {
        let nodes = try ArchiveTree.nodes([
            entry(0, "a/b/c.txt", size: 3), entry(1, "dup.txt", size: 1), entry(2, "dup.txt", size: 2),
            entry(3, "same", size: 4), entry(4, "same/", directory: true), entry(5, "same/inside.txt"),
            entry(6, "./", directory: true), entry(7, "."), entry(8, "/"),
        ])
        XCTAssertEqual(nodes.map(\.name), ["a", "same", "dup.txt", "dup.txt", "same"])
        XCTAssertEqual(nodes[0].id, "folder:a")
        XCTAssertEqual(nodes[0].children?.first?.children?.first?.path, "a/b/c.txt")
        XCTAssertEqual(nodes[1].children?.map(\.name), ["inside.txt"])
        XCTAssertEqual(Set(nodes[2...3].map(\.id)), ["entry:1", "entry:2"])
        XCTAssertFalse(nodes[4].isDirectory)
        XCTAssertEqual(ArchiveTree.count(nodes), 8)
    }

    func testHostileNamesDisplayAsInertBoundedTextIncludingCombiningMarks() throws {
        let nodes = try ArchiveTree.nodes([
            entry(0, "../escape.sh"), entry(1, "/etc/hosts"), entry(2, "bell\u{7}name"),
            entry(3, "invoice\u{202E}fdp.exe"), entry(4, "line\nbreak\u{2028}"),
        ])
        XCTAssertEqual(
            Set(nodes.map(\.name)), ["..", "etc", "bell\u{7}name", "invoice\u{202E}fdp.exe", "line\nbreak\u{2028}"])
        XCTAssertEqual(nodes.first { $0.name == ".." }?.children?.map(\.path), ["../escape.sh"])
        XCTAssertEqual(nodes.first { $0.name == "etc" }?.children?.map(\.path), ["etc/hosts"])
        XCTAssertEqual(ArchiveTree.displayText("bell\u{7}name"), "bell\u{FFFD}name")
        XCTAssertEqual(ArchiveTree.displayText("invoice\u{202E}fdp.exe"), "invoice\u{FFFD}fdp.exe")
        XCTAssertEqual(ArchiveTree.displayText("a\u{2067}b\u{200F}c"), "a\u{FFFD}b\u{FFFD}c")
        XCTAssertEqual(ArchiveTree.displayText("line\nbreak\u{2028}"), "line\u{FFFD}break\u{FFFD}")
        XCTAssertEqual(ArchiveTree.displayText("日本語 🎉.txt"), "日本語 🎉.txt")
        let long = ArchiveTree.displayText(String(repeating: "x", count: 5_000) + ".txt")
        XCTAssertEqual(long.count, ArchiveTree.maximumDisplayLength + 1)
        XCTAssertTrue(long.hasSuffix("x.txt"))
        XCTAssertTrue(long.contains("…"))

        let combiningBomb = "a" + String(repeating: "\u{0301}", count: 5_000)
        let shortened = ArchiveTree.displayText(combiningBomb)
        XCTAssertLessThanOrEqual(shortened.unicodeScalars.count, ArchiveTree.maximumDisplayLength + 1)
        XCTAssertTrue(shortened.contains("…"))
    }

    func testNameOrderFollowsFindersKeepFoldersOnTopSetting() throws {
        let entries = [
            entry(0, "b.txt"), entry(1, "c/", directory: true), entry(2, "a.txt"), entry(3, "file10.txt"),
            entry(4, "file9.txt"),
        ]
        XCTAssertEqual(
            try ArchiveTree.nodes(entries, foldersFirst: false).map(\.name),
            ["a.txt", "b.txt", "c", "file9.txt", "file10.txt"])
        XCTAssertEqual(
            try ArchiveTree.nodes(entries, foldersFirst: true).map(\.name),
            ["c", "a.txt", "b.txt", "file9.txt", "file10.txt"])
        let nodes = try ArchiveTree.nodes(entries)
        XCTAssertEqual(
            try PreviewArchiveSort(column: .name, ascending: true, foldersFirst: false).sorted(nodes).map(\.name),
            ["a.txt", "b.txt", "c", "file9.txt", "file10.txt"])
        XCTAssertEqual(
            try PreviewArchiveSort(column: .name, ascending: true, foldersFirst: true).sorted(nodes).map(\.name),
            ["c", "a.txt", "b.txt", "file9.txt", "file10.txt"])
    }

    func testDeepPathsCapTreeDepthWithoutDroppingFileName() throws {
        let deepPath = Array(repeating: "d", count: 299).joined(separator: "/") + "/leaf.txt"
        let nodes = try ArchiveTree.nodes([
            ArchiveEntry(
                id: 0, path: deepPath, isDirectory: false, size: 7, isEncrypted: false, rawPath: "/" + deepPath)
        ])
        var depth = 0
        var current = nodes
        var leaf: ArchiveNode?
        while let first = current.first {
            depth += 1
            if let children = first.children {
                current = children
            } else {
                leaf = first
                break
            }
        }
        XCTAssertEqual(depth, ArchiveContents.maximumPathDepth)
        let unwrappedLeaf = try XCTUnwrap(leaf)
        XCTAssertTrue(unwrappedLeaf.name.hasSuffix("/leaf.txt"), unwrappedLeaf.name)
        XCTAssertEqual(unwrappedLeaf.fileExtension, "txt")
        XCTAssertEqual(unwrappedLeaf.path, deepPath)
        XCTAssertEqual(PreviewArchiveRow(node: unwrappedLeaf).copyPath, "/" + deepPath)
    }

    func testColumnSortingKeepsFoldersAndUnknownsLastAndBreaksTiesAscending() throws {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_750_000_000)
        let nodes = try ArchiveTree.nodes([
            entry(0, "zeta.txt", size: 20, modified: early),
            entry(1, "alpha.txt", size: 20, modified: early),
            entry(2, "big.png", size: 500, modified: late),
            entry(3, "unknown.bin", size: nil, modified: nil),
            entry(4, "Folder/", directory: true),
        ])

        let sizeAsc = try PreviewArchiveSort(column: .size, ascending: true, foldersFirst: true).sorted(nodes)
        XCTAssertEqual(sizeAsc.map(\.name), ["alpha.txt", "zeta.txt", "big.png", "Folder", "unknown.bin"])

        let sizeDesc = try PreviewArchiveSort(column: .size, ascending: false, foldersFirst: true).sorted(nodes)
        XCTAssertEqual(sizeDesc.map(\.name), ["big.png", "alpha.txt", "zeta.txt", "Folder", "unknown.bin"])

        let dateAsc = try PreviewArchiveSort(column: .modified, ascending: true, foldersFirst: true).sorted(nodes)
        XCTAssertEqual(dateAsc.map(\.name), ["alpha.txt", "zeta.txt", "big.png", "Folder", "unknown.bin"])

        let dateDesc = try PreviewArchiveSort(column: .modified, ascending: false, foldersFirst: true).sorted(nodes)
        XCTAssertEqual(dateDesc.map(\.name), ["big.png", "alpha.txt", "zeta.txt", "Folder", "unknown.bin"])

        let kindDesc = try PreviewArchiveSort(column: .kind, ascending: false, foldersFirst: true).sorted(nodes)
        let txtOrder = kindDesc.map(\.name).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(txtOrder, ["alpha.txt", "zeta.txt"])

        let nameDescFoldersFirst = try PreviewArchiveSort(column: .name, ascending: false, foldersFirst: true)
            .sorted(nodes)
        XCTAssertEqual(nameDescFoldersFirst.first?.name, "Folder")
        XCTAssertEqual(
            nameDescFoldersFirst.dropFirst().map(\.name), ["zeta.txt", "unknown.bin", "big.png", "alpha.txt"])
    }

    func testListingSummarizesItemsAndUsesItemCountAcrossAllNotes() throws {
        let directory = try folder()
        let archive = directory.appending(path: "one.tar")
        try tar(archive, members: "    add('folder/only.bin', 2048)\n")
        let listing = try PreviewArchiveListing(reading: archive, foldersFirst: false)
        XCTAssertEqual(listing.ending, .complete)
        XCTAssertEqual(listing.itemCount, 2)
        XCTAssertEqual(listing.expandedBytes, 2_048)
        XCTAssertFalse(listing.hasEncryptedItems)
        let size = Int64(2_048).formatted(.byteCount(style: .file))
        XCTAssertEqual(listing.summary, String(localized: "\(2) items, \(size) uncompressed"))
        XCTAssertEqual(listing.noteText, listing.summary)

        let damaged = directory.appending(path: "cut.tar")
        try tar(damaged, members: "    add('dir/first.txt', 10)\n    add('dir/second.bin', 8192)\n")
        let raw = try Data(contentsOf: damaged)
        try raw.prefix(512 * 4).write(to: damaged)
        let brokenListing = try PreviewArchiveListing(reading: damaged, foldersFirst: false)
        XCTAssertEqual(brokenListing.ending, .damaged)
        XCTAssertEqual(brokenListing.itemCount, 3)
        XCTAssertEqual(
            brokenListing.noteText,
            String(localized: "This archive is damaged. Showing the first \(3) items."))
    }

    func testEntryLimitKeepsTheFirstEntriesAndUsesVisibleItemCountInNote() throws {
        let archive = try folder().appending(path: "many.tar")
        try tar(
            archive,
            members: "    for number in range(\(ArchiveContents.maximumEntries + 5)):\n"
                + "        add('photos/%03d/%06d.jpg' % (number // 1000, number))\n")
        let listing = try PreviewArchiveListing(reading: archive, foldersFirst: false)
        XCTAssertEqual(listing.ending, .entryLimit)
        XCTAssertEqual(listing.itemCount, ArchiveContents.maximumEntries + 101)
        XCTAssertEqual(
            listing.noteText,
            String(localized: "Showing the first \(ArchiveContents.maximumEntries + 101) items."))
    }

    @MainActor
    func testEncryptedDamagedTimedOutDecodedLimitNamesTooLargeAndUnknownArchivesReachTheirStates() async throws {
        let directory = try folder()
        let locked = try zip(in: directory, password: "secret")
        let listing = try PreviewArchiveListing(reading: locked, foldersFirst: false)
        XCTAssertTrue(listing.hasEncryptedItems)
        XCTAssertEqual(listing.itemCount, 3)

        let damaged = directory.appending(path: "damaged.zip")
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0xEE, count: 200)).write(to: damaged)
        let noise = directory.appending(path: "noise.tar")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: noise)
        let cases: [(URL, PreviewArchiveFailure)] = [
            (damaged, .damaged), (noise, .unsupported),
            (directory.appending(path: "missing.zip"), .unreadable),
        ]
        for (url, expected) in cases {
            let model = PreviewArchiveModel()
            await model.load(url)
            guard case .failed(let failure) = model.phase else { return XCTFail("\(url.lastPathComponent) listed") }
            XCTAssertEqual(failure, expected, url.lastPathComponent)
        }

        XCTAssertEqual(PreviewArchiveFailure(ArchiveContents.Failure.namesTooLarge), .namesTooLarge)
        XCTAssertEqual(PreviewArchiveFailure(ArchiveTreeError.tooLarge), .namesTooLarge)

        let timedOutArchive = directory.appending(path: "slow.tar")
        try tar(timedOutArchive, members: "    add('a.txt')\n")
        let timedOutModel = PreviewArchiveModel { url in
            try PreviewArchiveListing(reading: url, foldersFirst: false, maximumDuration: .zero)
        }
        await timedOutModel.load(timedOutArchive)
        guard case .failed(let timedOutFailure) = timedOutModel.phase else {
            return XCTFail("zero-entry timeout must not show empty archive")
        }
        XCTAssertEqual(timedOutFailure, .timedOut)

        let xattrBomb = directory.appending(path: "xattr-bomb.tar.bz2")
        let bombScript = """
            import bz2, sys, tarfile
            MiB = 1024 * 1024
            def pad(n): return b'\\0' * ((-n) % 512)
            value_len = 16 * MiB - 1
            lines = []
            for number in range(6):
                key = f'SCHILY.xattr.user.a{number:03d}'.encode()
                payload_len = len(key) + value_len + 3
                total = len(str(payload_len)) + payload_len
                while len(str(total)) + payload_len != total:
                    total = len(str(total)) + payload_len
                lines.append((total, key))
            body_len = sum(total for total, _ in lines)
            x_member = tarfile.TarInfo('././@PaxHeader')
            x_member.type = tarfile.XHDTYPE
            x_member.size = body_len
            reg_member = tarfile.TarInfo('after.bin')
            reg_member.size = 0
            compressor = bz2.BZ2Compressor(9)
            chunk = b'a' * value_len
            with open(sys.argv[1], 'wb') as out:
                out.write(compressor.compress(x_member.tobuf(format=tarfile.USTAR_FORMAT)))
                for total, key in lines:
                    out.write(compressor.compress(str(total).encode() + b' ' + key + b'='))
                    out.write(compressor.compress(chunk))
                    out.write(compressor.compress(b'\\n'))
                out.write(compressor.compress(pad(body_len) + reg_member.tobuf(format=tarfile.USTAR_FORMAT) + b'\\0' * 1024))
                out.write(compressor.flush())
            """
        try run("/usr/bin/python3", ["-c", bombScript, xattrBomb.path])
        let bombModel = PreviewArchiveModel()
        await bombModel.load(xattrBomb)
        guard case .failed(let bombFailure) = bombModel.phase else {
            return XCTFail("decoded-limit zero-entry archive must fail with decodedTooLarge")
        }
        XCTAssertEqual(bombFailure, .decodedTooLarge)

        let partialBomb = directory.appending(path: "partial-bomb.tar.bz2")
        let partialScript = """
            import bz2, io, sys, tarfile
            MiB = 1024 * 1024
            with bz2.open(sys.argv[1], 'wb', compresslevel=9) as compressed:
                with tarfile.open(fileobj=compressed, mode='w|') as archive:
                    first = tarfile.TarInfo('huge.bin')
                    first.size = 80 * MiB
                    class Zeros(io.RawIOBase):
                        def __init__(self, remaining): self.remaining = remaining
                        def read(self, size=-1):
                            if self.remaining <= 0: return b''
                            take = self.remaining if size is None or size < 0 else min(self.remaining, size)
                            self.remaining -= take
                            return b'\\0' * take
                    archive.addfile(first, Zeros(first.size))
            """
        try run("/usr/bin/python3", ["-c", partialScript, partialBomb.path])
        let partialListing = try PreviewArchiveListing(reading: partialBomb, foldersFirst: false)
        XCTAssertEqual(partialListing.ending, .decodedLimit)
        XCTAssertEqual(partialListing.itemCount, 1)
        XCTAssertEqual(
            partialListing.noteText,
            String(localized: "This archive is too large to list in full. Showing the first \(1) items."))
    }

    @MainActor
    func testSelectionChangeNeverShowsTheEarlierArchive() async throws {
        let directory = try folder()
        let firstURL = directory.appending(path: "first.tar")
        try tar(firstURL, members: "    add('slow.txt')\n")
        let secondURL = try zip(in: directory)
        let firstListing = try PreviewArchiveListing(reading: firstURL, foldersFirst: false)
        let secondListing = try PreviewArchiveListing(reading: secondURL, foldersFirst: false)

        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<PreviewArchiveListing, any Error>?
            private var started = false

            func waitForStart() async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if started {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        startedContinuation = continuation
                        lock.unlock()
                    }
                }
            }

            func suspendFirst() async throws -> PreviewArchiveListing {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        lock.lock()
                        started = true
                        releaseContinuation = continuation
                        let waiter = startedContinuation
                        startedContinuation = nil
                        lock.unlock()
                        waiter?.resume()
                    }
                } onCancel: {
                    self.finish(with: .failure(CancellationError()))
                }
            }

            func finish(with result: Result<PreviewArchiveListing, any Error>) {
                lock.lock()
                let continuation = releaseContinuation
                releaseContinuation = nil
                lock.unlock()
                continuation?.resume(with: result)
            }
        }

        let cancelGate = Gate()
        let cancelModel = PreviewArchiveModel { url in
            if url == firstURL { return try await cancelGate.suspendFirst() }
            return secondListing
        }
        let cancelled = Task { await cancelModel.load(firstURL) }
        await cancelGate.waitForStart()
        cancelled.cancel()
        await cancelModel.load(secondURL)
        await cancelled.value
        guard case .listed(let afterCancel) = cancelModel.phase else { return XCTFail("second archive not listed") }
        XCTAssertEqual(afterCancel.itemCount, 3)

        let staleGate = Gate()
        let staleModel = PreviewArchiveModel { url in
            if url == firstURL { return try await staleGate.suspendFirst() }
            return secondListing
        }
        let late = Task { await staleModel.load(firstURL) }
        await staleGate.waitForStart()
        await staleModel.load(secondURL)
        staleGate.finish(with: .success(firstListing))
        await late.value
        guard case .listed(let current) = staleModel.phase else { return XCTFail("second archive not listed") }
        XCTAssertEqual(current.itemCount, 3)
    }

    @MainActor
    func testFilterAndSortRunOffMainResetOnLoadAndHonorCancellation() async throws {
        let directory = try folder()
        let archive = directory.appending(path: "tree.tar")
        try tar(
            archive,
            members: """
                    add('Docs/report.txt', 100)
                    add('Media/clip.mp4', 500)
                    add('notes.txt', 20)

                """)
        let model = PreviewArchiveModel(filterDelay: .zero)
        await model.load(archive)
        await model.filter("report")
        XCTAssertTrue(model.isFiltering)
        XCTAssertEqual(model.visibleNodes.map(\.name), ["Docs"])
        XCTAssertEqual(model.visibleNodes.first?.children?.map(\.name), ["report.txt"])
        XCTAssertEqual(model.visibleCount, 2)

        await model.filter("")
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.visibleCount, 5)

        await model.applySort(column: .size, ascending: false)
        XCTAssertEqual(model.visibleNodes.map(\.name), ["notes.txt", "Docs", "Media"])

        await model.filter("txt")
        XCTAssertEqual(model.visibleCount, 3)
        await model.load(archive)
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.sortColumn, .name)
        XCTAssertTrue(model.sortAscending)

        var filterChecks = 0
        XCTAssertThrowsError(
            try ArchiveTree.filtered(model.visibleNodes, query: "a") {
                filterChecks += 1
                if filterChecks >= 2 { throw CancellationError() }
            })
        var sortChecks = 0
        XCTAssertThrowsError(
            try PreviewArchiveSort(column: .size, ascending: false, foldersFirst: true).sorted(model.visibleNodes) {
                sortChecks += 1
                throw CancellationError()
            })
        XCTAssertGreaterThan(sortChecks, 0)
    }

    func testBrowseContentsButtonAppliesOnlyToZIP() {
        let directory = URL(fileURLWithPath: "/tmp")
        XCTAssertTrue(PreviewArchiveViewer.canBrowse(directory.appending(path: "pack.zip")))
        XCTAssertTrue(PreviewArchiveViewer.canBrowse(directory.appending(path: "PACK.ZIP")))
        for name in ["pack.tar", "pack.tar.gz", "pack.tgz", "pack.gz", "pack.bz2", "pack.xz"] {
            XCTAssertFalse(PreviewArchiveViewer.canBrowse(directory.appending(path: name)), name)
        }
    }

    @MainActor
    func testCopyPathCopiesRealRawPathsDisablesOnEmptySpaceAndHandlesCommandCWithCapsLock() throws {
        let directory = try folder()
        let archive = directory.appending(path: "raw-paths.tar")
        let longName = String(repeating: "x", count: 1_500) + ".txt"
        try tar(
            archive,
            members: """
                    add('Docs/bell\\x07name.txt', 5)
                    add('/etc/passwd', 3)
                    add('\(longName)', 2)

                """)
        let listing = try PreviewArchiveListing(reading: archive, foldersFirst: true)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        window.contentView = NSHostingView(
            rootView: PreviewArchiveOutline(roots: listing.nodes, revision: 1, expandsAll: true))
        window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(Self.outline(in: window.contentView) as? PreviewArchiveOutlineView)
        var copied: [[String]] = []
        outline.copyPaths = { rows in copied.append(rows.map(\.copyPath)) }

        let contextItem = try XCTUnwrap(outline.menu?.items.first)
        XCTAssertFalse(outline.validateMenuItem(contextItem))
        outline.copy(contextItem)
        XCTAssertTrue(copied.isEmpty)

        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let editCopy = NSMenuItem(
            title: "Copy", action: #selector(PreviewArchiveOutlineView.copy(_:)), keyEquivalent: "")
        XCTAssertTrue(outline.validateMenuItem(editCopy))
        XCTAssertFalse(outline.validateMenuItem(contextItem))

        window.makeFirstResponder(outline)
        let normalCmdC = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: 8))
        XCTAssertTrue(outline.performKeyEquivalent(with: normalCmdC))

        let capsLockCmdC = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "C", charactersIgnoringModifiers: "C",
                isARepeat: false, keyCode: 8))
        XCTAssertTrue(outline.performKeyEquivalent(with: capsLockCmdC))
        XCTAssertEqual(copied, [["Docs/bell\u{07}name.txt"], ["Docs/bell\u{07}name.txt"]])

        let etcPasswdRow = try XCTUnwrap(outline.item(atRow: 3) as? PreviewArchiveRow)
        XCTAssertEqual(etcPasswdRow.copyPath, "/etc/passwd")
        let longRow = try XCTUnwrap(outline.item(atRow: 4) as? PreviewArchiveRow)
        XCTAssertEqual(longRow.copyPath, longName)
        XCTAssertLessThan(longRow.name.count, longName.count)
    }

    @MainActor
    func testExistingArchiveBrowserSelectsSearchesAndExportsByRealNameWithControlChars() async throws {
        let directory = try folder()
        let archive = directory.appending(path: "control.zip")
        try run(
            "/usr/bin/python3",
            [
                "-c",
                "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w') as z:\n"
                    + "    z.writestr('dir/bell\\x07file.txt', b'payload')\n    z.writestr('dir/plain.txt', b'other')\n",
                archive.path,
            ])
        let engine = try JobEngine(supportDirectory: directory.appending(path: "support"), concurrency: 1)
        let model = ArchiveBrowserPanelModel(source: archive, staging: engine.staging) { _ in }
        let entries = try await model.session.entries()
        let controlEntry = try XCTUnwrap(entries.first(where: { $0.path == "dir/bell\u{07}file.txt" }))
        XCTAssertEqual(ArchiveTree.displayText(controlEntry.path), "dir/bell\u{FFFD}file.txt")

        let tree = try ArchiveTree.nodes(entries)
        let filtered = ArchiveTree.filtered(tree, query: "bell\u{07}")
        XCTAssertEqual(filtered.first?.children?.map(\.path), ["dir/bell\u{07}file.txt"])

        model.load()
        while model.isLoading { await Task.yield() }
        model.selection = ["entry:\(controlEntry.id)"]
        XCTAssertEqual(model.selectedEntries.map(\.path), ["dir/bell\u{07}file.txt"])

        let destination = directory.appending(path: "exported.txt")
        let batch = try await model.session.batch(
            entryIDs: [controlEntry.id], password: nil, to: destination, operation: .archiveBrowse)
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = outcome.outcomes.first else {
            return XCTFail("Browser export failed")
        }
        XCTAssertEqual(outputs, [destination])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "payload")
        await model.close()
    }

    func testJapaneseArchiveItemStringsOmitSpaceBeforeKoumoku() throws {
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        let keys = [
            "%lld items, %@ uncompressed",
            "%lld items",
            "Showing the first %lld items.",
            "Item names are too large to list all items. Showing the first %lld items.",
            "This archive is too large to list in full. Showing the first %lld items.",
            "Listing timed out. Showing the first %lld items.",
            "First %lld items",
            "Timed out · first %lld items",
            "This archive is damaged. Showing the first %lld items.",
            "Damaged · first %lld items",
        ]
        for key in keys {
            let localized = japanese.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertTrue(localized.contains("%lld項目"), "\(key) -> \(localized)")
            XCTAssertFalse(localized.contains(" 項目"), "\(key) -> \(localized)")
        }
        for key in [
            "This archive couldn't be listed in time.",
            "This archive's item names are too large to list.",
            "This archive is too large to list.",
        ] {
            let localized = japanese.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(localized, key, key)
        }
    }

    private func snapshot(_ directory: URL) throws -> [String: Date] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var result: [String: Date] = [:]
        let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys))
        while let url = walk?.nextObject() as? URL {
            result[url.path] = try url.resourceValues(forKeys: keys).contentModificationDate
        }
        return result
    }

    private func quarantineValue(_ url: URL) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 256)
        let size = getxattr(url.path, "com.apple.quarantine", &value, value.count, 0, 0)
        return Array(value.prefix(max(size, 0)))
    }

    @MainActor
    func testQuarantinedArchiveIsListedWithoutWritingAnything() async throws {
        let directory = try folder()
        let archive = try zip(in: directory)
        let quarantine = Array("0081;00000000;Safari;".utf8)
        XCTAssertEqual(setxattr(archive.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0), 0)
        XCTAssertTrue(PreviewTrust.evaluate(archive, trustedFolders: []).restricted)
        XCTAssertEqual(try PreviewKind.inspect(archive), .archive)
        let before = try snapshot(directory)
        let archiveBefore = try FileManager.default.attributesOfItem(atPath: archive.path)

        let model = PreviewArchiveModel()
        await model.load(archive)
        guard case .listed(let listing) = model.phase else { return XCTFail("quarantined archive not listed") }
        XCTAssertEqual(listing.itemCount, 3)

        XCTAssertEqual(try snapshot(directory), before)
        XCTAssertEqual(quarantineValue(archive), quarantine)
        let archiveAfter = try FileManager.default.attributesOfItem(atPath: archive.path)
        XCTAssertEqual(archiveAfter[.modificationDate] as? Date, archiveBefore[.modificationDate] as? Date)
        XCTAssertEqual(archiveAfter[.size] as? Int, archiveBefore[.size] as? Int)
    }

    @MainActor
    func testOutlineExposesLevelsExpansionAndRowDetailsToAccessibility() throws {
        let modified = Date(timeIntervalSince1970: 1_764_000_000)
        let nodes = try ArchiveTree.nodes([
            ArchiveEntry(
                id: 0, path: "Docs/report.pdf", isDirectory: false, size: 2_048, isEncrypted: true,
                modified: modified),
            ArchiveEntry(id: 1, path: "readme.txt", isDirectory: false, size: 5, isEncrypted: false),
        ])
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        window.contentView = NSHostingView(
            rootView: PreviewArchiveOutline(roots: nodes, revision: 1, expandsAll: false))
        window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(Self.outline(in: window.contentView))
        XCTAssertEqual(outline.accessibilityRole(), .outline)
        XCTAssertNil(outline.doubleAction)
        XCTAssertEqual(outline.numberOfRows, 2)
        let docs = try XCTUnwrap(outline.item(atRow: 0))
        XCTAssertTrue(outline.isExpandable(docs))
        XCTAssertFalse(outline.isItemExpanded(docs))
        outline.expandItem(docs)
        XCTAssertTrue(outline.isItemExpanded(docs))
        XCTAssertEqual(outline.numberOfRows, 3)
        XCTAssertEqual(outline.level(forRow: 1), 1)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let label = try XCTUnwrap(cell.accessibilityLabel())
        XCTAssertTrue(label.hasPrefix("report.pdf, "), label)
        XCTAssertTrue(label.contains(Int64(2_048).formatted(.byteCount(style: .file))), label)
        XCTAssertTrue(label.contains(modified.formatted(date: .abbreviated, time: .shortened)), label)
        XCTAssertTrue(label.contains(String(localized: "Encrypted")), label)
        XCTAssertEqual(cell.accessibilityHelp(), "Docs/report.pdf")
        XCTAssertEqual(outline.tableColumns.map(\.isHidden), [false, false, true, true])
    }

    private static func outline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }
}
