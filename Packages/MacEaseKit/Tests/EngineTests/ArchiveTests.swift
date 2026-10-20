import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

private let fixedDate = Date(timeIntervalSince1970: 1_000_000_000)
private let quarantine = "com.apple.quarantine"

private func tool(_ path: String, _ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
}

private func extract(_ archive: URL, password: String? = nil) async throws -> BatchOutcome {
    try await runOperation(.archiveExtract, .archive(.extract(password: password)), inputs: [archive])
}

private func outputs(of outcome: BatchOutcome) -> [URL] {
    guard case .succeeded(let outputs, _) = outcome.outcomes.first else { return [] }
    return outputs
}

/// Relative path to contents, `->` marking symlinks.
private func snapshot(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    while let relative = enumerator?.nextObject() as? String {
        let path = root.path + "/" + relative
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            result[relative] = "-> " + (try FileManager.default.destinationOfSymbolicLink(atPath: path))
        case .typeDirectory: result[relative] = "/"
        default: result[relative] = try String(contentsOfFile: path, encoding: .utf8)
        }
    }
    return result
}

@Suite(.serialized) struct ArchiveTests {
    private func makeProject(in parent: URL) throws -> URL {
        let project = folderURL(parent, "Project")
        try makeTree(
            [
                "readme.txt": "hello", "資料/メモ.txt": "日本語", "bin/run.sh": "#!/bin/sh\n", "empty/": "",
                ".DS_Store": "meta", "._readme.txt": "double", "__MACOSX/x": "meta",
            ], in: project)
        let script = project.appending(path: "bin/run.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: script)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: script)
        try FileManager.default.createSymbolicLink(
            atPath: project.appending(path: "hosts").path, withDestinationPath: "/etc/hosts")
        return project
    }

    @Test(arguments: ArchiveFormat.allCases)
    func compressedFoldersExtractBackIdentically(format: ArchiveFormat) async throws {
        let parent = try TestVolume.makeFolder()
        let project = try makeProject(in: parent)

        let compressed = try await runOperation(.folderCompress, .folder(.compress(format)), inputs: [project])
        let archive = try #require(outputs(of: compressed).first)
        #expect(archive.lastPathComponent == "Project.\(format.rawValue)")
        #expect(compressed.record?.items.count == 1)

        let extracted = try #require(outputs(of: try await extract(archive)).first)
        #expect(extracted.lastPathComponent == "Project (2)")
        var expected = try snapshot(project)
        for name in [".DS_Store", "._readme.txt", "__MACOSX", "__MACOSX/x"] { expected.removeValue(forKey: name) }
        #expect(try snapshot(extracted) == expected)
        let script = try FileManager.default.attributesOfItem(atPath: extracted.appending(path: "bin/run.sh").path)
        #expect(script[.posixPermissions] as? Int == 0o750)
        #expect(script[.modificationDate] as? Date == fixedDate)
    }

    @Test func multipleFoldersBecomeOneArchiveNamedAfterTheParent() async throws {
        let parent = folderURL(try TestVolume.makeFolder(), "Shoot")
        try makeTree(["one/a.txt": "a", "two/b.txt": "b"], in: parent)
        var settings = Settings()
        settings.folder.archiveExcludesMacMetadata = false

        let outcome = try await runOperation(
            .folderCompress, .folder(.compress(.zip)),
            inputs: [folderURL(parent, "one"), folderURL(parent, "two")], settings: settings)

        let archive = try #require(outputs(of: outcome).first)
        #expect(archive.deletingLastPathComponent().lastPathComponent == "Shoot")
        #expect(archive.lastPathComponent == "Shoot.zip")
        let extracted = try #require(outputs(of: try await extract(archive)).first)
        #expect(extracted.lastPathComponent == "Shoot")
        #expect(try snapshot(extracted) == ["one": "/", "one/a.txt": "a", "two": "/", "two/b.txt": "b"])
    }

    @Test func zipNamesAreUTF8ForOtherTools() async throws {
        let parent = try TestVolume.makeFolder()
        let project = try makeProject(in: parent)
        let archive = try #require(
            outputs(of: try await runOperation(.folderCompress, .folder(.compress(.zip)), inputs: [project])).first)
        let destination = parent.appending(path: "ditto")

        try tool("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path], in: parent)

        #expect(try String(contentsOf: destination.appending(path: "Project/資料/メモ.txt"), encoding: .utf8) == "日本語")
    }

    @Test func thirdPartyArchivesExtract() async throws {
        let parent = try TestVolume.makeFolder()
        try makeTree(["Album/a.txt": "alpha", "Album/sub/b.txt": "beta", "loose.txt": "loose"], in: parent)
        let commands: [(String, [String], String)] = [
            ("/usr/bin/zip", ["-qr", "zip.zip", "Album"], "zip.zip"),
            ("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "Album", "ditto.zip"], "ditto.zip"),
            ("/usr/bin/tar", ["-cf", "plain.tar", "Album"], "plain.tar"),
            ("/usr/bin/tar", ["-czf", "gzip.tar.gz", "Album"], "gzip.tar.gz"),
            ("/usr/bin/tar", ["-cjf", "bzip.tar.bz2", "Album"], "bzip.tar.bz2"),
            ("/usr/bin/tar", ["-cJf", "xz.tar.xz", "Album"], "xz.tar.xz"),
            ("/usr/bin/bsdtar", ["--format", "7zip", "-cf", "seven.7z", "Album"], "seven.7z"),
        ]
        for (path, arguments, name) in commands {
            try tool(path, arguments, in: parent)
            let extracted = try #require(outputs(of: try await extract(parent.appending(path: name))).first, "\(name)")
            #expect(extracted.lastPathComponent.hasPrefix("Album"), "\(name)")
            #expect(
                try snapshot(extracted) == ["a.txt": "alpha", "sub": "/", "sub/b.txt": "beta"], "\(name)")
        }

        try tool("/usr/bin/zip", ["-q", "two.zip", "loose.txt", "Album/a.txt"], in: parent)
        let mixed = try #require(outputs(of: try await extract(parent.appending(path: "two.zip"))).first)
        #expect(mixed.lastPathComponent == "two")
        #expect(try snapshot(mixed) == ["loose.txt": "loose", "Album": "/", "Album/a.txt": "alpha"])

        try makeTree(["__MACOSX/Album/._a.txt": "resource fork"], in: parent)
        try tool("/usr/bin/zip", ["-qr", "mac.zip", "Album", "__MACOSX"], in: parent)
        let mac = try #require(outputs(of: try await extract(parent.appending(path: "mac.zip"))).first)
        #expect(mac.lastPathComponent.hasPrefix("Album"))
        #expect(try snapshot(mac) == ["a.txt": "alpha", "sub": "/", "sub/b.txt": "beta"])
    }

    @Test(arguments: ["gz", "bz2", "xz"])
    func singleCompressedFilesDecompressBesideTheArchive(pathExtension: String) async throws {
        let parent = try TestVolume.makeFolder()
        try makeTree(["notes.txt": "compressed text"], in: parent)
        let compressors = [
            "gz": ("/usr/bin/gzip", ["-k", "notes.txt"]),
            "bz2": ("/usr/bin/bzip2", ["-k", "notes.txt"]),
            "xz": ("/usr/bin/bsdtar", ["--format", "raw", "-cJf", "notes.txt.xz", "notes.txt"]),
        ]
        let (compressor, arguments) = try #require(compressors[pathExtension])
        try tool(compressor, arguments, in: parent)
        try FileManager.default.removeItem(at: parent.appending(path: "notes.txt"))

        let output = try #require(
            outputs(of: try await extract(parent.appending(path: "notes.txt.\(pathExtension)"))).first)

        #expect(output.lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: output, encoding: .utf8) == "compressed text")
    }

    @Test(arguments: ["../escape.txt", "/tmp/macease-absolute-\(UUID().uuidString).txt", "ok/../../escape.txt"])
    func traversalAndAbsolutePathsAreRefused(entryName: String) async throws {
        let parent = try TestVolume.makeFolder()
        let inner = folderURL(parent, "inner")
        try makeTree(["payload.txt": "evil"], in: inner)
        let substitution = ",^payload.txt$,\(entryName),"
        try tool("/usr/bin/bsdtar", ["-cPf", "../evil.tar", "-s", substitution, "payload.txt"], in: inner)

        let outcome = try await extract(parent.appending(path: "evil.tar"))

        #expect(outcome.outcomes == [.failed(.invalidInput(.unsafeArchivePath(entryName)))])
        #expect(try listing(parent) == ["evil.tar", "inner"])
        #expect(
            !FileManager.default.fileExists(
                atPath: parent.deletingLastPathComponent().appending(path: "escape.txt").path))
        #expect(!entryName.hasPrefix("/") || !FileManager.default.fileExists(atPath: entryName))
    }

    @Test func writingThroughAnExtractedSymlinkIsRefused() async throws {
        let parent = try TestVolume.makeFolder()
        let target = folderURL(parent, "target")
        let source = folderURL(parent, "source")
        try makeTree(["target/": "", "source/real/pwned.txt": "evil"], in: parent)
        try FileManager.default.createSymbolicLink(
            atPath: source.appending(path: "link").path, withDestinationPath: target.path)
        try tool(
            "/usr/bin/bsdtar", ["-cf", "../link.tar", "-s", ",^real/,link/,", "link", "real/pwned.txt"], in: source)

        let outcome = try await extract(parent.appending(path: "link.tar"))

        guard case .failed = try #require(outcome.outcomes.first) else {
            Issue.record("expected the symlink write to fail")
            return
        }
        #expect(try listing(target).isEmpty)
        #expect(try listing(parent) == ["link.tar", "source", "target"])
    }

    @Test func passwordProtectedZipAsksThenExtracts() async throws {
        let parent = try TestVolume.makeFolder()
        try makeTree(["Secret/plan.txt": "launch at dawn"], in: parent)
        try tool("/usr/bin/zip", ["-qr", "-P", "correct horse", "secret.zip", "Secret"], in: parent)
        let archive = parent.appending(path: "secret.zip")

        #expect(try await extract(archive).outcomes == [.failed(.invalidInput(.passwordRequired))])
        #expect(try await extract(archive, password: "wrong").outcomes == [.failed(.invalidInput(.wrongPassword))])
        let extracted = try #require(outputs(of: try await extract(archive, password: "correct horse")).first)
        #expect(try snapshot(extracted) == ["plan.txt": "launch at dawn"])
        #expect(try listing(parent) == ["Secret", "Secret (2)", "secret.zip"])
    }

    @Test func quarantineFollowsExtractedFiles() async throws {
        let parent = try TestVolume.makeFolder()
        try makeTree(
            ["Download/app.sh": "#!/bin/sh\n", "Download/locked.txt": "ro", "precious.txt": "mine"], in: parent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: parent.appending(path: "Download/locked.txt").path)
        let precious = parent.appending(path: "precious.txt").path
        let link = parent.appending(path: "Download/link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: precious)
        #expect(lchmod(link, 0o444) == 0)
        let preciousMode = try FileManager.default.attributesOfItem(atPath: precious)[.posixPermissions] as? Int
        try tool("/usr/bin/tar", ["-cf", "download.tar", "Download"], in: parent)
        let archive = parent.appending(path: "download.tar")
        let value = Array("0081;00000000;Test;".utf8)
        #expect(setxattr(archive.path, quarantine, value, value.count, 0, 0) == 0)
        try FileManager.default.removeItem(at: parent.appending(path: "Download/locked.txt"))
        try FileManager.default.removeItem(at: parent.appending(path: "Download"))

        let extracted = try #require(outputs(of: try await extract(archive)).first)

        for name in ["", "/app.sh", "/locked.txt"] {
            #expect(getxattr(extracted.path + name, quarantine, nil, 0, 0, 0) == value.count, "\(name)")
        }
        let locked = try FileManager.default.attributesOfItem(atPath: extracted.path + "/locked.txt")
        #expect(locked[.posixPermissions] as? Int == 0o444)
        #expect(try FileManager.default.attributesOfItem(atPath: precious)[.posixPermissions] as? Int == preciousMode)
        #expect(getxattr(precious, quarantine, nil, 0, 0, 0) < 0)
    }
}
