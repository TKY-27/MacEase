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
            japanese.localizedString(forKey: "Hide Finder Preview", value: nil, table: nil), "Finderプレビューを閉じる")
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
}
