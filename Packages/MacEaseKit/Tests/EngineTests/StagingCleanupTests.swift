import Foundation
import Testing

@testable import Engine

@Suite(.serialized) struct StagingCleanupTests {
    @Test func failedRemovalSurvivesNewStagingAndRepeatedSweeps() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StagingCleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let source = root.appending(path: "source.txt")
        try Data("source".utf8).write(to: source)
        let registry = root.appending(path: "staging.json")
        let staging = StagingArea(supportDirectory: root)
        let failed = try staging.makeDirectory(for: source)
        defer {
            if FileManager.default.fileExists(atPath: failed.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: failed) }
            }
        }
        let locked = failed.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: locked.appending(path: "child.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            if FileManager.default.fileExists(atPath: locked.path) {
                #expect(throws: Never.self) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
                }
            }
        }

        staging.remove(failed)
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(try registeredPaths(registry) == [failed.path])

        let active = try staging.makeDirectory(for: source)
        defer {
            if FileManager.default.fileExists(atPath: active.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: active) }
            }
        }
        #expect(try registeredPaths(registry) == [failed.path, active.path])
        staging.removeStale()
        staging.removeStale()
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(try registeredPaths(registry) == [failed.path, active.path])

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        staging.removeStale()
        #expect(!FileManager.default.fileExists(atPath: failed.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(try registeredPaths(registry) == [active.path])
        staging.remove(active)
        #expect(try registeredPaths(registry).isEmpty)
    }

    @Test func failedStartupSweepRetriesAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StagingCleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let source = root.appending(path: "source.txt")
        try Data("source".utf8).write(to: source)
        let registry = root.appending(path: "staging.json")
        let stale = try StagingArea(supportDirectory: root).makeDirectory(for: source)
        defer {
            if FileManager.default.fileExists(atPath: stale.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: stale) }
            }
        }
        let locked = stale.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: locked.appending(path: "child.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            if FileManager.default.fileExists(atPath: locked.path) {
                #expect(throws: Never.self) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
                }
            }
        }

        StagingArea(supportDirectory: root).removeStale()
        #expect(FileManager.default.fileExists(atPath: stale.path))
        #expect(try registeredPaths(registry) == [stale.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        StagingArea(supportDirectory: root).removeStale()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try registeredPaths(registry).isEmpty)
    }

    @Test func missingStagingDirectoryIsForgotten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StagingCleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let source = root.appending(path: "source.txt")
        try Data("source".utf8).write(to: source)
        let staging = StagingArea(supportDirectory: root)
        let missing = try staging.makeDirectory(for: source)
        try FileManager.default.removeItem(at: missing)

        staging.remove(missing)

        #expect(try registeredPaths(root.appending(path: "staging.json")).isEmpty)
    }

    @Test(arguments: [false, true])
    func unreadableRegistryBlocksNewStagingUntilItCanBeLoaded(_ lockSupportDirectory: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "StagingCleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let source = root.appending(path: "source.txt")
        try Data("source".utf8).write(to: source)
        let support = root.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let registry = support.appending(path: "staging.json")
        let stale = try StagingArea(supportDirectory: support).makeDirectory(for: source)
        defer {
            if FileManager.default.fileExists(atPath: stale.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: stale) }
            }
        }
        let originalRegistry = try Data(contentsOf: registry)
        let lockedPath = lockSupportDirectory ? support : registry
        let originalPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: lockedPath.path)[.posixPermissions] as? Int)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedPath.path)
        defer {
            #expect(throws: Never.self) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: originalPermissions], ofItemAtPath: lockedPath.path)
            }
        }

        let restarted = StagingArea(supportDirectory: support)
        restarted.removeStale()
        var unexpectedDirectory: URL?
        defer {
            if let unexpectedDirectory, FileManager.default.fileExists(atPath: unexpectedDirectory.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: unexpectedDirectory) }
            }
        }
        #expect(throws: (any Error).self) { unexpectedDirectory = try restarted.makeDirectory(for: source) }
        try FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions], ofItemAtPath: lockedPath.path)
        #expect(try Data(contentsOf: registry) == originalRegistry)
        #expect(FileManager.default.fileExists(atPath: stale.path))

        let active = try restarted.makeDirectory(for: source)
        defer {
            if FileManager.default.fileExists(atPath: active.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: active) }
            }
        }
        #expect(try registeredPaths(registry) == [stale.path, active.path])
        restarted.removeStale()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(try registeredPaths(registry) == [active.path])
        restarted.remove(active)
        #expect(try registeredPaths(registry).isEmpty)
    }

    private func registeredPaths(_ registry: URL) throws -> Set<String> {
        Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)))
    }
}
