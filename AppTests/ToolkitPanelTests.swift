import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class ToolkitPanelTests: XCTestCase {
    func testRemovedVisibilityMigratesOnceAndPlacementsPersistIndependently() throws {
        let suite = "MacEaseToolkitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["video.trim/", "image.copyBase64/", "any.sourceInfo/", "image.aiCustom/", "image.convert/png"],
            forKey: "hiddenMenuEntries")
        defaults.set(["video.trim", "any.sourceInfo"], forKey: "hiddenOperations")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hiddenEntries, ["video.edit/", "image.convert/png"])
        XCTAssertNil(defaults.object(forKey: "hiddenOperations"))
        var changes = 0
        store.onChange = { changes += 1 }
        store.menuPlacements["image.convert"] = .more
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.hiddenEntries, ["video.edit/", "image.convert/png"])
        store.hiddenEntries.remove("video.edit/")
        let restored = SettingsStore(defaults: defaults)
        XCTAssertFalse(restored.hiddenEntries.contains("video.edit/"))
        XCTAssertEqual(restored.menuPlacements, ["image.convert": .more])
        restored.resetAll()
        XCTAssertTrue(restored.menuPlacements.isEmpty)
        XCTAssertTrue(SettingsStore(defaults: defaults).menuPlacements.isEmpty)
    }

    func testLegacyHiddenTrimMigratesToEditing() throws {
        let suite = "MacEaseToolkitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["video.trim", "image.copyBase64", "video.aiCustom", "audio.aiCustom"], forKey: "hiddenOperations")
        XCTAssertEqual(SettingsStore(defaults: defaults).hiddenEntries, ["video.edit/"])
        XCTAssertNil(defaults.object(forKey: "hiddenOperations"))
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
