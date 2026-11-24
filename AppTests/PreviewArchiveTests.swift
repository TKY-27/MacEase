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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, executable)
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

    private func entry(_ id: Int, _ path: String, directory: Bool = false, size: Int64? = nil) -> ArchiveEntry {
        ArchiveEntry(id: id, path: path, isDirectory: directory, size: size, isEncrypted: false)
    }

    func testEveryArchiveExtensionRoutesToTheContentsListUnlessArchivesAreOff() {
        for suffix in ["zip", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz", "ZIP"] {
            let type = UTType(filenameExtension: suffix)
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix), .archive, suffix)
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix, disabled: [.archive]), .quickLook, suffix)
            XCTAssertEqual(
                PreviewKind.resolve(type: type, extension: suffix, disabled: [.text, .image]), .archive, suffix)
        }
        XCTAssertEqual(PreviewKind.resolve(type: UTType(filenameExtension: "docx"), extension: "docx"), .quickLook)
    }

    func testRealArchiveInspectsAsArchiveAndAMisnamedOneShowsTheMismatch() throws {
        let directory = try folder()
        let archive = try zip(in: directory)
        let (kind, detected) = try PreviewKind.inspectContent(archive)
        XCTAssertEqual(kind, .archive)
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .archive, detected: try XCTUnwrap(detected)), .matches)
        let fake = directory.appending(path: "fake.7z")
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

    func testTreeImpliesFoldersAndKeepsDuplicatesAndSameNamedFileAndFolder() throws {
        let nodes = try ArchiveTree.nodes([
            entry(0, "a/b/c.txt", size: 3), entry(1, "dup.txt", size: 1), entry(2, "dup.txt", size: 2),
            entry(3, "same", size: 4), entry(4, "same/", directory: true), entry(5, "same/inside.txt"),
        ])
        XCTAssertEqual(nodes.map(\.name), ["a", "same", "dup.txt", "dup.txt", "same"])
        XCTAssertEqual(nodes[0].id, "folder:a")
        XCTAssertEqual(nodes[0].children?.first?.children?.first?.path, "a/b/c.txt")
        XCTAssertEqual(nodes[1].children?.map(\.name), ["inside.txt"])
        XCTAssertEqual(Set(nodes[2...3].map(\.id)), ["entry:1", "entry:2"])
        XCTAssertFalse(nodes[4].isDirectory)
        XCTAssertEqual(ArchiveTree.count(nodes), 8)
    }

    func testHostileNamesDisplayAsInertBoundedText() throws {
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
    }

    func testNameOrderFollowsFindersKeepFoldersOnTopSetting() throws {
        let nodes = try ArchiveTree.nodes([
            entry(0, "b.txt"), entry(1, "c/", directory: true), entry(2, "a.txt"), entry(3, "file10.txt"),
            entry(4, "file9.txt"),
        ])
        XCTAssertEqual(
            try PreviewArchiveSort.nameSorted(nodes, foldersFirst: false).map(\.name),
            ["a.txt", "b.txt", "c", "file9.txt", "file10.txt"])
        XCTAssertEqual(
            try PreviewArchiveSort.nameSorted(nodes, foldersFirst: true).map(\.name),
            ["c", "a.txt", "b.txt", "file9.txt", "file10.txt"])
    }

    func testListingSummarizesItemsAndExpandedSize() throws {
        let archive = try folder().appending(path: "one.tar")
        try tar(archive, members: "    add('folder/only.bin', 2048)\n")
        let listing = try PreviewArchiveListing(reading: archive, foldersFirst: false)
        XCTAssertEqual(listing.ending, .complete)
        XCTAssertEqual(listing.entryCount, 1)
        XCTAssertEqual(listing.itemCount, 2)
        XCTAssertEqual(listing.expandedBytes, 2_048)
        XCTAssertFalse(listing.hasEncryptedItems)
        let size = Int64(2_048).formatted(.byteCount(style: .file))
        XCTAssertEqual(listing.summary, String(localized: "\(2) items, \(size) uncompressed"))
    }

    func testEntryLimitKeepsTheFirstEntriesForTheTruncationNote() throws {
        let archive = try folder().appending(path: "many.tar")
        try tar(
            archive,
            members: "    for number in range(\(ArchiveContents.maximumEntries + 5)):\n"
                + "        add('photos/%03d/%06d.jpg' % (number // 1000, number))\n")
        let listing = try PreviewArchiveListing(reading: archive, foldersFirst: false)
        XCTAssertEqual(listing.ending, .entryLimit)
        XCTAssertEqual(listing.entryCount, ArchiveContents.maximumEntries)
        XCTAssertEqual(listing.itemCount, ArchiveContents.maximumEntries + 101)
    }

    @MainActor
    func testEncryptedDamagedAndUnknownArchivesReachTheirStates() async throws {
        let directory = try folder()
        let locked = try zip(in: directory, password: "secret")
        let listing = try PreviewArchiveListing(reading: locked, foldersFirst: false)
        XCTAssertTrue(listing.hasEncryptedItems)
        XCTAssertEqual(listing.entryCount, 3)

        let sealed = directory.appending(path: "sealed.rar")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0, 0, 0x73, 0x80, 0, 0x0D, 0, 0, 0, 0, 0, 0, 0])
            .write(to: sealed)
        let damaged = directory.appending(path: "damaged.zip")
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0xEE, count: 200)).write(to: damaged)
        let noise = directory.appending(path: "noise.7z")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: noise)
        let cases: [(URL, PreviewArchiveFailure)] = [
            (sealed, .passwordProtected), (damaged, .damaged), (noise, .unsupported),
            (directory.appending(path: "missing.zip"), .unreadable),
        ]
        for (url, expected) in cases {
            let model = PreviewArchiveModel()
            await model.load(url)
            guard case .failed(let failure) = model.phase else { return XCTFail("\(url.lastPathComponent) listed") }
            XCTAssertEqual(failure, expected, url.lastPathComponent)
        }
    }

    @MainActor
    func testSelectionChangeNeverShowsTheEarlierArchive() async throws {
        let directory = try folder()
        let slow = directory.appending(path: "slow.tar")
        try tar(slow, members: "    for number in range(60000):\n        add('slow/%06d' % number)\n")
        let quick = try zip(in: directory)
        let model = PreviewArchiveModel()
        let first = Task { await model.load(slow) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let second = Task { await model.load(quick) }
        await first.value
        await second.value
        guard case .listed(let listing) = model.phase else { return XCTFail("quick archive not listed") }
        XCTAssertEqual(listing.entryCount, 3)

        let late = Task { await model.load(slow) }
        try await Task.sleep(for: .milliseconds(20))
        await model.load(quick)
        await late.value
        guard case .listed(let current) = model.phase else { return XCTFail("quick archive not listed") }
        XCTAssertEqual(current.entryCount, 3)
    }

    private func snapshot(_ directory: URL) throws -> [String: Date] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var result: [String: Date] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) {
            result[url.lastPathComponent] = try url.resourceValues(forKeys: Set(keys)).contentModificationDate
        }
        return result
    }

    @MainActor
    func testQuarantinedArchiveIsListedWithoutWritingAnything() async throws {
        let directory = try folder()
        let archive = try zip(in: directory)
        let quarantine = Array("0081;00000000;Safari;".utf8)
        XCTAssertEqual(setxattr(archive.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0), 0)
        XCTAssertTrue(PreviewTrust.evaluate(archive, trustedFolders: []).restricted)
        XCTAssertEqual(try PreviewKind.inspect(archive), .archive)
        let temporary = FileManager.default.temporaryDirectory
        let before = (try snapshot(directory), try snapshot(temporary))
        let archiveBefore = try FileManager.default.attributesOfItem(atPath: archive.path)

        let model = PreviewArchiveModel()
        await model.load(archive)
        guard case .listed(let listing) = model.phase else { return XCTFail("quarantined archive not listed") }
        XCTAssertEqual(listing.entryCount, 3)

        XCTAssertEqual(try snapshot(directory), before.0)
        XCTAssertEqual(try snapshot(temporary), before.1)
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
            rootView: PreviewArchiveOutline(roots: nodes, revision: 1, expandsAll: false, foldersFirst: true))
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
