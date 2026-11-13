import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class ToolkitPanelTests: XCTestCase {
    func testSourceInspectionMigrationPreservesLaterVisibilityChoice() throws {
        let suite = "MacEaseToolkitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([], forKey: "hiddenMenuEntries")
        let store = SettingsStore(defaults: defaults)
        let key = OperationID.anySourceInfo.menuEntryKey("")
        XCTAssertTrue(store.hiddenEntries.contains(key))
        store.hiddenEntries.remove(key)
        XCTAssertFalse(SettingsStore(defaults: defaults).hiddenEntries.contains(key))
        store.resetAll()
        XCTAssertTrue(store.hiddenEntries.contains(key))
    }

    func testGalleryModeClearsMediaOptionsAndPendingSelection() async {
        let model = MediaDownloadModel(destination: URL(filePath: "/tmp"))
        model.resolution = 1080
        model.selectedIDs = ["previous-video"]
        model.images = true
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.subtitle)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertFalse(model.canDownload)
        XCTAssertEqual(MediaDownloadKind.images.formats, [.source])
        await model.close()
    }

    func testProtectionClearsSecretsWhenDismissed() {
        let model = FileProtectionModel(source: URL(filePath: "/tmp/example.age")) { _ in
            XCTFail("Closing a panel must not submit a job")
        }
        XCTAssertTrue(model.decrypt)
        model.password = "test-only passphrase"
        model.confirmation = "test-only passphrase"
        XCTAssertTrue(model.canRun)
        model.close()
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertTrue(model.confirmation.isEmpty)
        XCTAssertFalse(model.canRun)
    }
}
