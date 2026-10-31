import Foundation
import Testing

@testable import MenuCatalog

@Suite struct RecipeMenuTests {
    private func selection(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/missing/\($0)", isDirectory: false) }
    }

    @Test func recipesRequireEverySelectedKind() {
        let entry = MenuEntry(
            op: .filesFinish, preset: nil, path: ["Finish", "Images"],
            recipeID: UUID(), recipeRevision: "1", acceptedKinds: [.image])
        #expect(MenuLayout.isApplicable(entry, selection: selection(["one.jpg", "two.png"])))
        #expect(!MenuLayout.isApplicable(entry, selection: selection(["one.jpg", "two.pdf"])))
        #expect(!MenuLayout.isApplicable(entry, selection: selection(["one.jpg", "unknown.bin"])))
        let folder = URL(fileURLWithPath: "/missing/folder", isDirectory: true)
        #expect(!MenuLayout.isApplicable(entry, selection: selection(["one.jpg"]) + [folder]))
        #expect(!MenuLayout.isApplicable(entry, selection: []))
    }

    @Test func chooserAcceptsMixedMediaWithoutDroppingFiles() {
        let chooser = MenuEntry(op: .filesFinish, preset: nil, path: ["Finish"])
        #expect(MenuLayout.isApplicable(chooser, selection: selection(["one.jpg", "two.mov", "three.pdf"])))
        #expect(!MenuLayout.isApplicable(chooser, selection: selection(["one.jpg", "two.txt"])))
    }

    @Test func recipeIdentityRevisionAndKindsInvalidateRequests() throws {
        let id = UUID()
        func entry(_ recipeID: UUID, revision: String, kinds: Set<FileKind>) -> MenuEntry {
            MenuEntry(
                op: .filesFinish, preset: nil, path: ["Finish", "Publish"],
                recipeID: recipeID, recipeRevision: revision, acceptedKinds: kinds)
        }
        let original = entry(id, revision: "1", kinds: [.image, .video])
        let catalog = MenuFile(token: "token", hostAvailable: true, entries: [original], kinds: [.any: "Files"])
        for changed in [
            entry(id, revision: "2", kinds: [.image, .video]),
            entry(UUID(), revision: "1", kinds: [.image, .video]),
            entry(id, revision: "1", kinds: [.image]),
        ] {
            #expect(MenuFile.version(of: [changed]) != catalog.catalogVersion)
        }
        let decoded = try MenuFile(json: catalog.encoded())
        #expect(decoded.entries == [original])
    }

    @Test func photoEditingAcceptsBatchesWhilePageEditingRemainsSingleDocument() {
        let photos = MenuEntry(op: .imageEdit, preset: nil, path: ["Edit"])
        let pages = MenuEntry(op: .pdfEditPages, preset: nil, path: ["Pages"])
        #expect(MenuLayout.isApplicable(photos, selection: selection(["one.jpg", "two.png"])))
        #expect(MenuLayout.isApplicable(pages, selection: selection(["one.pdf"])))
        #expect(!MenuLayout.isApplicable(pages, selection: selection(["one.pdf", "two.pdf"])))
    }
}
