import AppKit
import Engine
import XCTest

@testable import MacEase

@MainActor
final class FinderPreviewToggleTests: XCTestCase {
    func testHistoricalTextEditRecordDisplaysLocalizedTitle() throws {
        let json = """
            {"id":"00000000-0000-0000-0000-000000000001","operation":"text.edit","date":0,"items":[],"undone":false}
            """
        let record = try JSONDecoder().decode(BatchRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.operation)
        XCTAssertEqual(record.legacyOperation, BatchRecord.legacyTextEdit)
        XCTAssertEqual(MenuStrings.operationName(record), String(localized: "Edit Text"))
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(japanese.localizedString(forKey: "Edit Text", value: nil, table: nil), "テキストを編集")
    }

    func testMenuTitleNamesTheNextAction() throws {
        XCTAssertEqual(MenuStrings.previewTitle(open: true), String(localized: "Hide Finder Preview"))
        XCTAssertEqual(MenuStrings.previewTitle(open: false), String(localized: "Show Finder Preview"))
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(
            japanese.localizedString(forKey: "Hide Finder Preview", value: nil, table: nil), "Finderプレビューを非表示")
        XCTAssertEqual(
            japanese.localizedString(forKey: "Show Finder Preview", value: nil, table: nil), "Finderプレビューを表示")
    }

    func testPreviewSettingDefaultsOffAndPersistsAcrossLaunches() throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.finderPreviewEnabled)
        store.finderPreviewEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "finderPreview.enabled"))
        XCTAssertTrue(SettingsStore(defaults: defaults).finderPreviewEnabled)
        store.resetAll()
        XCTAssertFalse(SettingsStore(defaults: defaults).finderPreviewEnabled)
    }

    func testToggleFlipsTheSavedSettingAndTheMenuTitle() throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: FileManager.default.temporaryDirectory))
        coordinator.toggle()
        XCTAssertTrue(store.finderPreviewEnabled)
        XCTAssertEqual(
            MenuStrings.previewTitle(open: store.finderPreviewEnabled), String(localized: "Hide Finder Preview"))
        coordinator.toggle()
        XCTAssertFalse(SettingsStore(defaults: defaults).finderPreviewEnabled)
        XCTAssertEqual(
            MenuStrings.previewTitle(open: store.finderPreviewEnabled), String(localized: "Show Finder Preview"))
    }

    func testPresenceDocksOnlyWhenEnabledTrustedAndAWindowIsVisible() {
        let cases: [(Bool, Bool, FinderPreviewPresence.Window, FinderPreviewPresence)] = [
            (false, false, .visible, .hidden), (false, true, .visible, .hidden), (false, true, .unavailable, .hidden),
            (true, false, .absent, .notice), (true, false, .visible, .notice), (true, true, .unavailable, .notice),
            (true, true, .absent, .hidden), (true, true, .visible, .docked),
        ]
        for (enabled, trusted, window, expected) in cases {
            XCTAssertEqual(
                FinderPreviewPresence(enabled: enabled, trusted: trusted, window: window), expected,
                "\(enabled) \(trusted) \(window)")
        }
    }

    func testOnlyCommandWClosesThePanel() throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let panel = FinderPreviewPanel(content: NSView(), docked: true, defaults: defaults)
        var closeRequests = 0
        panel.closeRequested = { closeRequests += 1 }
        let keys: [(String, NSEvent.ModifierFlags, Int)] = [
            ("\u{1B}", [], 0), ("w", .command, 1), ("w", [], 1), ("\u{1B}", .shift, 1), ("q", .command, 1),
        ]
        for (characters, modifiers, expected) in keys {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
            _ = panel.performKeyEquivalent(with: event)
            XCTAssertEqual(closeRequests, expected, characters)
        }
    }

    func testClampedDockKeepsSavedPreferredWidthSeparateFromDisplayedWidth() throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let panel = FinderPreviewPanel(content: NSView(), docked: true, defaults: defaults)
        addTeardownBlock { panel.close() }
        panel.setPreviewWidth(500)
        XCTAssertEqual(panel.previewWidth, 500)
        XCTAssertEqual(defaults.double(forKey: "finderPreviewWidth"), 500)

        let smallScreen = CGRect(x: 0, y: 0, width: 840, height: 600)
        let smallWindow = CGRect(x: 40, y: 40, width: 360, height: 500)
        let clamped = FinderPreviewGeometry.placement(
            window: smallWindow, screen: smallScreen, width: panel.previewWidth)
        XCTAssertEqual(clamped.frame.width, 420)
        panel.dock(clamped, above: 0, animate: false)
        XCTAssertEqual(panel.displayedWidth, 420)
        XCTAssertEqual(panel.previewWidth, 500)
        XCTAssertEqual(defaults.double(forKey: "finderPreviewWidth"), 500)

        let largeScreen = CGRect(x: 0, y: 0, width: 2560, height: 1400)
        let largeWindow = CGRect(x: 100, y: 100, width: 900, height: 800)
        let restored = FinderPreviewGeometry.placement(
            window: largeWindow, screen: largeScreen, width: panel.previewWidth)
        XCTAssertEqual(restored.frame.width, 500)
        panel.dock(restored, above: 0, animate: false)
        XCTAssertEqual(panel.displayedWidth, 500)
        XCTAssertEqual(panel.previewWidth, 500)
    }

    func testTransientSelectionFailuresKeepPreviewUntilThresholdIsReached() async throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        let other = directory.appendingPathComponent("other.txt")
        try Data("hello".utf8).write(to: note)
        try Data("world".utf8).write(to: other)

        let store = SettingsStore(defaults: defaults)
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory))
        coordinator.applySelectionResult(.success(.init(windowID: 42, urls: [note])), trackedWindowID: 42)
        try await waitUntil { coordinator.state.kind == .text }

        coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42)
        XCTAssertEqual(coordinator.state.selectedURL, note)
        XCTAssertEqual(coordinator.state.kind, .text)
        XCTAssertNil(coordinator.state.notice)
        XCTAssertEqual(coordinator.retryAfter, .distantPast)

        coordinator.applySelectionResult(.success(.init(windowID: 99, urls: [other])), trackedWindowID: 42)
        XCTAssertEqual(coordinator.state.selectedURL, note)
        XCTAssertEqual(coordinator.state.kind, .text)
        XCTAssertNil(coordinator.state.notice)
        XCTAssertEqual(coordinator.retryAfter, .distantPast)

        coordinator.applySelectionResult(.success(.init(windowID: 42, urls: [note])), trackedWindowID: 42)
        coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42)
        coordinator.applySelectionResult(.failure(.unavailable), trackedWindowID: 42)
        XCTAssertEqual(coordinator.state.selectedURL, note)
        XCTAssertNil(coordinator.state.notice)

        coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42)
        XCTAssertNil(coordinator.state.selectedURL)
        XCTAssertNil(coordinator.state.kind)
        XCTAssertEqual(coordinator.state.notice, .timedOut)
        XCTAssertGreaterThan(coordinator.retryAfter, Date())

        coordinator.applySelectionResult(.success(.init(windowID: 42, urls: [note])), trackedWindowID: 42)
        try await waitUntil { coordinator.state.kind == .text }
        coordinator.applySelectionResult(.failure(.automationDenied), trackedWindowID: 42)
        XCTAssertNil(coordinator.state.selectedURL)
        XCTAssertEqual(coordinator.state.notice, .automation)
    }

    func testSettingsChangesRefreshActivePreviewKindAndHTMLTrust() async throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = try PreviewFixtures.directory(self)
        let pdf = directory.appendingPathComponent("sample.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: pdf)
        let page = directory.appendingPathComponent("index.html")
        try Data("<!doctype html><p>hi</p>".utf8).write(to: page)

        let store = SettingsStore(defaults: defaults)
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory))

        coordinator.applySelectionResult(.success(.init(windowID: 10, urls: [pdf])), trackedWindowID: 10)
        try await waitUntil { coordinator.state.kind == .pdf }
        let beforeDisable = coordinator.state.generation

        store.finderPreview.disabledKinds.insert(.pdf)
        try await waitUntil { coordinator.state.generation > beforeDisable && coordinator.state.kind == .quickLook }

        let beforeEnable = coordinator.state.generation
        store.finderPreview.disabledKinds.remove(.pdf)
        try await waitUntil { coordinator.state.generation > beforeEnable && coordinator.state.kind == .pdf }

        store.finderPreview.addTrustedFolder(directory)
        coordinator.applySelectionResult(.success(.init(windowID: 10, urls: [page])), trackedWindowID: 10)
        try await waitUntil { coordinator.state.kind == .html && coordinator.state.trust?.level == .trusted }
        XCTAssertEqual(
            try PreviewHTMLSnapshot.prepare(
                url: page, trustedFolders: store.finderPreview.trustedFolders,
                scriptConsent: coordinator.state.scriptConsent
            ).policy,
            .interactive)

        let beforeRevoke = coordinator.state.generation
        store.finderPreview.removeTrustedFolder(directory.path)
        try await waitUntil {
            coordinator.state.generation > beforeRevoke && coordinator.state.trust?.level == .standard
        }
        XCTAssertEqual(
            try PreviewHTMLSnapshot.prepare(
                url: page, trustedFolders: store.finderPreview.trustedFolders,
                scriptConsent: coordinator.state.scriptConsent
            ).policy,
            .staticPreview)

        let beforeTrustAgain = coordinator.state.generation
        store.finderPreview.addTrustedFolder(directory)
        try await waitUntil {
            coordinator.state.generation > beforeTrustAgain && coordinator.state.trust?.level == .trusted
        }

        let stableGeneration = coordinator.state.generation
        store.finderPreview.codeFontSize = 18
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(coordinator.state.generation, stableGeneration)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Condition was not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
