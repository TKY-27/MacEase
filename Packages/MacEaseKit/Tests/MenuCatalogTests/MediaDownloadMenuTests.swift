import Foundation
import Testing

@testable import MenuCatalog

struct MediaDownloadMenuTests {
    @Test func onlyOneCompleteFolderSelectionOffersDownload() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "MacEaseMenu-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let entry = MenuEntry(op: .folderDownloadMedia, preset: nil, path: ["yt-dlp…"])
        #expect(entry.maximumSelection == 1)
        #expect(MenuLayout.isApplicable(entry, selection: [folder]))
        #expect(!MenuLayout.isApplicable(entry, selection: []))
        #expect(!MenuLayout.isApplicable(entry, selection: [folder, folder]))
        #expect(!MenuLayout.isApplicable(entry, selection: [folder, URL(filePath: "/file.txt")]))
        let download = MenuCommandItem(
            group: MenuGroupID(rawValue: entry.resolvedGroupID), title: "yt-dlp…", placement: .finder)
        let file = MenuFile(
            token: "token", hostAvailable: true, entries: [entry], kinds: [.folder: "Folder"], commands: [download])
        let tree = MenuLayout.tree(for: file, selection: [folder])
        #expect(tree.macEase.isEmpty)
        #expect(tree.finder == [.action(title: "yt-dlp…", entryIndex: 0)])
        #expect(MenuLayout.tree(for: file, selection: [folder, folder]) == MenuTree(finder: [], macEase: []))
    }
}
