import AppKit
import Darwin
import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct NewFileTests {
    private func makeEngine(in folder: URL) throws -> JobEngine {
        let support = folder.appending(path: "support")
        return try JobEngine(supportDirectory: support, concurrency: 2)
    }

    private func runNewFile(
        _ template: NewFileTemplate, in inputs: [URL], engine: JobEngine
    ) async -> BatchOutcome {
        let settings = Settings()
        let request = OperationRequest(op: .folderNewFile, options: .folder(.newFile(template)), inputs: inputs)
        let batch = OperationPlanner.batch(for: request, settings: settings)
        return await engine.run(batch, settings: settings) { _ in }
    }

    @Test func substitutedDestinationIsRefusedBeforeCreatingNewFile() async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target")
        let displaced = workspace.appending(path: "displaced")
        let redirected = workspace.appending(path: "redirected")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        let engine = try makeEngine(in: workspace)
        let staged = try engine.staging.makeDirectory(for: target)
        defer { engine.staging.remove(staged) }
        let empty = staged.appending(path: "Untitled.txt")
        try Data().write(to: empty)
        let callbackFailure = Mutex<(any Error)?>(nil)
        await #expect(throws: FileCommitter.Failure.changedSinceScan) {
            try await FileCommitter().create(
                [StagedFile(url: empty, name: "Untitled.txt", check: .newFile(.empty))], in: target,
                phase: { phase in
                    guard phase == .saving else { return }
                    do {
                        try FileManager.default.moveItem(at: target, to: displaced)
                        try FileManager.default.createSymbolicLink(
                            atPath: target.path, withDestinationPath: redirected.path)
                    } catch { callbackFailure.withLock { $0 = error } }
                })
        }
        #expect(callbackFailure.withLock { $0 == nil })
        #expect(FileManager.default.fileExists(atPath: empty.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
    }

    @Test(arguments: ["docx", "rtf", "DOCX", ".RTF"])
    func emptyStructuredTemplatesAreRefused(pathExtension: String) async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = try makeEngine(in: workspace)
        let outcome = await runNewFile(
            NewFileTemplate(pathExtension: pathExtension, defaultBaseName: "Broken"), in: [target], engine: engine)
        #expect(outcome.outcomes == [.failed(.encodeFailed("empty output"))])
        #expect(outcome.record == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test(arguments: NewFileTemplate.BuiltIn.allCases)
    func builtInTemplatesCreateValidReopenableFilesAndUndoSafely(kind: NewFileTemplate.BuiltIn) async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = try makeEngine(in: workspace)
        let template = try NewFileTemplate.builtIn(kind, defaultBaseName: "Untitled")

        let outcome = await runNewFile(template, in: [target], engine: engine)

        let expected = target.appending(path: "Untitled.\(kind.rawValue)")
        #expect(outcome.outcomes == [.succeeded(outputs: [expected], warnings: [])])
        #expect(!outcome.historyFailed)
        let bytes = try Data(contentsOf: expected)
        switch kind {
        case .plainText, .markdown:
            #expect(bytes.isEmpty)
        case .richText:
            #expect(!bytes.isEmpty)
            #expect(try ContentSniffer.matches(expected, kind: .document))
            let reopened = try NSAttributedString(
                data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            #expect(reopened.string.isEmpty)
            #expect(try AttributedDocument.convert(expected, toPDF: false).isEmpty)
        case .wordDocument:
            #expect(!bytes.isEmpty)
            #expect(try ContentSniffer.matches(expected, kind: .document))
            try ArchiveListing.verify(expected)
            let reopened = try NSAttributedString(
                data: bytes, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil)
            #expect(reopened.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let converted = try String(decoding: AttributedDocument.convert(expected, toPDF: false), as: UTF8.self)
            #expect(converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        let record = try #require(outcome.record)
        #expect(record.operation == .folderNewFile)
        #expect(record.items == [.derived(output: expected.path, stamp: try FileStamp(of: expected))])

        let reopenedEngine = try makeEngine(in: workspace)
        #expect(await reopenedEngine.history.records.contains(record))
        #expect(try await reopenedEngine.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: expected.path))
    }

    @Test func collisionsNumberWithoutOverwritingFilesFoldersOrDanglingLinks() async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = target.appending(path: "Untitled.txt")
        let dangling = target.appending(path: "Untitled (2).txt")
        let folder = target.appending(path: "Untitled (3).txt")
        try Data("keep".utf8).write(to: existing)
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: target.appending(path: "missing"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let engine = try makeEngine(in: workspace)

        let first = await runNewFile(
            try NewFileTemplate.builtIn(.plainText, defaultBaseName: "Untitled"), in: [target], engine: engine)
        let second = await runNewFile(
            try NewFileTemplate.builtIn(.plainText, defaultBaseName: "Untitled"), in: [target], engine: engine)

        let fourth = target.appending(path: "Untitled (4).txt")
        let fifth = target.appending(path: "Untitled (5).txt")
        #expect(first.outcomes == [.succeeded(outputs: [fourth], warnings: [])])
        #expect(second.outcomes == [.succeeded(outputs: [fifth], warnings: [])])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        var linkStat = stat()
        #expect(lstat(dangling.path, &linkStat) == 0)
        #expect(linkStat.st_mode & S_IFMT == S_IFLNK)
    }

    @Test func customTemplatesSupportLocalizedNamesLeadingDotsAndNoExtension() async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = try makeEngine(in: workspace)

        let localized = NewFileTemplate(pathExtension: ".md", defaultBaseName: "名称未設定")
        let localizedOutcome = await runNewFile(localized, in: [target], engine: engine)
        let localizedURL = target.appending(path: "名称未設定.md")
        #expect(localizedOutcome.outcomes == [.succeeded(outputs: [localizedURL], warnings: [])])
        #expect(try Data(contentsOf: localizedURL).isEmpty)

        let extensionless = NewFileTemplate(
            pathExtension: "", defaultBaseName: "Makefile", initialBytes: Data("all:\n".utf8))
        let firstOutcome = await runNewFile(extensionless, in: [target], engine: engine)
        let secondOutcome = await runNewFile(extensionless, in: [target], engine: engine)
        let firstURL = target.appending(path: "Makefile")
        let secondURL = target.appending(path: "Makefile (2)")
        #expect(firstOutcome.outcomes == [.succeeded(outputs: [firstURL], warnings: [])])
        #expect(secondOutcome.outcomes == [.succeeded(outputs: [secondURL], warnings: [])])
        #expect(try String(contentsOf: firstURL, encoding: .utf8) == "all:\n")
        #expect(try String(contentsOf: secondURL, encoding: .utf8) == "all:\n")
    }

    @Test func undoSkipsCreatedFileAfterUserEditsIt() async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = try makeEngine(in: workspace)

        let outcome = await runNewFile(
            try NewFileTemplate.builtIn(.markdown, defaultBaseName: "Notes"), in: [target], engine: engine)
        let created = target.appending(path: "Notes.md")
        let record = try #require(outcome.record)
        try Data("# Important\n".utf8).write(to: created)

        #expect(try await engine.undo(record.id) == [.skipped(.undoOutputChanged, path: created.path)])
        #expect(try String(contentsOf: created, encoding: .utf8) == "# Important\n")
    }

    @Test func refusesReadOnlyNonDirectoryPackageSymlinkAndMissingTargets() async throws {
        let workspace = try TestVolume.makeFolder()
        let engine = try makeEngine(in: workspace)
        let template = try NewFileTemplate.builtIn(.plainText, defaultBaseName: "Untitled")

        let readOnly = workspace.appending(path: "readonly", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let readOnlyOutcome = await runNewFile(template, in: [readOnly], engine: engine)
        #expect(readOnlyOutcome.outcomes == [.failed(.permissionDenied(PermissionLocation(path: readOnly.path)))])
        #expect(readOnlyOutcome.record == nil)

        let regularFile = workspace.appending(path: "plain.txt")
        try Data("keep".utf8).write(to: regularFile)
        let fileOutcome = await runNewFile(template, in: [regularFile], engine: engine)
        #expect(fileOutcome.outcomes == [.skipped(.notADirectory)])
        #expect(fileOutcome.record == nil)
        #expect(try String(contentsOf: regularFile, encoding: .utf8) == "keep")

        let package = workspace.appending(path: "Note.rtfd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let packageOutcome = await runNewFile(template, in: [package], engine: engine)
        #expect(packageOutcome.outcomes == [.skipped(.notADirectory)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).isEmpty)

        let realFolder = workspace.appending(path: "real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let link = workspace.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFolder)
        let linkOutcome = await runNewFile(template, in: [link], engine: engine)
        #expect(linkOutcome.outcomes == [.skipped(.notADirectory)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: realFolder.path).isEmpty)

        let missing = workspace.appending(path: "missing", directoryHint: .isDirectory)
        let missingOutcome = await runNewFile(template, in: [missing], engine: engine)
        if case .failed = missingOutcome.outcomes.first {
        } else {
            Issue.record("Expected failure for missing directory")
        }
        #expect(missingOutcome.record == nil)
    }

    @Test func rejectsMalformedTemplateNamesAndInvalidStructuredBytes() async throws {
        let workspace = try TestVolume.makeFolder()
        let target = workspace.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = try makeEngine(in: workspace)

        let malformedTemplates = [
            NewFileTemplate(pathExtension: "txt", defaultBaseName: ""),
            NewFileTemplate(pathExtension: "txt", defaultBaseName: "a/b"),
            NewFileTemplate(pathExtension: "", defaultBaseName: ".."),
            NewFileTemplate(pathExtension: "../txt", defaultBaseName: "Untitled"),
            NewFileTemplate(pathExtension: "txt", defaultBaseName: String(repeating: "a", count: 260)),
        ]
        for template in malformedTemplates {
            let outcome = await runNewFile(template, in: [target], engine: engine)
            if case .failed(.invalidInput(.malformed)) = outcome.outcomes.first {
            } else {
                Issue.record("Expected malformed input error for \(template)")
            }
        }

        let badRTF = NewFileTemplate(
            pathExtension: "rtf", defaultBaseName: "Broken", initialBytes: Data("not rtf".utf8))
        let badRTFOutcome = await runNewFile(badRTF, in: [target], engine: engine)
        if case .failed(.encodeFailed) = badRTFOutcome.outcomes.first {
        } else {
            Issue.record("Expected encodeFailed for invalid RTF bytes")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

        let emptySelection = await runNewFile(
            try NewFileTemplate.builtIn(.plainText, defaultBaseName: "Untitled"), in: [], engine: engine)
        #expect(emptySelection.outcomes == [.failed(.invalidInput(.tooFewFiles(minimum: 1)))])

        let tooMany = await runNewFile(
            try NewFileTemplate.builtIn(.plainText, defaultBaseName: "Untitled"), in: [target, workspace],
            engine: engine)
        if case .failed(.invalidInput(.malformed)) = tooMany.outcomes.first {
        } else {
            Issue.record("Expected malformed input error for multiple folders")
        }
    }

    @Test func nonEmptyOutputRuleRemainsEnforcedForOrdinaryOutputs() async throws {
        let workspace = try TestVolume.makeFolder()
        let empty = workspace.appending(path: "empty.txt")
        try Data().write(to: empty)
        await #expect(throws: EngineError.encodeFailed("empty output")) {
            try await OutputVerifier.verify(StagedFile(url: empty, name: "empty.txt", check: .text(.utf8)))
        }
        #expect(!OperationID.menuOrder.contains(.folderNewFile))
    }
}
