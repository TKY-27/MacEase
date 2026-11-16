import AppKit
import XCTest

@testable import MacEase

@MainActor
final class FinderPreviewToggleTests: XCTestCase {
    func testMenuTitleNamesTheNextAction() throws {
        XCTAssertEqual(MenuStrings.previewTitle(open: true), String(localized: "Hide Finder Preview"))
        XCTAssertEqual(MenuStrings.previewTitle(open: false), String(localized: "Show Finder Preview"))
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(
            japanese.localizedString(forKey: "Hide Finder Preview", value: nil, table: nil), "Finderプレビューを閉じる")
        XCTAssertEqual(
            japanese.localizedString(forKey: "Show Finder Preview", value: nil, table: nil), "Finderプレビューを表示")
    }

    func testEscapeAndCommandWCloseThePanelButOtherKeysDoNot() throws {
        let suite = "FinderPreviewToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let panel = FinderPreviewPanel(content: NSView(), docked: true, defaults: defaults)
        var closeRequests = 0
        panel.closeRequested = { closeRequests += 1 }
        let keys: [(String, NSEvent.ModifierFlags, Int)] = [
            ("\u{1B}", [], 1), ("w", .command, 2), ("w", [], 2), ("\u{1B}", .shift, 2), ("q", .command, 2),
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
