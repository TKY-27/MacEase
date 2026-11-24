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
    private let imageRotate = MenuGroupID(rawValue: "image.rotate")
    private let videoRotate = MenuGroupID(rawValue: "video.rotate")
    private let legacyPlacements = ["image.convert": "more", "video.rotate": "primary"]
    private let newInstallResize: Set<String> = ["image.resize/long-3840", "image.resize/long-2560"]

    private func makeDefaults() throws -> UserDefaults {
        let suite = "MacEaseMenuArrangementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func menu(store: SettingsStore) -> MenuFile {
        MenuFile(
            token: "token", hostAvailable: true, visibleOperations: OperationID.allCases,
            titles: MenuStrings.titles(settings: store.settings), hiddenEntries: store.hiddenEntries,
            extraRotationDegrees: store.settings.extraRotationEnabled ? store.settings.extraRotationDegrees : nil,
            arrangement: store.menuArrangement, commandTitles: [.preview: MenuStrings.previewTitle(open: false)])
    }

    /// Group IDs in Finder order, per placement.
    private func shownGroups(_ file: MenuFile, selecting name: String) -> [MenuPlacement: [String]] {
        func entryIndices(_ nodes: [MenuNode]) -> [Int] {
            nodes.flatMap { node -> [Int] in
                switch node {
                case .action(_, let index): [index]
                case .submenu(_, let children): entryIndices(children)
                case .command, .separator: []
                }
            }
        }
        let tree = MenuLayout.tree(for: file, selection: [URL(fileURLWithPath: "/missing/\(name)")])
        var groups: [MenuPlacement: [String]] = [:]
        for entry in entryIndices(tree.finder + tree.macEase).map({ file.entries[$0] })
        where groups[entry.placement]?.last != entry.resolvedGroupID {
            groups[entry.placement, default: []].append(entry.resolvedGroupID)
        }
        return groups
    }

    func testLegacySettingsMigrateOnceToTheSameMenu() throws {
        let defaults = try makeDefaults()
        let legacyHidden = Set(ocr.entryKeys + resize.entryKeys + ["image.convert/png"])
        defaults.set(legacyPlacements, forKey: "menuPlacements")
        defaults.set(legacyHidden.sorted(), forKey: "hiddenMenuEntries")

        let store = SettingsStore(defaults: defaults)
        let migrated = menu(store: store)
        // Frozen from LegacyMenuOracle for these legacy settings.
        let anyKind = ["files.finish", "any.share", "any.findRelated", "any.protect", "any.checksum"]
        XCTAssertEqual(
            shownGroups(migrated, selecting: "a.png"),
            [
                .primary: ["image.edit", "image.compress", "image.rotate", "image.background"],
                .more: [
                    "image.convert", "image.enhance", "image.toPDF", "image.iconSet", "image.traceSVG",
                    "image.trimBorders", "image.stripMetadata", "image.aiRename",
                ] + anyKind,
            ])
        XCTAssertEqual(
            shownGroups(migrated, selecting: "a.mov"),
            [
                .primary: [
                    "video.edit", "video.convert", "video.compress", "video.resize", "video.extractAudio",
                    "video.thumbnail", "video.subtitles", "video.rotate",
                ],
                .more: ["video.speed", "video.removeAudio", "video.fps", "video.background"] + anyKind,
            ])
        XCTAssertFalse(migrated.entries.contains { $0.op == .imageConvert && $0.preset == "png" })
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

    func testTurningOffTheOnlyCheckedExtraAngleHidesRotateInBothScopes() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        let rotations = [MenuScope.image: imageRotate, .video: videoRotate]
        store.settings.extraRotationEnabled = true
        store.hiddenEntries.formUnion(
            rotations.values.flatMap(\.entryKeys).filter { !$0.hasSuffix("/\(OperationID.extraAnglePreset)") })
        for (scope, group) in rotations {
            XCTAssertNotEqual(store.menuScope(scope).section(of: group), .hidden)
        }

        store.settings.extraRotationEnabled = false
        for (scope, group) in rotations {
            XCTAssertEqual(store.menuScope(scope).section(of: group), .hidden)
        }
        assertShownGroupsReachFinder(store)

        store.rearrangeMenu(.image) { $0.show([self.imageRotate]) }
        XCTAssertEqual(store.menuScope(.image).section(of: imageRotate), .menu)
        XCTAssertTrue(menu(store: store).entries.contains { $0.resolvedGroupID == self.imageRotate.rawValue })
    }

    func testUncheckingEveryLeafHidesTheGroup() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        store.hiddenEntries.formUnion(compress.entryKeys)
        XCTAssertEqual(store.menuScope(.image).section(of: compress), .hidden)
        XCTAssertTrue(store.hiddenEntries.isDisjoint(with: compress.entryKeys))
        assertShownGroupsReachFinder(store)
    }

    func testDefaultMenusNeedNoFolding() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        for scope in MenuScope.allCases {
            store.restoreMenuDefaults(scope)
        }
        for scope in MenuScope.allCases {
            XCTAssertTrue(store.isMenuDefault(scope), "\(scope)")
        }
        assertShownGroupsReachFinder(store)
    }

    private func assertShownGroupsReachFinder(_ store: SettingsStore, line: UInt = #line) {
        let reached = Set(menu(store: store).entries.map(\.resolvedGroupID))
        for scope in MenuScope.allCases {
            let arrangement = store.menuScope(scope)
            for group in arrangement.groups
            where arrangement.section(of: group) != .hidden && !group.entryKeys.isEmpty {
                XCTAssertTrue(reached.contains(group.rawValue), "\(group.rawValue) shown but empty", line: line)
            }
        }
    }
}
