import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct MoveMetadataTests {
    private var attributes: [String: Data] {
        get throws {
            [
                "com.apple.metadata:_kMDItemUserTags": try PropertyListSerialization.data(
                    fromPropertyList: ["Important\n6", "Fixture\n0"], format: .binary, options: 0),
                "com.apple.metadata:kMDItemFinderComment": try PropertyListSerialization.data(
                    fromPropertyList: "Fixture Finder comment", format: .binary, options: 0),
                "com.apple.quarantine": Data("0081;665e4980;MacEaseTests;".utf8),
                "io.github.tky27.MacEase.fixture": Data([0, 1, 255]),
            ]
        }
    }

    private func metadata(_ url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw POSIXError(.EIO) }
        return result
    }

    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw POSIXError(.EIO) }
        defer { acl_free(text) }
        return String(cString: text)
    }

    private func setMetadata(_ url: URL) throws {
        for (name, contents) in try attributes {
            let status = contents.withUnsafeBytes {
                setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            try #require(status == 0)
        }
        if try metadata(url).st_mode & S_IFMT == S_IFREG {
            let resourceFork = Data("resource fork payload".utf8)
            try #require(
                resourceFork.withUnsafeBytes {
                    setxattr(url.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                } == 0)
        }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-h", "+a", "user:\(NSUserName()) allow readattr,readextattr,readsecurity", url.path]
        try chmod.run()
        chmod.waitUntilExit()
        try #require(chmod.terminationStatus == 0)
        try #require(lchmod(url.path, 0o750) == 0)
        var creation = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
        var requested = attrlist()
        requested.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        requested.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        try #require(
            setattrlist(url.path, &requested, &creation, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0)
        let dates = [timespec(tv_sec: 1_700_000_100, tv_nsec: 0), timespec(tv_sec: 1_700_000_100, tv_nsec: 0)]
        try #require(utimensat(AT_FDCWD, url.path, dates, AT_SYMLINK_NOFOLLOW) == 0)
        try #require(lchflags(url.path, UInt32(UF_HIDDEN)) == 0)
    }

    private func expectMetadata(_ url: URL, original: stat, originalACL: String) throws {
        let actual = try metadata(url)
        #expect(actual.st_mode == original.st_mode)
        #expect(actual.st_uid == original.st_uid)
        #expect(actual.st_gid == original.st_gid)
        #expect(actual.st_flags == original.st_flags)
        #expect(actual.st_birthtimespec.tv_sec == 1_700_000_000)
        #expect(actual.st_birthtimespec.tv_nsec == 0)
        #expect(actual.st_mtimespec.tv_sec == 1_700_000_100)
        #expect(actual.st_mtimespec.tv_nsec == 0)
        #expect(try aclText(url) == originalACL)
        var expected = try attributes
        if original.st_mode & S_IFMT == S_IFREG {
            expected["com.apple.ResourceFork"] = Data("resource fork payload".utf8)
        }
        for (name, contents) in expected {
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            try #require(size == contents.count)
            var copied = Data(count: size)
            #expect(
                copied.withUnsafeMutableBytes {
                    getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                } == size)
            #expect(copied == contents)
        }
    }

    @Test func crossVolumeMoveAndUndoPreserveMetadataAtEveryLevel() async throws {
        let boot = FileManager.default.temporaryDirectory.appending(path: "MacEaseMetadata-\(UUID().uuidString)")
        TestTemporaryFolders.register(boot)
        let disk = try TestVolume.makeFolder()
        let source = boot.appending(path: "source")
        let tree = source.appending(path: "tree")
        let nested = tree.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = source.appending(path: "file")
        let child = nested.appending(path: "child")
        try Data("file bytes".utf8).write(to: file)
        try Data("nested bytes".utf8).write(to: child)
        let topLink = source.appending(path: "link")
        let childLink = nested.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: topLink.path, withDestinationPath: "/missing/target")
        try FileManager.default.createSymbolicLink(atPath: childLink.path, withDestinationPath: "child")
        let entries = [file, topLink, child, childLink, nested, tree]
        for entry in entries { try setMetadata(entry) }
        let snapshots = try entries.map { (try metadata($0), try aclText($0)) }
        let engine = try JobEngine(supportDirectory: boot.appending(path: "support"), concurrency: 1)
        let cut = try [file, topLink, tree].map(MoveItem.capture)
        let request = OperationRequest(
            op: .filesMove, options: .move(MovePlan(items: cut, destination: disk)), inputs: cut.map(\.url))
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        #expect(
            outcome.outcomes
                == [file, topLink, tree].map {
                    .succeeded(outputs: [disk.appending(path: $0.lastPathComponent)], warnings: [])
                })
        for (index, entry) in entries.enumerated() {
            let relative = String(entry.path.dropFirst(source.path.count + 1))
            try expectMetadata(
                disk.appending(path: relative), original: snapshots[index].0, originalACL: snapshots[index].1)
        }
        let record = try #require(outcome.record)
        #expect(try await engine.undo(record.id) == [.restored, .restored, .restored])
        for (index, entry) in entries.enumerated() {
            try expectMetadata(entry, original: snapshots[index].0, originalACL: snapshots[index].1)
        }
    }
}
