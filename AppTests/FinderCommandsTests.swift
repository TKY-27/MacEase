import AppKit
import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class FinderCommandsTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let settings: SettingsStore
        let jobs: JobCenter
        let pasteboard: NSPasteboard
    }

    private func fixture() throws -> Fixture {
        let name = "MacEaseFinderCommands-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: BatchNotifier(settings: settings))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            pasteboard.releaseGlobally()
            try FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, defaults: defaults, settings: settings, jobs: jobs, pasteboard: pasteboard)
    }

    private func request(_ command: HostCommand, _ urls: [URL], preset: String? = nil) -> HostCommandRequest {
        HostCommandRequest(
            action: MenuCommandAction(command: command, preset: preset),
            catalogVersion: "version", token: "token", paths: urls.map(\.path))
    }

    private func source(_ name: String, in root: URL) throws -> URL {
        let url = root.appending(path: name)
        try Data("original".utf8).write(to: url)
        return url
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSettingsPersistTemplatesAndTerminalAndResetToDefaults() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.settings.enabledNewFileTemplates, Set(NewFileTemplate.BuiltIn.allCases))
        XCTAssertEqual(fixture.settings.terminalApplicationURL.path, "/System/Applications/Utilities/Terminal.app")
        fixture.settings.enabledNewFileTemplates = [.markdown, .wordDocument]
        fixture.settings.terminalApplicationURL = URL(fileURLWithPath: "/Applications/Custom Terminal.app")
        let reloaded = SettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.enabledNewFileTemplates, [.markdown, .wordDocument])
        XCTAssertEqual(reloaded.terminalApplicationURL.path, "/Applications/Custom Terminal.app")
        reloaded.resetAll()
        XCTAssertEqual(reloaded.enabledNewFileTemplates, Set(NewFileTemplate.BuiltIn.allCases))
        XCTAssertEqual(reloaded.terminalApplicationURL, SettingsStore.defaultTerminalApplicationURL)
    }

    func testNewFilesUseEngineHistoryAndRevealOnlyCreatedOutputs() async throws {
        let fixture = try fixture()
        var revealed: [[URL]] = []
        let commands = FinderCommands(
            jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard,
            reveal: { revealed.append($0) }, openTerminal: { _, _ in XCTFail("Unexpected terminal") })
        defer { commands.prepareForTermination() }
        let destination = try folder("new-files", in: fixture.root)
        for template in NewFileTemplate.BuiltIn.allCases {
            let execution = try await commands.execute(request(.newFile, [destination], preset: template.rawValue))
            let outcome = try XCTUnwrap(execution)
            XCTAssertEqual(outcome.operation, .folderNewFile)
            XCTAssertNotNil(outcome.record)
            let output = try XCTUnwrap(revealed.last?.first)
            XCTAssertEqual(output.deletingPathExtension().lastPathComponent, "Untitled")
            XCTAssertEqual(output.pathExtension, template.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(revealed.count, 4)
        let records = await fixture.jobs.engine.history.records
        XCTAssertEqual(records.count, 4)
        fixture.settings.enabledNewFileTemplates = []
        do {
            try await commands.execute(request(.newFile, [destination], preset: "txt"))
            XCTFail("Disabled template accepted")
        } catch FinderCommands.Failure.invalidTemplate {}
        XCTAssertEqual(revealed.count, 4)
    }

    func testCutReplacesPasteboardURLsAndExpiresOnClipboardChangeOrQuit() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let first = try source("first.txt", in: fixture.root)
        let second = try source("second.txt", in: fixture.root)
        var changes = 0
        commands.onCutChange = { changes += 1 }
        try await commands.execute(request(.cut, [first, first]))
        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [first])
        try await commands.execute(request(.cut, [second]))
        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [second])
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("copied elsewhere", forType: .string))
        let beforeInvalidation = changes
        commands.checkPasteboard()
        XCTAssertEqual(commands.cutCount, 0)
        XCTAssertEqual(changes, beforeInvalidation + 1)
        try await commands.execute(request(.cut, [first, second]))
        XCTAssertEqual(commands.cutCount, 2)
        commands.prepareForTermination()
        XCTAssertEqual(commands.cutCount, 0)
        try await commands.execute(request(.cut, [first]))
        XCTAssertEqual(commands.cutCount, 0)
        XCTAssertGreaterThanOrEqual(changes, 5)
    }

    func testMoveUsesCutTimeStampsAndDropsSkippedChangedItems() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let unchanged = try source("unchanged.txt", in: fixture.root)
        let changed = try source("changed.txt", in: fixture.root)
        let destination = try folder("destination", in: fixture.root)
        try await commands.execute(request(.cut, [unchanged, changed]))
        try Data("different contents after cut".utf8).write(to: changed)
        var counts: [Int] = []
        commands.onCutChange = { counts.append(commands.cutCount) }
        let execution = try await commands.execute(request(.moveHere, [destination]))
        let outcome = try XCTUnwrap(execution)
        XCTAssertEqual(outcome.outcomes.count, 2)
        XCTAssertEqual(outcome.outcomes[1], .skipped(.changedSinceScan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "unchanged.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unchanged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path))
        XCTAssertEqual(commands.cutCount, 0)
        XCTAssertTrue(counts.allSatisfy { $0 == 0 })
        XCTAssertTrue(BatchSummary(outcome).details.contains(changed.lastPathComponent))
        let record = try XCTUnwrap(outcome.record)
        let restored = try await fixture.jobs.engine.undo(record.id)
        XCTAssertEqual(restored, [.restored])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unchanged.path))
    }

    func testUndoEvenWithoutHistoryClearsCut() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        fixture.jobs.onUndo = { [weak commands] in commands?.clearCut() }
        try await commands.execute(request(.cut, [try source("a", in: fixture.root)]))
        fixture.jobs.undo(UUID())
        XCTAssertEqual(commands.cutCount, 0)
        try await fixture.jobs.prepareForTermination()
    }

    func testCopyPathWritesLiteralAndShellQuotedPathsAndClearsCut() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let first = try source("a b.txt", in: fixture.root)
        let second = try source("quote's.txt", in: fixture.root)
        try await commands.execute(request(.cut, [first]))
        try await commands.execute(request(.copyPath, [first, second], preset: "posix"))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), first.path + "\n" + second.path)
        XCTAssertEqual(commands.cutCount, 0)
        try await commands.execute(request(.copyPath, [first, second], preset: "shellQuoted"))
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "'" + first.path + "' '" + second.path.replacingOccurrences(of: "'", with: "'\\''") + "'")
        try await commands.execute(request(.copyPath, [fixture.root], preset: "posix"))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), fixture.root.path)
    }

    func testTerminalResolvesFolderFileAndPackageWithoutLaunchingAnyApp() async throws {
        let fixture = try fixture()
        var opened: [(URL, URL)] = []
        let commands = FinderCommands(
            jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard,
            openTerminal: { opened.append(($0, $1)) })
        let directory = try folder("directory", in: fixture.root)
        let file = try source("a.txt", in: directory)
        let package = try folder("Example.app", in: directory)
        for selected in [directory, file, package] {
            try await commands.execute(request(.openTerminal, [selected]))
            XCTAssertEqual(opened.last?.0.path, directory.path)
            XCTAssertEqual(opened.last?.1, SettingsStore.defaultTerminalApplicationURL)
        }
        fixture.settings.terminalApplicationURL = fixture.root.appending(path: "Missing.app")
        do {
            try await commands.execute(request(.openTerminal, [directory]))
            XCTFail("Missing application accepted")
        } catch FinderCommands.Failure.missingTerminal(let application) {
            XCTAssertEqual(application, fixture.settings.terminalApplicationURL)
            XCTAssertTrue(
                FinderCommands.Failure.missingTerminal(application).localizedDescription.contains(application.path))
        }
        XCTAssertEqual(opened.count, 3)
    }

    func testFolderCommandsRejectFilesPackagesAndMultipleFolders() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(
            jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard,
            reveal: { _ in XCTFail("Unexpected reveal") })
        let file = try source("a.txt", in: fixture.root)
        let package = try folder("Example.app", in: fixture.root)
        for command in [HostCommand.newFile, .moveHere] {
            for selection in [[file], [package], [fixture.root, fixture.root]] {
                do {
                    try await commands.execute(request(command, selection, preset: command == .newFile ? "txt" : nil))
                    XCTFail("Invalid destination accepted")
                } catch FinderCommands.Failure.invalidFolder {}
            }
        }
    }

    func testPublishedMoveTitleVisibilityAndEnabledTemplatesFollowState() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let configuration = HostConfiguration(
            urlScheme: "macease-test", supportDirectory: fixture.root.appending(path: "menu"))
        func publish() throws -> MenuFile {
            try MenuFileWriter(configuration: configuration).write(
                visibleOperations: [], hiddenEntries: [],
                settings: fixture.settings.settings, cutCount: commands.cutCount,
                newFileTemplates: fixture.settings.enabledNewFileTemplates)
        }
        XCTAssertFalse(try publish().commands.contains { $0.command == .moveHere })
        let first = try source("first", in: fixture.root)
        let second = try source("second", in: fixture.root)
        try await commands.execute(request(.cut, [first]))
        XCTAssertEqual(
            try publish().commands.first { $0.command == .moveHere }?.title, String(localized: "Move 1 Item Here"))
        try await commands.execute(request(.cut, [first, second]))
        let menu = try publish()
        XCTAssertEqual(menu.commands.first { $0.command == .moveHere }?.title, MenuStrings.moveHereTitle(count: 2))
        XCTAssertEqual(try MenuFile(json: Data(contentsOf: configuration.menuFile)), menu)
        fixture.settings.enabledNewFileTemplates = [.markdown]
        XCTAssertEqual(try publish().commands.first { $0.command == .newFile }?.leaves?.map(\.preset), ["md"])
        let invalidated = expectation(description: "Clipboard polling republishes menu")
        commands.onCutChange = {
            do { _ = try publish() } catch { XCTFail("Menu publication failed: \(error)") }
            if commands.cutCount == 0 { invalidated.fulfill() }
        }
        fixture.pasteboard.clearContents()
        await fulfillment(of: [invalidated], timeout: 3)
        let invalidatedMenu = try MenuFile(json: Data(contentsOf: configuration.menuFile))
        XCTAssertFalse(invalidatedMenu.commands.contains { $0.command == .moveHere })
    }
}

extension FinderCommandsTests {
    func testCrossVolumeWarningNamesBothPathsInEnglishJapaneseAndActivity() async throws {
        let original = URL(fileURLWithPath: "/source/notes.txt")
        let destination = URL(fileURLWithPath: "/other-disk/notes.txt")
        let key = "Copied to another disk at %@. Original kept at %@."
        let english = "Copied to another disk at /other-disk/notes.txt. Original kept at /source/notes.txt."
        let japanese = "別のディスクの/other-disk/notes.txtにコピーしました。元のファイルは/source/notes.txtに保持しました。"
        for (language, expected) in [("en", english), ("ja", japanese)] {
            let localization = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: localization))
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertEqual(String(format: format, destination.path, original.path), expected)
            XCTAssertEqual(
                bundle.localizedString(forKey: "Untitled", value: nil, table: nil),
                language == "ja" ? "名称未設定" : "Untitled")
        }
        let described = UserMessages.describe(.copiedAcrossVolumes(original: original, destination: destination))
        XCTAssertTrue([english, japanese].contains(described))
        let fixture = try fixture()
        let input = try source("warning.txt", in: fixture.root)
        let batches = Batch(
            operation: .filesMove,
            items: [
                WorkItem(inputs: [input]) { context in
                    context.warn(.copiedAcrossVolumes(original: original, destination: destination))
                    return .text("result", .report)
                }
            ])
        let execution = await fixture.jobs.run(batch: batches).value
        let outcome = try XCTUnwrap(execution)
        XCTAssertTrue(BatchSummary(outcome).details.contains(described))
        XCTAssertEqual(ActivityResult(outcome).noteCount, 1)
        XCTAssertTrue(ActivityResult(outcome).problems.isEmpty)
        XCTAssertTrue(fixture.jobs.completed.first?.summary.details.contains(described) == true)
    }
}
