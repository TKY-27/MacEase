import Foundation
import Testing

@testable import MenuCatalog

@Suite struct FolderAndVideoMenuTests {
    @Test func explicitLocationsIncludeStandardCloudAndAdditionalFolders() {
        let locations = FinderLocations.directories(
            home: URL(filePath: "/Users/test", directoryHint: .isDirectory),
            volumes: [URL(filePath: "/Volumes/External", directoryHint: .isDirectory)],
            additionalPaths: ["/Volumes/External/Projects", "/Users/test/Desktop", "relative", "/bad\0path"])
        let paths = Set(locations.map(\.path))
        #expect(
            paths.isSuperset(of: [
                "/", "/Users/test", "/Users/test/Desktop", "/Users/test/Documents", "/Users/test/Downloads",
                "/Volumes/External", "/Volumes/External/Projects",
                "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Desktop",
            ]))
        #expect(!paths.contains { $0.contains("relative") || $0.contains("bad") })
        #expect(
            FinderLocations.notificationName(supportFolder: "MacEase")
                != FinderLocations.notificationName(supportFolder: "MacEaseDev"))
    }

    @Test func folderPathsAreOptionalAndDoNotInvalidateOperationRequests() throws {
        let original = MenuFile(token: "test", hostAvailable: true, entries: [], kinds: [:])
        let legacy = try MenuFile(json: original.encoded())
        #expect(legacy.monitoredDirectoryPaths == nil)
        var updated = original
        updated.monitoredDirectoryPaths = ["/Volumes/External"]
        let decoded = try MenuFile(json: updated.encoded())
        #expect(decoded.monitoredDirectoryPaths == updated.monitoredDirectoryPaths)
        #expect(updated.catalogVersion == original.catalogVersion)
    }

    @Test func editIsSingleSelectionAndSpeedSupportsBatchesAndCustomInput() {
        let one = [URL(filePath: "/clip.mov")]
        let several = one + [URL(filePath: "/second.mp4")]
        let edit = MenuEntry(op: .videoEdit, preset: nil, path: ["Edit Video"])
        let speed = MenuEntry(op: .videoSpeed, preset: MenuEntry.customPreset, path: ["Playback Speed", "Custom"])
        #expect(MenuLayout.isApplicable(edit, selection: one))
        #expect(!MenuLayout.isApplicable(edit, selection: several))
        #expect(MenuLayout.isApplicable(speed, selection: several))
        #expect(OperationID.videoSpeed.presets == ["0.5", "0.75", "1.25", "1.5", "2", "4"])
        #expect(OperationID(rawValue: "video.trim") == .videoTrim)
        #expect(OperationID.menuOrder.contains(.videoEdit))
        #expect(!OperationID.menuOrder.contains(.videoTrim))
    }
}
