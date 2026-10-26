import Darwin
import Foundation
import Testing

@testable import Formats

@Suite(.serialized) struct ArchiveBrowserZIPTests {
    private struct Member {
        let name: String
        let payload: [UInt8]
        let checksum: UInt32
    }

    private func fixture(_ members: [Member]) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zip-browser-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appending(path: "sample.zip")
        var local = Data()
        var central = Data()
        for member in members {
            let name = Array(member.name.utf8)
            let offset = UInt32(local.count)
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(20))
            local.appendLE(UInt16(0x0800))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(member.checksum)
            local.appendLE(UInt32(member.payload.count))
            local.appendLE(UInt32(member.payload.count))
            local.appendLE(UInt16(name.count))
            local.appendLE(UInt16(0))
            local.append(contentsOf: name)
            local.append(contentsOf: member.payload)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(member.checksum)
            central.appendLE(UInt32(member.payload.count))
            central.appendLE(UInt32(member.payload.count))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(contentsOf: name)
        }
        let centralOffset = UInt32(local.count)
        local.append(central)
        local.appendLE(UInt32(0x06054b50))
        local.appendLE(UInt16(0))
        local.appendLE(UInt16(0))
        local.appendLE(UInt16(members.count))
        local.appendLE(UInt16(members.count))
        local.appendLE(UInt32(central.count))
        local.appendLE(centralOffset)
        local.appendLE(UInt16(0))
        try local.write(to: archive)
        return (folder, archive)
    }

    private func appendComment(_ comment: [UInt8], to archive: URL) throws {
        var bytes = try Data(contentsOf: archive)
        let end = bytes.count - 22
        bytes[end + 20] = UInt8(truncatingIfNeeded: comment.count)
        bytes[end + 21] = UInt8(truncatingIfNeeded: comment.count >> 8)
        bytes.append(contentsOf: comment)
        try bytes.write(to: archive)
    }

    private func generatedFixture(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zip-generated-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appending(path: "generated.zip")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c", "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w', allowZip64=True) as archive:\n" + body,
            archive.path,
        ]
        python.standardError = FileHandle.nullDevice
        try python.run()
        python.waitUntilExit()
        guard python.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return archive
    }

    @Test func validZIP64CountListsEveryMember() throws {
        let archive = try generatedFixture(
            "    for number in range(65536):\n        archive.writestr(str(number), b'')\n")
        let listed = try ArchiveBrowserZIP.list(archive)
        #expect(listed.count == 65_536)
        #expect(listed.first?.id == 0)
        #expect(listed.last?.id == 65_535)
    }

    @Test func entryBudgetRejects100001Members() throws {
        let archive = try generatedFixture(
            "    for number in range(100001):\n        archive.writestr(str(number), b'')\n")
        #expect(throws: ZIPBrowserError.tooManyEntries) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func nameBudgetRejectsOver32MiB() throws {
        let archive = try generatedFixture(
            "    for number in range(517):\n        archive.writestr('x' * 65000 + str(number), b'')\n")
        #expect(throws: ZIPBrowserError.namesTooLarge) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func lyingLowEOCDCountIsRejectedBeforeListing() throws {
        let (_, archive) = try fixture([
            Member(name: "first", payload: [], checksum: 0),
            Member(name: "second", payload: [], checksum: 0),
        ])
        var bytes = try Data(contentsOf: archive)
        let end = bytes.count - 22
        bytes[end + 8] = 1
        bytes[end + 10] = 1
        try bytes.write(to: archive)
        #expect(throws: ZIPBrowserError.invalidZIP) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func zip64DeclaredCountRejectsBeforeListing() throws {
        let (_, archive) = try fixture([])
        var bytes = Data()
        bytes.appendLE(UInt32(0x06064b50))
        bytes.appendLE(UInt64(44))
        bytes.appendLE(UInt16(45))
        bytes.appendLE(UInt16(45))
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt64(100_001))
        bytes.appendLE(UInt64(100_001))
        bytes.appendLE(UInt64(0))
        bytes.appendLE(UInt64(0))
        bytes.appendLE(UInt32(0x07064b50))
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt64(0))
        bytes.appendLE(UInt32(1))
        bytes.appendLE(UInt32(0x06054b50))
        bytes.appendLE(UInt16(0))
        bytes.appendLE(UInt16(0))
        bytes.appendLE(UInt16.max)
        bytes.appendLE(UInt16.max)
        bytes.appendLE(UInt32.max)
        bytes.appendLE(UInt32.max)
        bytes.appendLE(UInt16(0))
        try bytes.write(to: archive)
        #expect(throws: ZIPBrowserError.tooManyEntries) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func commentsCountTowardMetadataBudget() throws {
        let archive = try generatedFixture(
            "    for number in range(513):\n        entry = zipfile.ZipInfo(str(number))\n        entry.comment = b'x' * 65500\n        archive.writestr(entry, b'')\n"
        )
        #expect(throws: ZIPBrowserError.namesTooLarge) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func cancellationStopsDirectoryPreflight() throws {
        let archive = try generatedFixture(
            "    for number in range(1000):\n        archive.writestr(str(number), b'')\n")
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ArchiveBrowserZIP.list(archive) {
                checks += 1
                if checks == 100 { throw CancellationError() }
            }
        }
        #expect(checks == 100)
    }

    @Test func emptyZIPListsSuccessfully() throws {
        let (_, archive) = try fixture([])
        #expect(try ArchiveBrowserZIP.list(archive).isEmpty)
    }

    @Test func ordinaryZIPCommentListsSuccessfully() throws {
        let (_, archive) = try fixture([Member(name: "one.txt", payload: [], checksum: 0)])
        try appendComment(Array("ordinary comment".utf8), to: archive)
        #expect(try ArchiveBrowserZIP.list(archive).map(\.path) == ["one.txt"])
    }

    @Test func EOCDSignatureInsideCommentIsRejected() throws {
        let (_, archive) = try fixture([Member(name: "one.txt", payload: [], checksum: 0)])
        try appendComment([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0x41, count: 22), to: archive)
        #expect(throws: ZIPBrowserError.invalidZIP) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func macMetadataEntriesKeepDistinctOrdinals() throws {
        let (folder, archive) = try fixture([
            Member(name: "__MACOSX/._hidden.txt", payload: [65], checksum: 0xd3d99e8b),
            Member(name: "visible.txt", payload: [66], checksum: 0x4ad0cf31),
        ])
        let listed = try ArchiveBrowserZIP.list(archive)
        #expect(listed.map(\.id) == [0, 1])
        #expect(listed.map(\.path) == ["__MACOSX/._hidden.txt", "visible.txt"])
        let hidden = folder.appending(path: "hidden")
        let visible = folder.appending(path: "visible")
        try ArchiveBrowserZIP.extract(
            archive, selections: [0: hidden, 1: visible], password: nil, limit: 2)
        #expect(try Data(contentsOf: hidden) == Data([65]))
        #expect(try Data(contentsOf: visible) == Data([66]))
    }

    @Test func multipleSelectedMembersSkipUnselectedContent() throws {
        let (folder, archive) = try fixture([
            Member(name: "a.txt", payload: [65], checksum: 0xd3d99e8b),
            Member(name: "b.txt", payload: [66], checksum: 0x4ad0cf31),
            Member(name: "empty.txt", payload: [], checksum: 0),
        ])
        let first = folder.appending(path: "first")
        let empty = folder.appending(path: "empty")
        try ArchiveBrowserZIP.extract(
            archive, selections: [0: first, 2: empty], password: nil, limit: 1)
        #expect(try Data(contentsOf: first) == Data([65]))
        #expect(try Data(contentsOf: empty).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "b.txt").path))
    }

    @Test func preservesJapanesePathsAndDuplicateOrdinals() throws {
        let (folder, archive) = try fixture([
            Member(name: "資料/一.txt", payload: [65], checksum: 0xd3d99e8b),
            Member(name: "資料/一.txt", payload: [66], checksum: 0x4ad0cf31),
        ])
        let entries = try ArchiveBrowserZIP.list(archive)
        #expect(entries.map(\.id) == [0, 1])
        #expect(entries.map(\.path) == ["資料/一.txt", "資料/一.txt"])
        let second = folder.appending(path: "second.txt")
        try ArchiveBrowserZIP.extract(archive, ordinal: 1, to: second, password: nil, limit: 10)
        #expect(try Data(contentsOf: second) == Data([66]))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "資料").path))
    }

    @Test func acceptsDeepValidPathAndRejectsMoreThan256Components() throws {
        let accepted = Array(repeating: "folder", count: 63).joined(separator: "/") + "/a.txt"
        let (_, validZIP) = try fixture([Member(name: accepted, payload: [65], checksum: 0xd3d99e8b)])
        #expect(try ArchiveBrowserZIP.list(validZIP).map(\.path) == [accepted])
        let rejected = Array(repeating: "folder", count: 256).joined(separator: "/") + "/a.txt"
        let (_, invalidZIP) = try fixture([Member(name: rejected, payload: [65], checksum: 0xd3d99e8b)])
        #expect(throws: ZIPBrowserError.pathTooDeep) { try ArchiveBrowserZIP.list(invalidZIP) }
    }

    @Test func rejectsTraversalBeforeTreeConstruction() throws {
        let (_, archive) = try fixture([Member(name: "../escape", payload: [65], checksum: 0xd3d99e8b)])
        #expect(throws: ZIPBrowserError.unsafeEntry) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func corruptCRCDoesNotProduceSuccessfulExtraction() throws {
        let (folder, archive) = try fixture([Member(name: "bad.txt", payload: [65], checksum: 0)])
        let output = folder.appending(path: "bad.txt")
        #expect(throws: ZIPBrowserError.corruptEntry) {
            try ArchiveBrowserZIP.extract(archive, ordinal: 0, to: output, password: nil, limit: 10)
        }
    }

    @Test func nonregularSourcesAreRejectedWithoutBlocking() throws {
        let (folder, archive) = try fixture([])
        let pipe = folder.appending(path: "pipe.zip")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: ZIPBrowserError.invalidZIP) { try ArchiveBrowserZIP.list(pipe) }
        #expect(start.duration(to: clock.now) < .seconds(2))
        let alias = folder.appending(path: "alias.zip")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: archive)
        #expect(throws: ZIPBrowserError.invalidZIP) { try ArchiveBrowserZIP.list(alias) }
    }

    @Test func linkEntriesAreRejectedDuringListing() throws {
        let (_, archive) = try fixture([Member(name: "link", payload: [], checksum: 0)])
        var bytes = try Data(contentsOf: archive)
        let central = 30 + "link".utf8.count
        bytes[central + 5] = 3
        let mode = UInt32(0o120777) << 16
        for index in 0..<4 { bytes[central + 38 + index] = UInt8(truncatingIfNeeded: mode >> (index * 8)) }
        try bytes.write(to: archive)
        #expect(throws: ZIPBrowserError.unsupportedEntry) { try ArchiveBrowserZIP.list(archive) }
    }

    @Test func unsupportedCompressionMethodFailsClosed() throws {
        let (folder, archive) = try fixture([Member(name: "a.txt", payload: [65], checksum: 0xd3d99e8b)])
        var bytes = try Data(contentsOf: archive)
        bytes[8] = 99
        bytes[30 + "a.txt".utf8.count + 1 + 10] = 99
        try bytes.write(to: archive)
        #expect(throws: ZIPBrowserError.self) {
            _ = try ArchiveBrowserZIP.list(archive)
            try ArchiveBrowserZIP.extract(
                archive, ordinal: 0, to: folder.appending(path: "output"), password: nil, limit: 10)
        }
    }

    @Test func encryptedZIPRequiresCorrectPassword() throws {
        let (folder, _) = try fixture([])
        let input = folder.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: input)
        let archive = folder.appending(path: "encrypted.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-P", "fixture-pass", archive.path, "secret.txt"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        let listed = try ArchiveBrowserZIP.list(archive)
        #expect(listed.count == 1)
        #expect(listed[0].isEncrypted)
        #expect(throws: ZIPBrowserError.passwordRequired) {
            try ArchiveBrowserZIP.extract(
                archive, ordinal: 0, to: folder.appending(path: "no-password"),
                password: nil, limit: 100)
        }
        #expect(throws: ZIPBrowserError.wrongPassword) {
            try ArchiveBrowserZIP.extract(
                archive, ordinal: 0, to: folder.appending(path: "wrong-password"),
                password: "wrong", limit: 100)
        }
        let output = folder.appending(path: "correct-password")
        try ArchiveBrowserZIP.extract(archive, ordinal: 0, to: output, password: "fixture-pass", limit: 100)
        #expect(try String(contentsOf: output, encoding: .utf8) == "secret")
    }

    @Test func declaredSizeCannotExceedSelectionCap() throws {
        let (folder, archive) = try fixture([Member(name: "a.txt", payload: [65], checksum: 0xd3d99e8b)])
        #expect(throws: ZIPBrowserError.selectionTooLarge) {
            try ArchiveBrowserZIP.extract(
                archive, ordinal: 0, to: folder.appending(path: "out.txt"), password: nil, limit: 0)
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(truncatingIfNeeded: value))
        appendLE(UInt16(truncatingIfNeeded: value >> 16))
    }

    mutating func appendLE(_ value: UInt64) {
        appendLE(UInt32(truncatingIfNeeded: value))
        appendLE(UInt32(truncatingIfNeeded: value >> 32))
    }
}
