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

    func testTerminalChoicesListEachDetectedAppOnceAndReportAMissingSavedApp() throws {
        let fixture = try fixture()
        let iTerm = fixture.root.appending(path: "iTerm.app", directoryHint: .isDirectory)
        let executableFolder = iTerm.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: executableFolder, withIntermediateDirectories: true)
        let executable = executableFolder.appending(path: "iTerm")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let bundleProperties = ["CFBundleExecutable": "iTerm", "CFBundleIdentifier": "test.iTerm"]
        try PropertyListSerialization.data(fromPropertyList: bundleProperties, format: .xml, options: 0)
            .write(to: iTerm.appending(path: "Contents/Info.plist"))
        var asked: [String] = []
        let locate: (String) -> URL? = { identifier in
            asked.append(identifier)
            return switch identifier {
            case "com.apple.Terminal": URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/")
            case "com.googlecode.iterm2": iTerm
            default: nil
            }
        }

        let standard = TerminalApplications(saved: SettingsStore.defaultTerminalApplicationURL, locate: locate)
        XCTAssertEqual(asked, TerminalApplications.bundleIdentifiers)
        XCTAssertEqual(standard.choices.map(\.path), [SettingsStore.defaultTerminalApplicationURL.path, iTerm.path])
        XCTAssertNil(standard.missing)

        fixture.settings.terminalApplicationURL = iTerm
        let reloaded = SettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.terminalApplicationURL, iTerm, "the choice persists")
        try FileManager.default.removeItem(at: iTerm)
        let missing = TerminalApplications(saved: reloaded.terminalApplicationURL, locate: locate)
        XCTAssertEqual(missing.choices.map(\.path), [SettingsStore.defaultTerminalApplicationURL.path, iTerm.path])
        XCTAssertEqual(missing.missing, iTerm, "a deleted app is reported, not hidden")
        XCTAssertEqual(TerminalApplications.name(of: iTerm), "iTerm")

        let custom = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let other = TerminalApplications(saved: custom, locate: locate)
        XCTAssertEqual(other.choices.last, custom, "an app chosen with Other… stays listed")
        XCTAssertNil(other.missing)
    }

    func testTerminalChoicesExcludeDetectedAppsThatCannotBeOpened() throws {
        let fixture = try fixture()
        let unavailable = fixture.root.appending(path: "Unavailable.app")
        let choices = TerminalApplications(saved: SettingsStore.defaultTerminalApplicationURL) { identifier in
            identifier == "com.googlecode.iterm2" ? unavailable : nil
        }
        XCTAssertEqual(choices.choices.map(\.path), [SettingsStore.defaultTerminalApplicationURL.path])
        XCTAssertNil(choices.missing)
    }

    func testOpenWithUsesTheSameMacOSTermInItsMissingApplicationMessage() throws {
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(japanese.localizedString(forKey: "Open with", value: nil, table: nil), "このアプリケーションで開く")
        XCTAssertEqual(
            japanese.localizedString(forKey: "“%@” can’t be found. Choose another app.", value: nil, table: nil),
            "“%@”が見つかりません。別のアプリケーションを選択してください。")
        XCTAssertEqual(
            japanese.localizedString(
                forKey:
                    "Applies to subtitles, chapters and similar content in new files. Replacing an original always asks.",
                value: nil, table: nil),
            "新しいファイルの字幕やチャプタなどに適用されます。元のファイルを置き換える場合は必ず確認します。")
    }

    func testTurningOffEveryTemplateRemovesNewFileFromThePublishedMenu() throws {
        let fixture = try fixture()
        let configuration = HostConfiguration(
            urlScheme: "macease-test", supportDirectory: fixture.root.appending(path: "menu"))
        func newFile() throws -> MenuCommandItem? {
            try MenuFileWriter(configuration: configuration).write(
                visibleOperations: [], hiddenEntries: [], settings: fixture.settings.settings,
                newFileTemplates: fixture.settings.enabledNewFileTemplates
            ).commands.first { $0.command == .newFile }
        }
        var changes = 0
        fixture.settings.onChange = { changes += 1 }
        fixture.settings.enabledNewFileTemplates.remove(.richText)
        XCTAssertEqual(try newFile()?.leaves?.map(\.preset), ["txt", "md", "docx"])
        fixture.settings.enabledNewFileTemplates = []
        XCTAssertNil(try newFile(), "New File leaves the menu instead of opening an empty submenu")
        XCTAssertEqual(changes, 2, "each toggle republishes the menu")
        fixture.settings.enabledNewFileTemplates.insert(.markdown)
        XCTAssertEqual(try newFile()?.leaves?.map(\.preset), ["md"])
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
        XCTAssertTrue((fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).isEmpty)
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

    func testCutCapturesOffMainActorCancelsEarlierCaptureAndRefusesMoveWhileCapturing() async throws {
        let fixture = try fixture()
        let first = try source("first.txt", in: fixture.root)
        let second = try source("second.txt", in: fixture.root)
        let destination = try folder("dest", in: fixture.root)

        let startedFirst = expectation(description: "First capture started off main thread")
        let cancelledFirst = expectation(description: "First capture observed cancellation")
        let gate = AsyncGate()

        let commands = FinderCommands(
            jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard,
            captureMoveItems: { urls in
                XCTAssertFalse(Self.isOnMainThread())
                if urls.first?.lastPathComponent == "first.txt" {
                    startedFirst.fulfill()
                    await gate.wait()
                    if Task.isCancelled { cancelledFirst.fulfill() }
                    try Task.checkCancellation()
                }
                return try urls.map(MoveItem.capture)
            })
        defer { commands.prepareForTermination() }

        let firstCut = Task { try await commands.execute(request(.cut, [first])) }
        await fulfillment(of: [startedFirst], timeout: 5)
        XCTAssertEqual(commands.cutCount, 0)
        do {
            try await commands.execute(request(.moveHere, [destination]))
            XCTFail("Move Here accepted while capture running")
        } catch FinderCommands.Failure.cutInProgress {}

        try await commands.execute(request(.cut, [second]))
        await gate.open()
        await fulfillment(of: [cancelledFirst], timeout: 5)
        _ = try await firstCut.value

        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [second])
        _ = try await commands.execute(request(.moveHere, [destination]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "second.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        let bigFolder = try folder("big", in: fixture.root)
        _ = try source("child.txt", in: bigFolder)
        let cancelledTask = Task.detached {
            try MoveItem.capture(bigFolder)
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Cancelled directory capture succeeded")
        } catch is CancellationError {}
    }

    func testSymlinkAndDotComponentsAreRefusedForFolderAndTerminalCommands() async throws {
        let fixture = try fixture()
        let work = try folder("work", in: fixture.root)
        let target = try folder("target", in: fixture.root)
        let symdir = work.appending(path: "symdir")
        try FileManager.default.createSymbolicLink(at: symdir, withDestinationURL: target)
        let file = try source("cut.txt", in: fixture.root)

        var opened: [URL] = []
        let commands = FinderCommands(
            jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard,
            reveal: { _ in XCTFail("Unexpected reveal") }, openTerminal: { folder, _ in opened.append(folder) })
        defer { commands.prepareForTermination() }
        try await commands.execute(request(.cut, [file]))

        for path in [symdir.path + "/.", symdir.path + "/..", symdir.path + "/", symdir.path] {
            let newFileRequest = HostCommandRequest(
                action: MenuCommandAction(command: .newFile, preset: "txt"),
                catalogVersion: "v", token: "t", paths: [path])
            do {
                try await commands.execute(newFileRequest)
                XCTFail("New File accepted \(path)")
            } catch FinderCommands.Failure.invalidSelection, FinderCommands.Failure.invalidFolder {}

            let moveRequest = HostCommandRequest(
                action: MenuCommandAction(command: .moveHere),
                catalogVersion: "v", token: "t", paths: [path])
            do {
                try await commands.execute(moveRequest)
                XCTFail("Move Here accepted \(path)")
            } catch FinderCommands.Failure.invalidSelection, FinderCommands.Failure.invalidFolder {}
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        for dotPath in [symdir.path + "/.", symdir.path + "/.."] {
            let terminalRequest = HostCommandRequest(
                action: MenuCommandAction(command: .openTerminal),
                catalogVersion: "v", token: "t", paths: [dotPath])
            do {
                try await commands.execute(terminalRequest)
                XCTFail("Open Terminal accepted \(dotPath)")
            } catch FinderCommands.Failure.invalidSelection {}
        }
        XCTAssertTrue(opened.isEmpty)

        for symlinkPath in [symdir.path + "/", symdir.path] {
            let terminalRequest = HostCommandRequest(
                action: MenuCommandAction(command: .openTerminal),
                catalogVersion: "v", token: "t", paths: [symlinkPath])
            try await commands.execute(terminalRequest)
            XCTAssertEqual(opened.last?.path, work.path)
            XCTAssertNotEqual(opened.last?.path, target.path)
        }
    }

    func testErrorWordingCoversExpiredCutMissingItemsAndDisabledTemplate() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(
            jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard,
            openTerminal: { _, _ in XCTFail("Unexpected terminal") })
        defer { commands.prepareForTermination() }
        let file = try source("item.txt", in: fixture.root)
        let destination = try folder("dest", in: fixture.root)

        try await commands.execute(request(.cut, [file]))
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("external", forType: .string))
        do {
            try await commands.execute(request(.moveHere, [destination]))
            XCTFail("Move Here accepted right after clipboard change before timer")
        } catch FinderCommands.Failure.nothingCut {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(commands.cutCount, 0)

        let deletedFolder = fixture.root.appending(path: "gone-folder", directoryHint: .isDirectory)
        let deletedFile = fixture.root.appending(path: "gone-file.txt")
        for req in [
            request(.newFile, [deletedFolder], preset: "txt"),
            request(.moveHere, [deletedFolder]),
        ] {
            do {
                try await commands.execute(req)
                XCTFail("Missing folder accepted")
            } catch let error as FinderCommands.Failure {
                XCTAssertEqual(error, .itemFailed(.retryInputMissing, file: "gone-folder"))
                XCTAssertTrue(error.localizedDescription.contains("gone-folder"))
            }
        }
        for req in [request(.cut, [deletedFile]), request(.openTerminal, [deletedFile])] {
            do {
                try await commands.execute(req)
                XCTFail("Missing file accepted")
            } catch let error as FinderCommands.Failure {
                XCTAssertEqual(error, .itemFailed(.retryInputMissing, file: "gone-file.txt"))
                XCTAssertTrue(error.localizedDescription.contains("gone-file.txt"))
            }
        }

        let keys: [(String, String, String)] = [
            (
                "This New File template is no longer enabled. Enable it in Settings > Finder Menu > Commands > New File > Options.",
                "Settings > Finder Menu > Commands > New File > Options",
                "「設定」>「Finderメニュー」>「コマンド」>「新規ファイル」>「オプション」"
            ),
            (
                "There are no cut items to move. Cut the items again, then choose Move Here.",
                "Cut the items again", "カットされた項目がありません"
            ),
            (
                "Cut is still preparing the selected items. Wait for it to finish, then choose Move Here.",
                "still preparing", "準備中"
            ),
            (
                "A move is already in progress. Wait for it to finish, then try again.",
                "already in progress", "進行中"
            ),
        ]
        for (key, enFragment, jaFragment) in keys {
            for (language, fragment) in [("en", enFragment), ("ja", jaFragment)] {
                let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
                let bundle = try XCTUnwrap(Bundle(path: path))
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertTrue(localized.contains(fragment), "\(language) missing \(fragment): \(localized)")
                XCTAssertFalse(localized.contains("!"))
            }
        }
    }

    func testPartialFailureKeepsOnlyFailedItemsAndRewritesPasteboard() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let parent = try folder("parent", in: fixture.root)
        let childDestination = try folder("child", in: parent)
        let sibling = try source("sibling.txt", in: fixture.root)

        try await commands.execute(request(.cut, [parent, sibling]))
        XCTAssertEqual(commands.cutCount, 2)
        let execution = try await commands.execute(request(.moveHere, [childDestination]))
        let outcome = try XCTUnwrap(execution)
        XCTAssertEqual(outcome.outcomes.count, 2)
        if case .failed = outcome.outcomes[0] {
        } else {
            XCTFail("Moving folder into descendant should fail, got \(outcome.outcomes[0])")
        }
        if case .succeeded = outcome.outcomes[1] {
        } else {
            XCTFail("Moving sibling should succeed, got \(outcome.outcomes[1])")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: childDestination.appending(path: "sibling.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [parent])
        commands.checkPasteboard()
        XCTAssertEqual(commands.cutCount, 1)
    }

    func testMoveIntoSourceFolderKeepsCutWithOriginalStamp() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let sourceFolder = try folder("source", in: fixture.root)
        let otherFolder = try folder("other", in: fixture.root)
        let file = try source("keep.txt", in: sourceFolder)

        try await commands.execute(request(.cut, [file]))
        let sameFolderExecution = try await commands.execute(request(.moveHere, [sourceFolder]))
        let sameFolder = try XCTUnwrap(sameFolderExecution)
        XCTAssertEqual(sameFolder.outcomes, [.skipped(.alreadyDone)])
        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [file])

        let movedExecution = try await commands.execute(request(.moveHere, [otherFolder]))
        let moved = try XCTUnwrap(movedExecution)
        XCTAssertEqual(moved.outcomes, [.succeeded(outputs: [otherFolder.appending(path: "keep.txt")], warnings: [])])
        XCTAssertEqual(commands.cutCount, 0)
        XCTAssertTrue((fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).isEmpty)
    }

    func testSecondCutWhileMoveRunsWinsAndIsNotClearedWhenMoveFinishes() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let first = try source("first.txt", in: fixture.root)
        let second = try source("second.txt", in: fixture.root)
        let destination = try folder("dest", in: fixture.root)

        try await commands.execute(request(.cut, [first]))
        var nestedTask: Task<Void, Never>?
        var moveWhileMovingFailed = false
        var cutCountDuringMove: Int?
        var triggered = false
        fixture.jobs.onStart = { [weak commands] _ in
            guard !triggered, let commands else { return }
            triggered = true
            cutCountDuringMove = commands.cutCount
            nestedTask = Task {
                do {
                    try await commands.execute(self.request(.moveHere, [destination]))
                } catch FinderCommands.Failure.moveInProgress {
                    moveWhileMovingFailed = true
                } catch {
                    XCTFail("Unexpected move error: \(error)")
                }
                do {
                    try await commands.execute(self.request(.cut, [second]))
                } catch {
                    XCTFail("Second cut failed: \(error)")
                }
            }
        }

        _ = try await commands.execute(request(.moveHere, [destination]))
        await nestedTask?.value

        XCTAssertEqual(cutCountDuringMove, 0)
        XCTAssertTrue(moveWhileMovingFailed)
        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [second])
        _ = try await commands.execute(request(.moveHere, [destination]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "second.txt").path))
    }

    func testExternalPasteboardChangeDuringMoveIsNotClobberedOnCompletion() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let file = try source("move.txt", in: fixture.root)
        let destination = try folder("dest", in: fixture.root)

        try await commands.execute(request(.cut, [file]))
        var changed = false
        fixture.jobs.onStart = { _ in
            guard !changed else { return }
            changed = true
            fixture.pasteboard.clearContents()
            XCTAssertTrue(fixture.pasteboard.setString("user-copied-text", forType: .string))
        }
        _ = try await commands.execute(request(.moveHere, [destination]))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "user-copied-text")
        XCTAssertEqual(commands.cutCount, 0)
    }

    func testCrossVolumeMoveKeepsCutWithOriginalStamps() async throws {
        let fixture = try fixture()
        let volume = try TemporaryDiskImage.create(in: fixture.root)
        defer {
            do { try volume.close() } catch { XCTFail("Disk image cleanup failed: \(error)") }
        }
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        let original = try source("notes.txt", in: fixture.root)

        try await commands.execute(request(.cut, [original]))
        let execution = try await commands.execute(request(.moveHere, [volume.mount]))
        let outcome = try XCTUnwrap(execution)
        let copied = volume.mount.appending(path: "notes.txt")
        XCTAssertEqual(
            outcome.outcomes,
            [.succeeded(outputs: [copied], warnings: [.copiedAcrossVolumes(original: original, destination: copied)])])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(commands.cutCount, 1)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [original])

        try Data("edited after original cut".utf8).write(to: original)
        let secondExecution = try await commands.execute(request(.moveHere, [volume.mount]))
        let secondOutcome = try XCTUnwrap(secondExecution)
        XCTAssertEqual(secondOutcome.outcomes, [.skipped(.changedSinceScan)])
        XCTAssertEqual(commands.cutCount, 0)
    }

    func testSettingsStoreHandlesEmptyTerminalAndGuardsOnChange() throws {
        let fixture = try fixture()
        fixture.defaults.set("", forKey: "finderCommands.terminalApplication")
        let emptyReloaded = SettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(emptyReloaded.terminalApplicationURL, SettingsStore.defaultTerminalApplicationURL)

        fixture.defaults.set("relative/Terminal.app", forKey: "finderCommands.terminalApplication")
        let relativeReloaded = SettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(relativeReloaded.terminalApplicationURL, SettingsStore.defaultTerminalApplicationURL)

        var changes = 0
        emptyReloaded.onChange = { changes += 1 }
        emptyReloaded.terminalApplicationURL = SettingsStore.defaultTerminalApplicationURL
        emptyReloaded.terminalApplicationURL = URL(fileURLWithPath: "/Applications/Other.app")
        XCTAssertEqual(changes, 0)

        emptyReloaded.enabledNewFileTemplates = Set(NewFileTemplate.BuiltIn.allCases)
        XCTAssertEqual(changes, 0)
        emptyReloaded.enabledNewFileTemplates = [.plainText]
        XCTAssertEqual(changes, 1)
        emptyReloaded.enabledNewFileTemplates = [.plainText]
        XCTAssertEqual(changes, 1)
    }

    func testOrganizationUndoClearsCut() async throws {
        let fixture = try fixture()
        let commands = FinderCommands(jobs: fixture.jobs, settings: fixture.settings, pasteboard: fixture.pasteboard)
        defer { commands.prepareForTermination() }
        fixture.jobs.onUndo = { [weak commands] in commands?.clearCut() }
        let organization = OrganizationController(
            jobs: fixture.jobs, store: fixture.settings, supportDirectory: fixture.root.appending(path: "support"))

        try await commands.execute(request(.cut, [try source("a.txt", in: fixture.root)]))
        XCTAssertEqual(commands.cutCount, 1)
        let cleared = expectation(description: "Organization undo clears cut")
        commands.onCutChange = { if commands.cutCount == 0 { cleared.fulfill() } }
        let record = BatchRecord(id: UUID(), operation: .folderOrganize, date: Date(), items: [], undone: false)
        organization.undo(record)
        await fulfillment(of: [cleared], timeout: 5)
        XCTAssertEqual(commands.cutCount, 0)
    }

    private nonisolated static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class TemporaryDiskImage {
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    let mount: URL
    private var attached = false

    private init(mount: URL, attached: Bool) {
        self.mount = mount
        self.attached = attached
    }

    static func create(in root: URL) throws -> TemporaryDiskImage {
        let work = root.appending(path: "disk-\(UUID().uuidString)", directoryHint: .isDirectory)
        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        let image = work.appending(path: "volume.sparseimage")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let label = "MACEASE\(UUID().uuidString.prefix(4))"
        let create = try run([
            "create", "-size", "64m", "-fs", "ExFAT", "-type", "SPARSE", "-volname", label, image.path,
        ])
        if create != 0 {
            throw XCTSkip("Disk-image creation is unavailable in this environment")
        }
        let attach = try run(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        guard attach == 0 else {
            throw POSIXError(.EIO)
        }
        return TemporaryDiskImage(mount: mount, attached: true)
    }

    func close() throws {
        guard attached else { return }
        attached = false
        let status = try Self.run(["detach", mount.path, "-force"])
        guard status == 0 else { throw POSIXError(.EIO) }
    }

    private static func run(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = hdiutil
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
