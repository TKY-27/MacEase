import AppKit
import Engine
import XCTest

@testable import MacEase

final class FinderStorageBarGeometryTests: XCTestCase {
    private let height = FinderStorageBarGeometry.Calibration.statusBarHeight

    func testStripCoversOnlyTheBottomEdgeOnEveryDisplay() throws {
        let windows = [
            CGRect(x: 100, y: 200, width: 900, height: 700),
            CGRect(x: -1600, y: -300, width: 640, height: 420),
            CGRect(x: 1920, y: 1200, width: 1280, height: 900),
        ]
        for window in windows {
            let placement = try XCTUnwrap(
                FinderStorageBarGeometry.placement(window: window, preview: nil, statusBarShown: true))
            XCTAssertEqual(placement.frame, CGRect(x: window.minX, y: window.minY, width: window.width, height: height))
            XCTAssertTrue(window.contains(placement.frame))
            XCTAssertTrue(placement.roundsLeadingCorner)
            XCTAssertTrue(placement.roundsTrailingCorner)
        }
    }

    func testHiddenWhenFinderShowsNoStatusBar() {
        let window = CGRect(x: 100, y: 200, width: 900, height: 700)
        XCTAssertNil(FinderStorageBarGeometry.placement(window: window, preview: nil, statusBarShown: false))
    }

    func testPreviewDockedBesideTheWindowLeavesTheStripWhole() throws {
        let screen = CGRect(x: 0, y: 30, width: 1600, height: 950)
        let right = CGRect(x: 100, y: 200, width: 900, height: 700)
        let left = CGRect(x: 700, y: 200, width: 900, height: 700)
        for (window, dock) in [(right, FinderPreviewGeometry.Dock.right), (left, .left)] {
            let preview = FinderPreviewGeometry.placement(window: window, screen: screen, width: 360)
            XCTAssertEqual(preview.dock, dock)
            let strip = try XCTUnwrap(
                FinderStorageBarGeometry.placement(window: window, preview: preview, statusBarShown: true))
            XCTAssertEqual(strip.frame.width, window.width)
            XCTAssertFalse(strip.frame.intersects(preview.frame), "\(dock)")
        }
    }

    func testInsetPreviewTrimsTheStripAndSquaresTheCutCorner() throws {
        let screen = CGRect(x: 0, y: 30, width: 1600, height: 950)
        let preview = FinderPreviewGeometry.placement(window: screen, screen: screen, width: 360)
        XCTAssertEqual(preview.dock, .inset)
        let strip = try XCTUnwrap(
            FinderStorageBarGeometry.placement(window: screen, preview: preview, statusBarShown: true))
        XCTAssertEqual(strip.frame, CGRect(x: 0, y: 30, width: 1240, height: height))
        XCTAssertFalse(strip.frame.intersects(preview.frame))
        XCTAssertTrue(strip.roundsLeadingCorner)
        XCTAssertFalse(strip.roundsTrailingCorner)
    }

    func testTooLittleRoomHidesTheStrip() {
        let tiny = CGRect(x: 0, y: 0, width: 150, height: 300)
        XCTAssertNil(FinderStorageBarGeometry.placement(window: tiny, preview: nil, statusBarShown: true))
        let short = CGRect(x: 0, y: 0, width: 600, height: height)
        XCTAssertNil(FinderStorageBarGeometry.placement(window: short, preview: nil, statusBarShown: true))
        let smallScreen = CGRect(x: 0, y: 0, width: 300, height: 600)
        let inset = FinderPreviewGeometry.placement(window: smallScreen, screen: smallScreen, width: 360)
        XCTAssertEqual(inset.dock, .inset)
        XCTAssertNil(FinderStorageBarGeometry.placement(window: smallScreen, preview: inset, statusBarShown: true))
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let covering = FinderPreviewGeometry.Placement(
            frame: CGRect(x: -10, y: 0, width: 420, height: 300), dock: .inset)
        XCTAssertNil(FinderStorageBarGeometry.placement(window: window, preview: covering, statusBarShown: true))
    }
}

final class StorageVolumeTests: XCTestCase {
    func testAvailableSpaceCountsPurgeableFilesWhenTheVolumeReportsThem() throws {
        let apfs = StorageVolume(
            name: "Macintosh HD", total: 994_610_155_520, available: 44_242_358_272,
            availableForImportantUsage: 49_036_046_336)
        XCTAssertEqual(apfs.capacity?.available, 49_036_046_336)
        XCTAssertEqual(try XCTUnwrap(apfs.capacity?.usedFraction), 0.9507, accuracy: 0.0001)
        let diskImage = StorageVolume(
            name: "Installer", total: 582_717_440, available: 3_276_800, availableForImportantUsage: 0)
        XCTAssertEqual(diskImage.capacity?.available, 3_276_800)
        let network = StorageVolume(name: "Share", total: 1_000, available: 400, availableForImportantUsage: nil)
        XCTAssertEqual(network.capacity?.available, 400)
    }

    func testVolumesWithoutCapacityReportNone() {
        XCTAssertNil(StorageVolume(name: "Share", total: nil, available: 400, availableForImportantUsage: nil).capacity)
        XCTAssertNil(StorageVolume(name: "Share", total: 0, available: 0, availableForImportantUsage: 0).capacity)
        XCTAssertNil(
            StorageVolume(name: "Share", total: 1_000, available: nil, availableForImportantUsage: nil).capacity)
        let overReported = StorageVolume(name: "Share", total: 1_000, available: 5_000, availableForImportantUsage: nil)
        XCTAssertEqual(overReported.capacity?.available, 1_000)
    }

    func testVolumeIsTheLongestMountPointWithoutTouchingTheFolder() {
        let volumes = ["/", "/System/Volumes/Data", "/Volumes/USB", "/Volumes/USB/Nested"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let cases = [
            ("/Users/someone/Documents/Private", "/"),
            ("/Volumes/USB/Photos/a.jpg", "/Volumes/USB"),
            ("/Volumes/USB2/a.jpg", "/"),
            ("/Volumes/USB/Nested", "/Volumes/USB/Nested"),
            ("/Volumes/USB/./Photos/../a.jpg", "/Volumes/USB"),
        ]
        for (location, expected) in cases {
            XCTAssertEqual(
                StorageVolume.root(of: URL(fileURLWithPath: location), among: volumes)?.path, expected, location)
        }
        XCTAssertNil(StorageVolume.root(of: URL(fileURLWithPath: "/Users"), among: []))
    }

    func testStartupDiskReadsItsNameAndCapacity() throws {
        let volumes = try XCTUnwrap(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil))
        let root = try XCTUnwrap(StorageVolume.root(of: URL(fileURLWithPath: NSHomeDirectory()), among: volumes))
        let volume = try StorageVolume.read(volume: root)
        XCTAssertFalse(volume.name.isEmpty)
        let capacity = try XCTUnwrap(volume.capacity)
        XCTAssertGreaterThan(capacity.total, 0)
        XCTAssertLessThanOrEqual(capacity.available, capacity.total)
    }
}

final class SelectionSizeTests: XCTestCase {
    func testFilesFoldersAndPackagesAddUpWithoutFollowingSymlinks() throws {
        let directory = try PreviewFixtures.directory(self)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let large = outside.appendingPathComponent("large.bin")
        try Data(count: 50_000).write(to: large)

        let file = directory.appendingPathComponent("a.txt")
        try Data(count: 1_000).write(to: file)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 2_000).write(to: folder.appendingPathComponent("b.txt"))
        try Data(count: 3_000).write(to: nested.appendingPathComponent("c.txt"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("large link"), withDestinationURL: large)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("outside link"), withDestinationURL: outside)
        let package = directory.appendingPathComponent("Tool.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: contents.appendingPathComponent("Info.plist"))
        let selectedLink = directory.appendingPathComponent("selected link")
        try FileManager.default.createSymbolicLink(at: selectedLink, withDestinationURL: large)
        let linkSize = try XCTUnwrap(selectedLink.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize)
        XCTAssertLessThan(linkSize, 1_000)

        XCTAssertEqual(try SelectionSize.total(of: [file], limits: .standard), 1_000)
        XCTAssertEqual(try SelectionSize.total(of: [folder], limits: .standard), 5_000)
        XCTAssertEqual(try SelectionSize.total(of: [package], limits: .standard), 4_000)
        XCTAssertEqual(try SelectionSize.total(of: [selectedLink], limits: .standard), Int64(linkSize))
        XCTAssertEqual(
            try SelectionSize.total(of: [file, folder, package, selectedLink], limits: .standard),
            10_000 + Int64(linkSize))
    }

    func testLimitsStopTheWalkWithoutAPartialTotal() throws {
        let folder = try folderOfFiles(count: 5)
        XCTAssertEqual(try SelectionSize.total(of: [folder], limits: .init(entries: 5, duration: .seconds(10))), 500)
        XCTAssertNil(try SelectionSize.total(of: [folder], limits: .init(entries: 4, duration: .seconds(10))))
        XCTAssertNil(try SelectionSize.total(of: [folder], limits: .init(entries: 100, duration: .zero)))
    }

    func testCancellationStopsTheWalk() async throws {
        let folder = try folderOfFiles(count: 5)
        let walk = Task.detached { () throws -> Int64? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try SelectionSize.total(of: [folder], limits: .standard)
        }
        do {
            _ = try await walk.value
            XCTFail("A cancelled walk must not return a total")
        } catch is CancellationError {}
    }

    func testUnreadableFoldersGiveNoPartialTotal() throws {
        let folder = try folderOfFiles(count: 2)
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 100).write(to: locked.appendingPathComponent("hidden.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        XCTAssertThrowsError(try SelectionSize.total(of: [folder], limits: .standard))
    }

    func testMissingItemsThrow() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SelectionSize.total(of: [missing], limits: .standard))
    }

    private func folderOfFiles(count: Int) throws -> URL {
        let folder = try PreviewFixtures.directory(self).appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data(count: 100).write(to: folder.appendingPathComponent("\(index).bin"))
        }
        return folder
    }
}

final class FinderStorageBarTextTests: XCTestCase {
    private let volume = StorageVolume(
        name: "Macintosh HD", total: 994_000_000_000, available: 200_000_000_000,
        availableForImportantUsage: 212_000_000_000)

    func testEnglishMatchesFinderWording() throws {
        let text = try self.text("en", locale: "en_US")
        XCTAssertEqual(text.name(volume, startupDisk: false), "Macintosh HD")
        XCTAssertEqual(text.name(volume, startupDisk: true), "Macintosh HD (Startup Disk)")
        XCTAssertEqual(text.capacity(volume), "212 GB available of 994 GB")
        let share = StorageVolume(name: "Share", total: nil, available: nil, availableForImportantUsage: nil)
        XCTAssertEqual(text.capacity(share), "Capacity unavailable")
        XCTAssertEqual(
            text.selection(.measured(count: 3, bytes: 1_200_000_000), includesSize: true), "3 selected, 1.2 GB")
        XCTAssertEqual(text.selection(.measured(count: 3, bytes: 1_200_000_000), includesSize: false), "3 selected")
        XCTAssertEqual(text.selection(.measuring(count: 1), includesSize: true), "1 selected, Calculating…")
        XCTAssertEqual(text.selection(.unmeasured(count: 120), includesSize: true), "120 selected")
    }

    func testJapaneseMatchesFinderWording() throws {
        let text = try self.text("ja", locale: "ja_JP")
        XCTAssertEqual(text.name(volume, startupDisk: true), "Macintosh HD（起動ディスク）")
        XCTAssertEqual(text.capacity(volume), "994 GB中212 GB空き")
        let share = StorageVolume(name: "Share", total: nil, available: nil, availableForImportantUsage: nil)
        XCTAssertEqual(text.capacity(share), "容量を取得できません")
        XCTAssertEqual(text.selection(.measured(count: 3, bytes: 1_200_000_000), includesSize: true), "3項目を選択、1.2 GB")
        XCTAssertEqual(text.selection(.measuring(count: 1), includesSize: true), "1項目を選択、計算中…")
        XCTAssertEqual(text.selection(.unmeasured(count: 120), includesSize: true), "120項目を選択")
    }

    func testVoiceOverReadsOneSentence() throws {
        let english = try text("en", locale: "en_US")
        XCTAssertEqual(
            english.accessibilityValue(
                volume, startupDisk: false, selection: .measured(count: 3, bytes: 1_200_000_000)),
            "Macintosh HD, 212 GB available of 994 GB, 3 selected, 1.2 GB")
        XCTAssertEqual(
            english.accessibilityValue(volume, startupDisk: true, selection: nil),
            "Macintosh HD (Startup Disk), 212 GB available of 994 GB")
        let japanese = try text("ja", locale: "ja_JP")
        XCTAssertEqual(
            japanese.accessibilityValue(volume, startupDisk: false, selection: .unmeasured(count: 2)),
            "Macintosh HD、994 GB中212 GB空き、2項目を選択")
    }

    private func text(_ language: String, locale: String) throws -> FinderStorageBarText {
        let bundle = try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
        return FinderStorageBarText(bundle: bundle, locale: Locale(identifier: locale))
    }
}

@MainActor
final class FinderStorageBarModelTests: XCTestCase {
    func testNewSelectionDiscardsAnEarlierMeasurement() async throws {
        let directory = try PreviewFixtures.directory(self)
        let folder = directory.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<2_000 {
            try Data(count: 10).write(to: folder.appendingPathComponent("\(index)"))
        }
        let file = directory.appendingPathComponent("one.bin")
        try Data(count: 1_234).write(to: file)
        let model = FinderStorageBarModel()
        model.update(urls: [folder], folder: directory)
        model.update(urls: [file], folder: directory)
        try await waitUntil { model.selection == .measured(count: 1, bytes: 1_234) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.selection, .measured(count: 1, bytes: 1_234))
        model.update(urls: [], folder: directory)
        XCTAssertNil(model.selection)
    }

    func testReachingTheLimitShowsTheCountWithoutASize() async throws {
        let directory = try PreviewFixtures.directory(self)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(count: 10).write(to: folder.appendingPathComponent("\(index)"))
        }
        let model = FinderStorageBarModel(limits: .init(entries: 2, duration: .seconds(10)))
        model.update(urls: [folder], folder: directory)
        try await waitUntil { model.selection == .unmeasured(count: 1) }
    }

    func testUnknownFolderFallsBackToTheLabelledStartupDisk() async throws {
        let directory = try PreviewFixtures.directory(self)
        let file = directory.appendingPathComponent("one.bin")
        try Data(count: 10).write(to: file)
        let model = FinderStorageBarModel()
        model.update(urls: nil, folder: nil)
        try await waitUntil { model.volume != nil }
        XCTAssertTrue(model.showsStartupDisk)
        XCTAssertNil(model.selection)

        model.update(urls: [file], folder: directory)
        try await waitUntil { !model.showsStartupDisk && model.selection == .measured(count: 1, bytes: 10) }

        model.update(urls: nil, folder: nil)
        XCTAssertNil(model.selection)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.showsStartupDisk, "The last known folder keeps its volume")

        model.forgetLocation()
        model.update(urls: nil, folder: nil)
        try await waitUntil { model.showsStartupDisk }
    }
}

@MainActor
final class FinderStorageBarPresenceTests: XCTestCase {
    private let window = FinderStorageBar.Window(
        id: 0, frame: CGRect(x: 120, y: 140, width: 820, height: 560), preview: nil)

    func testStripFollowsTheWindowAndReturnsWithIt() async throws {
        let directory = try PreviewFixtures.directory(self)
        let bar = FinderStorageBar(readsStatusBar: { true })
        bar.start()
        addTeardownBlock { @MainActor in bar.stop() }
        bar.model.update(urls: [], folder: directory)
        bar.follow(window)
        try await waitUntil { bar.isVisible }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? FinderStorageBarPanel }.first { $0.isVisible })
        XCTAssertEqual(panel.frame, CGRect(x: 120, y: 140, width: 820, height: 20))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)

        bar.follow(nil)
        XCTAssertFalse(bar.isVisible)
        XCTAssertFalse(bar.wantsSelection)
        bar.follow(window)
        XCTAssertTrue(bar.isVisible)
        XCTAssertFalse(bar.model.showsStartupDisk)

        bar.follow(nil)
        bar.follow(.init(id: 7, frame: window.frame, preview: nil))
        bar.model.update(urls: nil, folder: nil)
        try await waitUntil { bar.model.showsStartupDisk }

        bar.stop()
        XCTAssertFalse(bar.isVisible)
        XCTAssertNil(bar.model.volume)
    }

    func testHiddenFinderStatusBarShowsNothing() async throws {
        let directory = try PreviewFixtures.directory(self)
        let bar = FinderStorageBar(readsStatusBar: { false })
        bar.start()
        addTeardownBlock { @MainActor in bar.stop() }
        bar.model.update(urls: [], folder: directory)
        try await waitUntil { bar.model.volume != nil }
        bar.follow(window)
        XCTAssertFalse(bar.isVisible)
        XCTAssertFalse(bar.wantsSelection)
    }
}

@MainActor
final class FinderStorageBarCoordinatorTests: XCTestCase {
    func testStorageBarSettingDefaultsOnAndPersists() throws {
        let (store, defaults) = try makeStore()
        XCTAssertTrue(store.finderStorageBarEnabled)
        store.finderStorageBarEnabled = false
        XCTAssertFalse(defaults.bool(forKey: "finderStorageBar.enabled"))
        XCTAssertFalse(SettingsStore(defaults: defaults).finderStorageBarEnabled)
        store.resetAll()
        XCTAssertTrue(SettingsStore(defaults: defaults).finderStorageBarEnabled)
        XCTAssertFalse(store.finderPreviewEnabled)
    }

    func testOneSelectionResultFeedsThePreviewAndTheStorageBar() async throws {
        let (store, _) = try makeStore()
        store.finderPreviewEnabled = true
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let coordinator = makeCoordinator(store, directory)

        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [note], folder: directory)), trackedWindowID: 42)
        XCTAssertEqual(coordinator.state.urls, [note])
        let model = coordinator.storageBar.model
        try await waitUntil { model.selection == .measured(count: 1, bytes: 5) && model.volume != nil }
        XCTAssertFalse(model.showsStartupDisk)
        try await waitUntil { coordinator.state.kind == .text }
    }

    func testMissingAutomationKeepsCapacityAndDropsTheSelection() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let coordinator = makeCoordinator(store, directory)
        let model = coordinator.storageBar.model

        coordinator.applySelectionResult(.failure(.automationDenied), trackedWindowID: 42)
        try await waitUntil { model.volume != nil }
        XCTAssertTrue(model.showsStartupDisk)
        XCTAssertNil(model.selection)

        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [note], folder: directory)), trackedWindowID: 42)
        try await waitUntil { model.selection != nil && !model.showsStartupDisk }
        coordinator.applySelectionResult(.failure(.automationDenied), trackedWindowID: 42)
        XCTAssertNil(model.selection)
        XCTAssertNotNil(model.volume)
    }

    func testTransientFailuresKeepTheStorageSelection() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let coordinator = makeCoordinator(store, directory)
        let model = coordinator.storageBar.model
        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [note], folder: directory)), trackedWindowID: 42)
        try await waitUntil { model.selection == .measured(count: 1, bytes: 5) }
        for _ in 1..<FinderPreviewCoordinator.transientFailureThreshold {
            coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42)
        }
        XCTAssertEqual(model.selection, .measured(count: 1, bytes: 5))
        coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42)
        XCTAssertNil(model.selection)
    }

    func testMissingAccessibilityShowsNothing() throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let coordinator = makeCoordinator(store, directory)
        coordinator.start()
        XCTAssertFalse(coordinator.storageBar.isVisible)
        XCTAssertFalse(coordinator.storageBar.wantsSelection)
        XCTAssertFalse(NSApp.windows.contains { $0 is FinderPreviewPanel && $0.isVisible })
    }

    func testTurningTheSettingOffRemovesTheStrip() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let coordinator = makeCoordinator(store, directory)
        coordinator.start()
        let bar = coordinator.storageBar
        bar.start()
        bar.model.update(urls: [], folder: directory)
        bar.follow(.init(id: 0, frame: CGRect(x: 100, y: 100, width: 800, height: 500), preview: nil))
        try await waitUntil { bar.isVisible }

        store.finderStorageBarEnabled = false
        try await waitUntil { !bar.isVisible && bar.model.volume == nil }
        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [directory], folder: directory)), trackedWindowID: 42)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(bar.model.volume)
        XCTAssertNil(bar.model.selection)
    }

    private func makeStore() throws -> (SettingsStore, UserDefaults) {
        let suite = "FinderStorageBarTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (SettingsStore(defaults: defaults), defaults)
    }

    private func makeCoordinator(_ store: SettingsStore, _ directory: URL) -> FinderPreviewCoordinator {
        FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }), isTrusted: { false })
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(3), condition: @MainActor () -> Bool) async throws {
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
