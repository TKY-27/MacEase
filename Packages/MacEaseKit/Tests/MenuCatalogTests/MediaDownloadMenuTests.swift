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
        let file = MenuFile(token: "token", hostAvailable: true, entries: [entry], kinds: [.folder: "Folder"])
        #expect(MenuLayout.nodes(for: file, selection: [folder]).isEmpty)
    }
}
