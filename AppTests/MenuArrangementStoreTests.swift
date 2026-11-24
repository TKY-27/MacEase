import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class MenuArrangementStoreTests: XCTestCase {
    private let convert = MenuGroupID(rawValue: "image.convert")
    private let resize = MenuGroupID(rawValue: "image.resize")
    private let ocr = MenuGroupID(rawValue: "image.ocr")
    private let compress = MenuGroupID(rawValue: "image.compress")
    private let legacyPlacements = ["image.convert": "more", "video.rotate": "primary"]
    private let newInstallResize: Set<String> = ["image.resize/long-3840", "image.resize/long-2560"]

    private func makeDefaults() throws -> UserDefaults {
        let suite = "MacEaseMenuArrangementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func menu(hidden: Set<String>, arrangement: MenuArrangement) -> MenuFile {
        MenuFile(
            token: "token", hostAvailable: true, visibleOperations: OperationID.allCases,
            titles: MenuStrings.titles(settings: Settings()), hiddenEntries: hidden, arrangement: arrangement,
            commandTitles: [.preview: MenuStrings.previewTitle(open: false)])
    }

    func testLegacySettingsMigrateOnceToTheSameMenu() throws {
        let defaults = try makeDefaults()
        let legacyHidden = Set(ocr.entryKeys + resize.entryKeys + ["image.convert/png"])
        defaults.set(legacyPlacements, forKey: "menuPlacements")
        defaults.set(legacyHidden.sorted(), forKey: "hiddenMenuEntries")
        let shipped = menu(
            hidden: legacyHidden,
            arrangement: MenuArrangement.migrating(
                placements: legacyPlacements.compactMapValues(MenuPlacement.init(rawValue:)),
                hiddenEntries: legacyHidden, newInstallHidden: [], extraAngleEnabled: false
            ).arrangement)

        let store = SettingsStore(defaults: defaults)
        let migrated = menu(hidden: store.hiddenEntries, arrangement: store.menuArrangement)
        XCTAssertEqual(migrated.entries.map(\.path), shipped.entries.map(\.path))
        XCTAssertEqual(migrated.catalogVersion, shipped.catalogVersion)
        XCTAssertEqual(store.menuScope(.image).section(of: convert), .more)
        XCTAssertEqual(store.menuScope(.video).section(of: MenuGroupID(rawValue: "video.rotate")), .menu)
        XCTAssertEqual(Set(store.menuScope(.image)[.hidden]), [ocr, resize])
        XCTAssertEqual(store.hiddenEntries, newInstallResize.union(["image.convert/png"]))
        XCTAssertNil(defaults.object(forKey: "menuPlacements"))

        store.rearrangeMenu(.image) { $0.move([self.convert], to: .menu, at: 0) }
        let edited = store.menuArrangement
        defaults.set(legacyPlacements, forKey: "menuPlacements")
        let relaunched = SettingsStore(defaults: defaults)
        XCTAssertEqual(relaunched.menuArrangement, edited)
        XCTAssertEqual(relaunched.menuScope(.image)[.menu].first, convert)
        XCTAssertEqual(relaunched.hiddenEntries, store.hiddenEntries)
        XCTAssertNil(defaults.object(forKey: "menuPlacements"))
    }

    func testResetAllClearsTheArrangement() throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.rearrangeMenu(.image) { $0.hide([self.convert]) }
        store.rearrangeMenu(.commands) { $0.move([MenuGroupID(.preview)], to: .more) }
        store.resetAll()
        XCTAssertEqual(store.menuArrangement, MenuArrangement())
        XCTAssertEqual(SettingsStore(defaults: defaults).menuArrangement, MenuArrangement())
    }

    func testUnreadableArrangementIsKeptAsideAndDefaultsApply() throws {
        for stored: Any in [
            Data("{".utf8), Data(#"{"version":2,"scopes":{}}"#.utf8), "not data",
        ] {
            let defaults = try makeDefaults()
            defaults.set(stored, forKey: "menu.arrangement")
            defaults.set(legacyPlacements, forKey: "menuPlacements")
            let store = SettingsStore(defaults: defaults)
            XCTAssertEqual(store.menuArrangement, MenuArrangement())
            XCTAssertEqual(
                defaults.object(forKey: "menu.arrangement.unreadable") as? NSObject, stored as? NSObject)
            XCTAssertEqual(defaults.object(forKey: "menu.arrangement") as? NSObject, stored as? NSObject)
            store.rearrangeMenu(.image) { $0.hide([self.convert]) }
            XCTAssertEqual(SettingsStore(defaults: defaults).menuScope(.image).section(of: convert), .hidden)
        }
    }

    func testShowingAFullyUncheckedGroupRestoresItsLeafDefaults() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        store.hiddenEntries = []
        store.rearrangeMenu(.image) { $0.hide([self.resize, self.compress]) }
        store.hiddenEntries.formUnion(resize.entryKeys + ["image.compress/x"])
        store.rearrangeMenu(.image) { $0.move([self.resize, self.compress], to: .more) }
        XCTAssertEqual(store.hiddenEntries, newInstallResize.union(["image.compress/x"]))
        XCTAssertEqual(store.menuScope(.image)[.more].suffix(2), [compress, resize])
    }

    func testRestoreDefaultsResetsOrderAndLeavesOfOneScope() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        store.hiddenEntries = ["image.convert/png", "video.convert/mov"]
        store.rearrangeMenu(.image) { $0.hide([self.convert]) }
        store.rearrangeMenu(.video) { $0.move([MenuGroupID(rawValue: "video.convert")], to: .more) }
        let values = store.settings.menuValues
        store.restoreMenuDefaults(.image)
        XCTAssertFalse(store.menuArrangement.isCustomized(.image))
        XCTAssertTrue(store.menuArrangement.isCustomized(.video))
        XCTAssertEqual(
            store.hiddenEntries,
            newInstallResize.union([
                "image.convert/bmp", "image.convert/ico", "image.convert/icns", "video.convert/mov",
            ]))
        XCTAssertEqual(store.settings.menuValues, values)
    }

    func testDefaultStateTracksOrderAndLeavesPerScope() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        store.restoreMenuDefaults(.image)
        XCTAssertTrue(store.isMenuDefault(.image))
        store.hiddenEntries.insert("image.convert/png")
        XCTAssertFalse(store.isMenuDefault(.image))
        store.restoreMenuDefaults(.image)
        store.rearrangeMenu(.image) { $0.moveDown([self.convert]) }
        XCTAssertFalse(store.isMenuDefault(.image))
        store.restoreMenuDefaults(.image)
        XCTAssertTrue(store.isMenuDefault(.image))
    }
}
