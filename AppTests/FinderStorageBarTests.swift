import AppKit
import Engine
import XCTest
import os

@testable import MacEase

final class FinderStorageBarGeometryTests: XCTestCase {
    private let height = FinderStorageBarGeometry.Calibration.statusBarHeight
    private let sliderReserved = FinderStorageBarGeometry.Calibration.iconSliderReserved

    func testStripCoversOnlyTheBottomEdgeOnEveryDisplay() throws {
        let windows = [
            CGRect(x: 100, y: 200, width: 900, height: 700),
            CGRect(x: -1600, y: -300, width: 640, height: 420),
            CGRect(x: 1920, y: 1200, width: 1280, height: 900),
        ]
        for window in windows {
            for view in [FinderWindowView.list, .column, .gallery] {
                let placement = try XCTUnwrap(
                    FinderStorageBarGeometry.placement(window: window, preview: nil, statusBarShown: true, view: view))
                XCTAssertEqual(
                    placement.frame, CGRect(x: window.minX, y: window.minY, width: window.width, height: height))
                XCTAssertTrue(window.contains(placement.frame))
                XCTAssertTrue(placement.roundsLeadingCorner)
                XCTAssertTrue(placement.roundsTrailingCorner)
            }
        }
    }

    func testIconAndUnknownViewsLeaveTheIconSliderUncovered() throws {
        let window = CGRect(x: 100, y: 200, width: 900, height: 700)
        for view in [FinderWindowView.icon, .unknown] {
            let placement = try XCTUnwrap(
                FinderStorageBarGeometry.placement(window: window, preview: nil, statusBarShown: true, view: view))
            XCTAssertEqual(
                placement.frame,
                CGRect(x: window.minX, y: window.minY, width: window.width - sliderReserved, height: height))
            XCTAssertTrue(placement.roundsLeadingCorner)
            XCTAssertFalse(placement.roundsTrailingCorner)
        }
    }

    func testHiddenWhenFinderShowsNoStatusBar() {
        let window = CGRect(x: 100, y: 200, width: 900, height: 700)
        XCTAssertNil(
            FinderStorageBarGeometry.placement(window: window, preview: nil, statusBarShown: false, view: .list))
    }

    func testPreviewDockedBesideTheWindowLeavesTheStripWhole() throws {
        let screen = CGRect(x: 0, y: 30, width: 1600, height: 950)
        let right = CGRect(x: 100, y: 200, width: 900, height: 700)
        let left = CGRect(x: 700, y: 200, width: 900, height: 700)
        for (window, dock) in [(right, FinderPreviewGeometry.Dock.right), (left, .left)] {
            let preview = FinderPreviewGeometry.placement(window: window, screen: screen, width: 360)
            XCTAssertEqual(preview.dock, dock)
            let strip = try XCTUnwrap(
                FinderStorageBarGeometry.placement(window: window, preview: preview, statusBarShown: true, view: .list))
            XCTAssertEqual(strip.frame.width, window.width)
            XCTAssertFalse(strip.frame.intersects(preview.frame), "\(dock)")
        }
    }

    func testInsetPreviewTrimsTheStripAndSquaresTheCutCorner() throws {
        let screen = CGRect(x: 0, y: 30, width: 1600, height: 950)
        let preview = FinderPreviewGeometry.placement(window: screen, screen: screen, width: 360)
        XCTAssertEqual(preview.dock, .inset)
        let strip = try XCTUnwrap(
            FinderStorageBarGeometry.placement(window: screen, preview: preview, statusBarShown: true, view: .list))
        XCTAssertEqual(strip.frame, CGRect(x: 0, y: 30, width: 1240, height: height))
        XCTAssertFalse(strip.frame.intersects(preview.frame))
        XCTAssertTrue(strip.roundsLeadingCorner)
        XCTAssertFalse(strip.roundsTrailingCorner)

        let iconStrip = try XCTUnwrap(
            FinderStorageBarGeometry.placement(window: screen, preview: preview, statusBarShown: true, view: .icon))
        XCTAssertEqual(iconStrip.frame, CGRect(x: 0, y: 30, width: 1240, height: height))
        XCTAssertTrue(iconStrip.roundsLeadingCorner)
        XCTAssertFalse(iconStrip.roundsTrailingCorner)
    }

    func testLeadingCoverLeavesTheTrailingSideAndHonorsSlider() throws {
        let window = CGRect(x: 100, y: 30, width: 900, height: 700)
        let leadingCover = FinderPreviewGeometry.Placement(
            frame: CGRect(x: 100, y: 30, width: 300, height: 700), dock: .inset)
        let listStrip = try XCTUnwrap(
            FinderStorageBarGeometry.placement(
                window: window, preview: leadingCover, statusBarShown: true, view: .list))
        XCTAssertEqual(listStrip.frame, CGRect(x: 400, y: 30, width: 600, height: height))
        XCTAssertFalse(listStrip.roundsLeadingCorner)
        XCTAssertTrue(listStrip.roundsTrailingCorner)

        let iconStrip = try XCTUnwrap(
            FinderStorageBarGeometry.placement(
                window: window, preview: leadingCover, statusBarShown: true, view: .icon))
        XCTAssertEqual(iconStrip.frame, CGRect(x: 400, y: 30, width: 600 - sliderReserved, height: height))
        XCTAssertFalse(iconStrip.roundsLeadingCorner)
        XCTAssertFalse(iconStrip.roundsTrailingCorner)
    }

    func testTooLittleRoomHidesTheStrip() {
        let tiny = CGRect(x: 0, y: 0, width: 150, height: 300)
        XCTAssertNil(
            FinderStorageBarGeometry.placement(window: tiny, preview: nil, statusBarShown: true, view: .list))
        let narrowForSlider = CGRect(
            x: 0, y: 0, width: FinderStorageBarGeometry.minimumWidth + sliderReserved - 1, height: 300)
        XCTAssertNil(
            FinderStorageBarGeometry.placement(
                window: narrowForSlider, preview: nil, statusBarShown: true, view: .icon))
        XCTAssertNotNil(
            FinderStorageBarGeometry.placement(
                window: narrowForSlider, preview: nil, statusBarShown: true, view: .list))
        let short = CGRect(x: 0, y: 0, width: 600, height: height)
        XCTAssertNil(
            FinderStorageBarGeometry.placement(window: short, preview: nil, statusBarShown: true, view: .list))
        let smallScreen = CGRect(x: 0, y: 0, width: 300, height: 600)
        let inset = FinderPreviewGeometry.placement(window: smallScreen, screen: smallScreen, width: 360)
        XCTAssertEqual(inset.dock, .inset)
        XCTAssertNil(
            FinderStorageBarGeometry.placement(window: smallScreen, preview: inset, statusBarShown: true, view: .list))
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let covering = FinderPreviewGeometry.Placement(
            frame: CGRect(x: -10, y: 0, width: 420, height: 300), dock: .inset)
        XCTAssertNil(
            FinderStorageBarGeometry.placement(window: window, preview: covering, statusBarShown: true, view: .list))
    }
}

final class FinderSelectionReaderParsingTests: XCTestCase {
    func testParsesEncodedSpecialCharactersAndLocalhost() throws {
        let addresses = [
            "file:///Users/test/line%0Abreak.txt",
            "file:///Users/test/%22quoted%22.txt",
            "file:///Users/test/%E6%97%A5%E6%9C%AC%E8%AA%9E.txt",
            "file://localhost/Users/test/local.txt",
        ]
        let response = makeResponse(
            windowID: 12,
            selection: addresses.map(NSAppleEventDescriptor.init(string:)),
            folder: NSAppleEventDescriptor(string: "file:///Users/test/%E3%83%95%E3%82%A9%E3%83%AB%E3%83%80/"),
            view: NSAppleEventDescriptor(enumCode: 0x6C73_7677))
        let parsed = try FinderSelectionReader.parse(response).get()
        XCTAssertEqual(parsed.windowID, 12)
        XCTAssertEqual(
            parsed.urls.map(\.path),
            [
                "/Users/test/line\nbreak.txt",
                "/Users/test/\"quoted\".txt",
                "/Users/test/日本語.txt",
                "/Users/test/local.txt",
            ])
        XCTAssertEqual(parsed.folder?.path, "/Users/test/フォルダ")
        XCTAssertEqual(parsed.view, .list)
    }

    func testParsesMissingValueEmptyAndViewModesDefensively() throws {
        let missingValue = NSAppleEventDescriptor(typeCode: 0x6D73_6E67)
        let response = makeResponse(windowID: 5, selection: [], folder: missingValue, view: missingValue)
        let parsed = try FinderSelectionReader.parse(response).get()
        XCTAssertEqual(parsed.windowID, 5)
        XCTAssertTrue(parsed.urls.isEmpty)
        XCTAssertNil(parsed.folder)
        XCTAssertEqual(parsed.view, .unknown)
        XCTAssertTrue(parsed.view.showsIconSizeSlider)

        let emptyFolder = makeResponse(
            windowID: 6, selection: [], folder: NSAppleEventDescriptor(string: ""),
            view: NSAppleEventDescriptor(string: ""))
        let emptyParsed = try FinderSelectionReader.parse(emptyFolder).get()
        XCTAssertNil(emptyParsed.folder)
        XCTAssertEqual(emptyParsed.view, .unknown)

        let remoteFolder = makeResponse(
            windowID: 7, selection: [], folder: NSAppleEventDescriptor(string: "file://otherhost/Users/test"),
            view: NSAppleEventDescriptor(enumCode: 0x6963_6E76))
        let remoteParsed = try FinderSelectionReader.parse(remoteFolder).get()
        XCTAssertNil(remoteParsed.folder)
        XCTAssertEqual(remoteParsed.view, .icon)

        let viewCases: [(NSAppleEventDescriptor, FinderWindowView)] = [
            (NSAppleEventDescriptor(enumCode: 0x6963_6E76), .icon),
            (NSAppleEventDescriptor(enumCode: 0x6C73_7677), .list),
            (NSAppleEventDescriptor(enumCode: 0x636C_7677), .column),
            (NSAppleEventDescriptor(enumCode: 0x666C_7677), .gallery),
            (NSAppleEventDescriptor(enumCode: 0x7878_7878), .unknown),
            (NSAppleEventDescriptor(string: "list view"), .list),
            (NSAppleEventDescriptor(string: "column view"), .column),
            (NSAppleEventDescriptor(string: "flow view"), .gallery),
            (NSAppleEventDescriptor(string: "icon view"), .icon),
            (NSAppleEventDescriptor(string: "future view"), .unknown),
        ]
        for (descriptor, expected) in viewCases {
            XCTAssertEqual(FinderSelectionReader.windowView(descriptor), expected)
        }
    }

    func testRejectsRemoteHostMissingValueAndZeroWindowInSelection() {
        let missingValue = NSAppleEventDescriptor(typeCode: 0x6D73_6E67)
        let badResponses = [
            makeResponse(
                windowID: 0, selection: [], folder: NSAppleEventDescriptor(string: ""),
                view: NSAppleEventDescriptor(string: "")),
            makeResponse(
                windowID: 9, selection: [NSAppleEventDescriptor(string: "file://otherhost/Users/a.txt")],
                folder: NSAppleEventDescriptor(string: ""), view: NSAppleEventDescriptor(string: "")),
            makeResponse(
                windowID: 9, selection: [missingValue],
                folder: NSAppleEventDescriptor(string: ""), view: NSAppleEventDescriptor(string: "")),
            makeResponse(
                windowID: 9, selection: [NSAppleEventDescriptor(string: "")],
                folder: NSAppleEventDescriptor(string: ""), view: NSAppleEventDescriptor(string: "")),
            NSAppleEventDescriptor.list(),
        ]
        for response in badResponses {
            if case .success = FinderSelectionReader.parse(response) {
                XCTFail("Malformed selection response must fail")
            }
        }
    }

    private func makeResponse(
        windowID: Int32, selection: [NSAppleEventDescriptor], folder: NSAppleEventDescriptor,
        view: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(int32: windowID), at: 1)
        let items = NSAppleEventDescriptor.list()
        for (offset, descriptor) in selection.enumerated() {
            items.insert(descriptor, at: offset + 1)
        }
        list.insert(items, at: 2)
        list.insert(folder, at: 3)
        list.insert(view, at: 4)
        return list
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
            ("/Volumes/USB/Nested", "/Volumes/USB/Nested"),
            ("/Volumes/USB/Nested2/a.jpg", "/Volumes/USB"),
            ("/Volumes/USB/./Photos/../a.jpg", "/Volumes/USB"),
        ]
        for (location, expected) in cases {
            XCTAssertEqual(
                StorageVolume.root(of: URL(fileURLWithPath: location), among: volumes)?.path, expected, location)
        }
        // Ejected /Volumes mounts fall back as unknown.
        XCTAssertNil(StorageVolume.root(of: URL(fileURLWithPath: "/Volumes/USB2/a.jpg"), among: volumes))
        XCTAssertNil(
            StorageVolume.root(
                of: URL(fileURLWithPath: "/Volumes/USB/Photos/a.jpg"), among: [URL(fileURLWithPath: "/")]))
        XCTAssertNil(StorageVolume.root(of: URL(fileURLWithPath: "/Users"), among: []))
    }

    func testUnstandardizedMountPointsCompareStandardizedDepth() {
        let volumes = [
            URL(fileURLWithPath: "/Volumes/USB/././", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/USB/Nested", isDirectory: true),
        ]
        let matched = StorageVolume.root(of: URL(fileURLWithPath: "/Volumes/USB/Nested/a.txt"), among: volumes)
        XCTAssertEqual(matched?.standardized.path, "/Volumes/USB/Nested")
    }

    func testNonStartupVolumesUseMountTableWithoutTouchingVolumeFiles() throws {
        var startupCalls = 0
        let startup = StorageVolume(
            name: "Macintosh HD", total: 1_000_000, available: 400_000, availableForImportantUsage: 500_000)
        let mounted = [
            StorageVolume.MountedVolume(
                root: URL(fileURLWithPath: "/"), totalBytes: 1_000_000, availableBytes: 400_000),
            StorageVolume.MountedVolume(
                root: URL(fileURLWithPath: "/Volumes/Camera Card"), totalBytes: 64_000_000_000,
                availableBytes: 12_000_000_000),
        ]
        let external = try FinderStorageBarModel.readVolumeSync(
            for: URL(fileURLWithPath: "/Volumes/Camera Card/DCIM/IMG_0001.JPG"),
            mounted: mounted,
            readStartup: {
                startupCalls += 1
                return startup
            })
        XCTAssertEqual(startupCalls, 0)
        XCTAssertFalse(external.startupDisk)
        XCTAssertEqual(external.volume.name, "Camera Card")
        XCTAssertEqual(external.volume.capacity, .init(total: 64_000_000_000, available: 12_000_000_000))

        let ejected = try FinderStorageBarModel.readVolumeSync(
            for: URL(fileURLWithPath: "/Volumes/Gone/Photos"),
            mounted: [mounted[0]],
            readStartup: {
                startupCalls += 1
                return startup
            })
        XCTAssertEqual(startupCalls, 1)
        XCTAssertTrue(ejected.startupDisk)
        XCTAssertEqual(ejected.volume, startup)
    }

    func testStartupDiskReadsItsNameAndCapacity() throws {
        let volumes = StorageVolume.mountedVolumes().map(\.root)
        let root = try XCTUnwrap(StorageVolume.root(of: URL(fileURLWithPath: NSHomeDirectory()), among: volumes))
        let volume = try StorageVolume.read(volume: root)
        XCTAssertFalse(volume.name.isEmpty)
        let capacity = try XCTUnwrap(volume.capacity)
        XCTAssertGreaterThan(capacity.total, 0)
        XCTAssertLessThanOrEqual(capacity.available, capacity.total)
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
        XCTAssertEqual(text.selection(1), "1 selected")
        XCTAssertEqual(text.selection(3), "3 selected")
        XCTAssertEqual(text.selection(120), "120 selected")
    }

    func testJapaneseMatchesFinderWording() throws {
        let text = try self.text("ja", locale: "ja_JP")
        XCTAssertEqual(text.name(volume, startupDisk: true), "Macintosh HD（起動ディスク）")
        XCTAssertEqual(text.capacity(volume), "994 GB中212 GB空き")
        let share = StorageVolume(name: "Share", total: nil, available: nil, availableForImportantUsage: nil)
        XCTAssertEqual(text.capacity(share), "容量を取得できません")
        XCTAssertEqual(text.selection(1), "1項目を選択")
        XCTAssertEqual(text.selection(3), "3項目を選択")
        XCTAssertEqual(text.selection(120), "120項目を選択")
    }

    func testVoiceOverReadsOneSentence() throws {
        let english = try text("en", locale: "en_US")
        XCTAssertEqual(
            english.accessibilityValue(volume, startupDisk: false, selectionCount: 3),
            "Macintosh HD, 212 GB available of 994 GB, 3 selected")
        XCTAssertEqual(
            english.accessibilityValue(volume, startupDisk: true, selectionCount: nil),
            "Macintosh HD (Startup Disk), 212 GB available of 994 GB")
        let japanese = try text("ja", locale: "ja_JP")
        XCTAssertEqual(
            japanese.accessibilityValue(volume, startupDisk: false, selectionCount: 2),
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
    func testUnknownFolderFallsBackToTheLabelledStartupDisk() async throws {
        let directory = try PreviewFixtures.directory(self)
        let model = FinderStorageBarModel()
        model.update(selectionCount: nil, folder: nil)
        try await waitUntil { model.volume != nil }
        XCTAssertTrue(model.showsStartupDisk)
        XCTAssertNil(model.selectionCount)

        model.update(selectionCount: 1, folder: directory)
        try await waitUntil { !model.showsStartupDisk && model.selectionCount == 1 }

        model.update(selectionCount: nil, folder: nil)
        XCTAssertNil(model.selectionCount)
        XCTAssertFalse(model.showsStartupDisk, "The last known folder keeps its volume")

        model.forgetLocation()
        model.update(selectionCount: nil, folder: nil)
        try await waitUntil { model.showsStartupDisk }
    }

    func testSlowVolumeReadFromPreviousWindowIsDropped() async throws {
        let folderA = URL(fileURLWithPath: "/Volumes/DriveA/Work")
        let folderB = URL(fileURLWithPath: "/Volumes/DriveB/Work")
        let volumeA = StorageVolume(name: "DriveA", total: 100, available: 50, availableForImportantUsage: nil)
        let volumeB = StorageVolume(name: "DriveB", total: 200, available: 150, availableForImportantUsage: nil)
        let gate = AsyncGate<FinderStorageBarModel.VolumeSnapshot>()
        let model = FinderStorageBarModel { target in
            if target == folderA {
                return try await gate.wait()
            }
            return .init(volume: volumeB, startupDisk: false, mountRoot: URL(fileURLWithPath: "/Volumes/DriveB"))
        }

        model.update(selectionCount: 1, folder: folderA)
        try await waitUntil { gate.isWaiting }

        model.forgetLocation()
        model.update(selectionCount: 2, folder: folderB)
        gate.resume(
            returning: .init(volume: volumeA, startupDisk: false, mountRoot: URL(fileURLWithPath: "/Volumes/DriveA")))

        try await waitUntil { model.volume == volumeB }
        XCTAssertEqual(model.volume, volumeB)
        XCTAssertFalse(model.showsStartupDisk)
        XCTAssertEqual(model.selectionCount, 2)
    }

    func testEjectedVolumeFallsBackToLabelledStartupDisk() async throws {
        let startup = StorageVolume(
            name: "Macintosh HD", total: 1_000, available: 500, availableForImportantUsage: 600)
        let usbMount = StorageVolume.MountedVolume(
            root: URL(fileURLWithPath: "/Volumes/USB"), totalBytes: 500, availableBytes: 250)
        let customMount = StorageVolume.MountedVolume(
            root: URL(fileURLWithPath: "/mnt/Scratch"), totalBytes: 400, availableBytes: 100)
        let rootMount = StorageVolume.MountedVolume(
            root: URL(fileURLWithPath: "/"), totalBytes: 1_000, availableBytes: 500)
        let mounted = OSAllocatedUnfairLock(initialState: [rootMount, usbMount, customMount])

        let model = FinderStorageBarModel { target in
            let current = mounted.withLock { $0 }
            return try FinderStorageBarModel.readVolumeSync(for: target, mounted: current) { startup }
        }

        model.update(selectionCount: 0, folder: URL(fileURLWithPath: "/Volumes/USB/Photos"))
        try await waitUntil { model.volume?.name == "USB" }
        XCTAssertFalse(model.showsStartupDisk)

        mounted.withLock { $0 = [rootMount, customMount] }
        model.refreshVolume()
        try await waitUntil { model.volume == startup && model.showsStartupDisk }

        model.update(selectionCount: 0, folder: URL(fileURLWithPath: "/mnt/Scratch/Sub"))
        try await waitUntil { model.volume?.name == "Scratch" && !model.showsStartupDisk }

        mounted.withLock { $0 = [rootMount] }
        model.refreshVolume()
        try await waitUntil { model.volume == startup && model.showsStartupDisk }
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
        bar.model.update(selectionCount: 0, folder: directory)
        bar.follow(window)
        try await waitUntil { bar.isVisible }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? FinderStorageBarPanel }.first { $0.isVisible })
        XCTAssertEqual(
            panel.frame,
            CGRect(
                x: 120, y: 140, width: 820 - FinderStorageBarGeometry.Calibration.iconSliderReserved,
                height: FinderStorageBarGeometry.Calibration.statusBarHeight))
        bar.setView(.list)
        XCTAssertEqual(
            panel.frame,
            CGRect(x: 120, y: 140, width: 820, height: FinderStorageBarGeometry.Calibration.statusBarHeight))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))

        bar.follow(nil)
        XCTAssertFalse(bar.isVisible)
        XCTAssertFalse(bar.wantsSelection)
        bar.follow(window)
        XCTAssertTrue(bar.isVisible)
        XCTAssertFalse(bar.model.showsStartupDisk)

        bar.follow(nil)
        bar.follow(.init(id: 7, frame: window.frame, preview: nil))
        bar.model.update(selectionCount: nil, folder: nil)
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
        bar.model.update(selectionCount: 0, folder: directory)
        try await waitUntil { bar.model.volume != nil }
        bar.follow(window)
        XCTAssertFalse(bar.isVisible)
        XCTAssertFalse(bar.wantsSelection)
    }

    func testHidingCancelsPendingVolumeWorkAndSkipsRefresh() async throws {
        let reads = AtomicCounter()
        let statusBarShown = OSAllocatedUnfairLock(initialState: true)
        let gate = AsyncGate<FinderStorageBarModel.VolumeSnapshot>()
        let sample = StorageVolume(name: "Disk", total: 100, available: 40, availableForImportantUsage: nil)
        let model = FinderStorageBarModel { _ in
            reads.increment()
            return try await gate.wait()
        }
        let bar = FinderStorageBar(model: model, readsStatusBar: { statusBarShown.withLock { $0 } })
        bar.start()
        addTeardownBlock { @MainActor in bar.stop() }

        bar.follow(window)
        bar.model.update(selectionCount: 0, folder: URL(fileURLWithPath: "/Users"))
        try await waitUntil { gate.isWaiting && reads.value == 1 }

        bar.follow(nil)
        gate.resume(returning: .init(volume: sample, startupDisk: false, mountRoot: URL(fileURLWithPath: "/")))
        bar.refresh()
        XCTAssertEqual(reads.value, 1)
        XCTAssertNil(bar.model.volume)

        statusBarShown.withLock { $0 = false }
        bar.follow(window)
        bar.refresh()
        XCTAssertEqual(reads.value, 1)

        statusBarShown.withLock { $0 = true }
        bar.follow(.init(id: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 400), preview: nil))
        bar.refresh()
        XCTAssertEqual(reads.value, 1)
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
        try await waitUntil { model.selectionCount == 1 && model.volume != nil }
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

        coordinator.applySelectionResult(.failure(.automationDenied), trackedWindowID: 42, forPreview: false)
        try await waitUntil { model.volume != nil }
        XCTAssertTrue(model.showsStartupDisk)
        XCTAssertNil(model.selectionCount)
        XCTAssertNil(coordinator.state.notice)

        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [note], folder: directory, view: .list)),
            trackedWindowID: 42, forPreview: false)
        try await waitUntil { model.selectionCount == 1 && !model.showsStartupDisk }
        coordinator.applySelectionResult(.failure(.automationDenied), trackedWindowID: 42, forPreview: false)
        XCTAssertNil(model.selectionCount)
        XCTAssertNotNil(model.volume)
        XCTAssertNil(coordinator.state.notice)
        XCTAssertEqual(coordinator.storageBar.windowView, .unknown)
    }

    func testTransientFailuresKeepTheStorageSelection() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let coordinator = makeCoordinator(store, directory)
        let model = coordinator.storageBar.model
        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [note], folder: directory, view: .list)),
            trackedWindowID: 42, forPreview: false)
        try await waitUntil { model.selectionCount == 1 }
        for _ in 1..<FinderPreviewCoordinator.transientFailureThreshold {
            coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42, forPreview: false)
        }
        XCTAssertEqual(model.selectionCount, 1)
        coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42, forPreview: false)
        XCTAssertNil(model.selectionCount)
        XCTAssertNil(coordinator.state.notice)
    }

    func testMissingAccessibilityShowsNothing() throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let coordinator = makeCoordinator(store, directory)
        coordinator.start()
        addTeardownBlock { @MainActor in coordinator.stop() }
        XCTAssertFalse(coordinator.storageBar.isVisible)
        XCTAssertFalse(coordinator.storageBar.wantsSelection)
        XCTAssertFalse(NSApp.windows.contains { $0 is FinderPreviewPanel && $0.isVisible })
    }

    func testTurningTheSettingOffRemovesTheStrip() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let coordinator = makeCoordinator(store, directory)
        coordinator.start()
        addTeardownBlock { @MainActor in coordinator.stop() }
        let bar = coordinator.storageBar
        bar.start()
        bar.model.update(selectionCount: 0, folder: directory)
        bar.follow(.init(id: 0, frame: CGRect(x: 100, y: 100, width: 800, height: 500), preview: nil))
        try await waitUntil { bar.isVisible }

        store.finderStorageBarEnabled = false
        try await waitUntil { !bar.isVisible && bar.model.volume == nil }
        coordinator.applySelectionResult(
            .success(.init(windowID: 42, urls: [directory], folder: directory)),
            trackedWindowID: 42, forPreview: false)
        XCTAssertNil(bar.model.volume)
        XCTAssertNil(bar.model.selectionCount)
    }

    func testPreviewOffNeverInspectsSelectedFilesOrKeepsPreviewState() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let locked = directory.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }

        let reader = FinderSelectionReader(
            requestConsent: { _ in nil },
            readSelection: { .success(.init(windowID: 42, urls: [locked], folder: directory, view: .list)) })
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }),
            reader: reader, isTrusted: { true }, finderIsFrontmost: { true }, frontWindowMatches: { true })
        addTeardownBlock { @MainActor in coordinator.stop() }
        coordinator.storageBar.start()
        coordinator.followTrackedWindow(
            .init(
                id: 42, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: true))
        let generationAfterTrack = coordinator.state.generation
        try await waitUntil { coordinator.storageBar.model.selectionCount == 1 && coordinator.storageBar.isVisible }

        XCTAssertTrue(coordinator.state.urls.isEmpty)
        XCTAssertNil(coordinator.state.kind)
        XCTAssertNil(coordinator.state.trust)
        XCTAssertNil(coordinator.state.detected)
        XCTAssertNil(coordinator.state.fileFailure)
        XCTAssertNil(coordinator.state.notice)
        XCTAssertEqual(coordinator.state.generation, generationAfterTrack)

        store.finderPreview.disabledKinds.insert(.text)
        store.finderPreview.addTrustedFolder(directory)
        XCTAssertEqual(coordinator.state.generation, generationAfterTrack)
        XCTAssertTrue(coordinator.state.urls.isEmpty)
        XCTAssertNil(coordinator.state.kind)
    }

    func testTurningPreviewOffWithStripOnClearsPreviewState() async throws {
        let (store, _) = try makeStore()
        store.finderPreviewEnabled = true
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let reader = FinderSelectionReader(
            requestConsent: { _ in nil },
            readSelection: { .success(.init(windowID: 42, urls: [note], folder: directory, view: .list)) })
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }),
            reader: reader, isTrusted: { true }, finderIsFrontmost: { true }, frontWindowMatches: { true })
        addTeardownBlock { @MainActor in coordinator.stop() }
        coordinator.storageBar.start()
        coordinator.followTrackedWindow(
            .init(
                id: 42, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: true))
        coordinator.start()
        try await waitUntil { coordinator.state.kind == .text && coordinator.storageBar.isVisible }

        store.finderPreviewEnabled = false
        try await waitUntil { coordinator.state.urls.isEmpty && coordinator.state.kind == nil }
        XCTAssertNil(coordinator.state.trust)
        XCTAssertNil(coordinator.state.detected)
        XCTAssertNil(coordinator.state.fileFailure)
        XCTAssertNil(coordinator.state.notice)
        XCTAssertTrue(coordinator.storageBar.isVisible)
    }

    func testEnablingStorageBarWhilePreviewIsOnShowsStripImmediately() async throws {
        let (store, _) = try makeStore()
        store.finderPreviewEnabled = true
        store.finderStorageBarEnabled = false
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let counter = AtomicCounter()
        let reader = FinderSelectionReader(
            requestConsent: { _ in nil },
            readSelection: {
                counter.increment()
                return .success(.init(windowID: 42, urls: [note], folder: directory, view: .list))
            })
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }),
            reader: reader, isTrusted: { true }, finderIsFrontmost: { false }, frontWindowMatches: { true })
        addTeardownBlock { @MainActor in coordinator.stop() }

        coordinator.followTrackedWindow(
            .init(
                id: 42, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: true))
        coordinator.start()
        try await waitUntil { coordinator.state.kind == .text && counter.value == 1 }
        XCTAssertFalse(coordinator.storageBar.isVisible)

        store.finderStorageBarEnabled = true
        try await waitUntil {
            counter.value >= 2 && coordinator.storageBar.isVisible
                && coordinator.storageBar.model.selectionCount == 1
        }
        XCTAssertFalse(coordinator.storageBar.model.showsStartupDisk)
    }

    func testStripSilentDenialStopsRetryingAndDoesNotSwallowPreviewConsent() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let releaseSilent = DispatchSemaphore(value: 0)
        let silentCalls = AtomicCounter()
        let askingCalls = AtomicCounter()
        let reader = FinderSelectionReader(
            requestConsent: { asking in
                if asking {
                    askingCalls.increment()
                    return nil
                }
                silentCalls.increment()
                releaseSilent.wait()
                return .automationDenied
            },
            readSelection: {
                .success(.init(windowID: 42, urls: [note], folder: directory, view: .list))
            })
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }),
            reader: reader, isTrusted: { true }, finderIsFrontmost: { true }, frontWindowMatches: { true })
        addTeardownBlock { @MainActor in coordinator.stop() }
        coordinator.storageBar.start()

        coordinator.followTrackedWindow(
            .init(
                id: 42, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: true))
        coordinator.start()
        try await waitUntil { silentCalls.value == 1 }

        store.finderPreviewEnabled = true
        try await waitUntil { coordinator.state.docked }
        releaseSilent.signal()

        try await waitUntil { askingCalls.value == 1 && coordinator.state.kind == .text }
        XCTAssertNil(coordinator.state.notice)
        XCTAssertEqual(coordinator.storageBar.model.selectionCount, 1)
    }

    func testStripOnlyTransientFailuresDoNotFlashNoticeWhenPreviewTurnsOn() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let note = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let reader = FinderSelectionReader(
            requestConsent: { _ in nil },
            readSelection: { .success(.init(windowID: 42, urls: [note], folder: directory, view: .list)) })
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }),
            reader: reader, isTrusted: { true }, finderIsFrontmost: { true }, frontWindowMatches: { true })
        addTeardownBlock { @MainActor in coordinator.stop() }
        coordinator.storageBar.start()
        coordinator.followTrackedWindow(
            .init(
                id: 42, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: true))
        coordinator.start()
        try await waitUntil { coordinator.storageBar.model.selectionCount == 1 }

        for _ in 0..<FinderPreviewCoordinator.transientFailureThreshold {
            coordinator.applySelectionResult(.failure(.timedOut), trackedWindowID: 42, forPreview: false)
        }
        XCTAssertNil(coordinator.state.notice)

        store.finderPreviewEnabled = true
        try await waitUntil { coordinator.state.docked && coordinator.state.kind == .text }
        XCTAssertNil(coordinator.state.notice)
    }

    func testStripOnlyAutomationDenialStopsPollingAndKeepsCapacity() async throws {
        let (store, _) = try makeStore()
        let directory = try PreviewFixtures.directory(self)
        let silentCalls = AtomicCounter()
        let reader = FinderSelectionReader(
            requestConsent: { _ in
                silentCalls.increment()
                return .automationDenied
            },
            readSelection: { .failure(.automationDenied) })
        let coordinator = FinderPreviewCoordinator(
            settings: store, staging: StagingArea(supportDirectory: directory),
            storageBar: FinderStorageBar(readsStatusBar: { true }),
            reader: reader, isTrusted: { true }, finderIsFrontmost: { true }, frontWindowMatches: { true })
        addTeardownBlock { @MainActor in coordinator.stop() }
        coordinator.storageBar.start()

        coordinator.followTrackedWindow(
            .init(
                id: 42, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: true))
        try await waitUntil {
            silentCalls.value == 1 && coordinator.storageBar.model.volume != nil
                && coordinator.storageBar.model.showsStartupDisk
        }
        XCTAssertNil(coordinator.state.notice)
        XCTAssertNil(coordinator.storageBar.model.selectionCount)

        coordinator.pollSelectionForTesting(immediate: true)
        coordinator.pollSelectionForTesting(immediate: false)
        XCTAssertEqual(silentCalls.value, 1)
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

private final class AtomicCounter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { storage.withLock { $0 } }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

@MainActor
private final class AsyncGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pending: Result<Value, any Error>?

    var isWaiting: Bool { continuation != nil }

    func wait() async throws -> Value {
        if let pending {
            self.pending = nil
            return try pending.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
        }
    }

    func resume(returning value: Value) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else {
            pending = .success(value)
        }
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
