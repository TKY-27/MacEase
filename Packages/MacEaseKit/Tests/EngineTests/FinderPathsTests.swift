import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct FinderPathsTests {
    private func runShell(_ command: String) throws -> String {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func shellQuotedExecutablePathStillExecutesAsACommand() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseShell-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "safe example")
        try Data("#!/bin/sh\nprintf executed".utf8).write(to: executable)
        try #require(chmod(executable.path, 0o700) == 0)
        #expect(try runShell(FinderPaths.copyText(for: [executable], format: .shellQuoted)) == "executed")
    }

    @Test func copyTextOutputsPosixPathsPerLineInSelectionOrder() {
        let selection = [
            URL(fileURLWithPath: "/Users/me/z.txt", isDirectory: false),
            URL(fileURLWithPath: "/Users/me/Folder A", isDirectory: true),
            URL(fileURLWithPath: "/Users/me/書類/a.md", isDirectory: false),
        ]
        #expect(
            FinderPaths.copyText(for: selection, format: .posix)
                == "/Users/me/z.txt\n/Users/me/Folder A\n/Users/me/書類/a.md")
        #expect(FinderPaths.copyText(for: [], format: .posix).isEmpty)
        #expect(FinderPaths.copyText(for: [], format: .shellQuoted).isEmpty)
    }

    @Test(arguments: [
        "/Users/me/simple_file-1.txt",
        "/Users/me/My Documents/space name.txt",
        "/Users/me/it's a 'quoted' \"file\".txt",
        "/Users/me/line1\nline2\nline3.txt",
        "/Users/me/日本語/ファイル🎉.md",
        "/Users/me/$HOME $(uname) `id` \\ * ? [a] ; & | (sub)",
        "'",
        "",
    ])
    func shellQuotedRoundTripsExactlyThroughPOSIXShell(path: String) throws {
        let quoted = FinderPaths.shellQuoted(path)
        let echoed = try runShell("printf %s \(quoted)")
        #expect(echoed == path)
    }

    @Test func shellQuotedSelectionPassesMultipleAwkwardPathsAsSeparateArguments() throws {
        let paths = [
            "/tmp/a b.txt",
            "/tmp/o'brien \"doc\".md",
            "/tmp/two\nlines.txt",
            "/tmp/日本語フォルダ/メモ.txt",
        ]
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
        let joined = FinderPaths.copyText(for: urls, format: .shellQuoted)
        let evaluated = try runShell("printf '%s\\0' \(joined)")
        let parsed = evaluated.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(parsed == paths)
    }

    @Test func terminalDirectoryResolvesFolderPackageFileCommonParentAndTargetFallback() {
        let folder = URL(fileURLWithPath: "/Users/me/Projects/MacEase", isDirectory: true)
        let dottedFolder = URL(fileURLWithPath: "/Users/me/Photos 2024.v2", isDirectory: true)
        let appBundle = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let rtfdPackage = URL(fileURLWithPath: "/Users/me/Docs/Notes.rtfd", isDirectory: true)
        let xcodeProject = URL(fileURLWithPath: "/Users/me/Work/App.xcodeproj", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/me/Docs/readme.md", isDirectory: false)
        let siblingFile = URL(fileURLWithPath: "/Users/me/Docs/notes.txt", isDirectory: false)
        let siblingFolder = URL(fileURLWithPath: "/Users/me/Docs/Archive", isDirectory: true)
        let nestedFile = URL(fileURLWithPath: "/Users/me/Docs/Sub/deep.txt", isDirectory: false)
        let root = URL(fileURLWithPath: "/", isDirectory: true)

        #expect(FinderPaths.terminalDirectory(for: [folder])?.path == "/Users/me/Projects/MacEase")
        #expect(FinderPaths.terminalDirectory(for: [dottedFolder])?.path == "/Users/me/Photos 2024.v2")
        #expect(FinderPaths.terminalDirectory(for: [appBundle])?.path == "/Applications")
        #expect(FinderPaths.terminalDirectory(for: [rtfdPackage])?.path == "/Users/me/Docs")
        #expect(FinderPaths.terminalDirectory(for: [xcodeProject])?.path == "/Users/me/Work")
        #expect(FinderPaths.terminalDirectory(for: [file])?.path == "/Users/me/Docs")
        #expect(FinderPaths.terminalDirectory(for: [root])?.path == "/")

        #expect(FinderPaths.terminalDirectory(for: [file, siblingFile])?.path == "/Users/me/Docs")
        #expect(FinderPaths.terminalDirectory(for: [siblingFolder, file])?.path == "/Users/me/Docs")
        #expect(FinderPaths.terminalDirectory(for: [file, nestedFile])?.path == "/Users/me/Docs")
        #expect(FinderPaths.terminalDirectory(for: [folder, folder])?.path == "/Users/me/Projects/MacEase")
        #expect(FinderPaths.terminalDirectory(for: [], targetFolder: folder)?.path == "/Users/me/Projects/MacEase")
        #expect(FinderPaths.terminalDirectory(for: [], targetFolder: appBundle)?.path == "/Applications")
        #expect(FinderPaths.terminalDirectory(for: [], targetFolder: nil) == nil)
    }

    @Test func copyPathOperationRunsThroughPlannerAndJobEngineForFilesAndFolders() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEasePaths-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let settings = Settings()
        let selection = [
            URL(fileURLWithPath: "/Users/me/My Folder", isDirectory: true),
            URL(fileURLWithPath: "/Users/me/it's.txt", isDirectory: false),
        ]

        #expect(OperationPlanner.options(for: .anyCopyPath, preset: nil, settings: settings) == .copyPath(.posix))
        #expect(
            OperationPlanner.options(for: .anyCopyPath, preset: "shellQuoted", settings: settings)
                == .copyPath(.shellQuoted))
        #expect(OperationPlanner.options(for: .anyCopyPath, preset: "unknown", settings: settings) == nil)

        let posixBatch = OperationPlanner.batch(
            for: OperationRequest(op: .anyCopyPath, options: .copyPath(.posix), inputs: selection),
            settings: settings)
        let posixOutcome = await engine.run(posixBatch, settings: settings) { _ in }
        #expect(posixOutcome.outcomes == [.succeeded(outputs: [], warnings: [])])
        #expect(posixOutcome.clipboardText == "/Users/me/My Folder\n/Users/me/it's.txt")
        #expect(posixOutcome.record == nil)

        let quotedBatch = OperationPlanner.batch(
            for: OperationRequest(op: .anyCopyPath, options: .copyPath(.shellQuoted), inputs: selection),
            settings: settings)
        let quotedOutcome = await engine.run(quotedBatch, settings: settings) { _ in }
        #expect(quotedOutcome.outcomes == [.succeeded(outputs: [], warnings: [])])
        #expect(quotedOutcome.clipboardText == "'/Users/me/My Folder' '/Users/me/it'\\''s.txt'")
        #expect(quotedOutcome.record == nil)

        let emptyBatch = OperationPlanner.batch(
            for: OperationRequest(op: .anyCopyPath, options: .copyPath(.posix), inputs: []),
            settings: settings)
        let emptyOutcome = await engine.run(emptyBatch, settings: settings) { _ in }
        #expect(emptyOutcome.outcomes == [.failed(.invalidInput(.tooFewFiles(minimum: 1)))])
        #expect(!OperationID.menuOrder.contains(.anyCopyPath))
    }
}
