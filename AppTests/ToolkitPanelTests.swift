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
        let edit = MenuGroupID(rawValue: "video.edit")
        XCTAssertEqual(store.hiddenEntries, ["image.convert/png"])
        XCTAssertEqual(store.menuScope(.video).section(of: edit), .hidden)
        XCTAssertNil(defaults.object(forKey: "hiddenOperations"))
        var changes = 0
        store.onChange = { changes += 1 }
        let convert = MenuGroupID(rawValue: "image.convert")
        store.rearrangeMenu(.image) { $0.move([convert], to: .more) }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.hiddenEntries, ["image.convert/png"])
        store.rearrangeMenu(.video) { $0.show([edit]) }
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.menuScope(.video).section(of: edit), .menu)
        XCTAssertEqual(restored.menuScope(.image).section(of: convert), .more)
        restored.resetAll()
        XCTAssertFalse(restored.menuArrangement.isCustomized(.image))
        XCTAssertFalse(SettingsStore(defaults: defaults).menuArrangement.isCustomized(.image))
    }

    func testLegacyHiddenTrimMigratesToEditing() throws {
        let suite = "MacEaseToolkitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["video.trim", "image.copyBase64", "video.aiCustom", "audio.aiCustom"], forKey: "hiddenOperations")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hiddenEntries, [])
        XCTAssertEqual(store.menuScope(.video).section(of: MenuGroupID(rawValue: "video.edit")), .hidden)
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
