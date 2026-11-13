import Foundation
import Testing

@testable import MenuCatalog

@Suite struct ToolkitMenuTests {
    @Test func relatedAndProtectionRequireOneFile() {
        let source = URL(filePath: "/selection/photo.png")
        let other = URL(filePath: "/selection/song.wav")
        for operation in [OperationID.anyFindRelated, .anyProtect, .anySourceInfo] {
            let entry = MenuEntry(op: operation, preset: nil, path: [operation.rawValue])
            #expect(MenuLayout.isApplicable(entry, selection: [source]))
            #expect(!MenuLayout.isApplicable(entry, selection: [source, other]))
            #expect(!MenuLayout.isApplicable(entry, selection: []))
        }
        let share = MenuEntry(op: .anyShare, preset: nil, path: ["Share"])
        #expect(MenuLayout.isApplicable(share, selection: [source, other]))
        #expect(MenuLayout.isApplicable(share, selection: Array(repeating: source, count: 20)))
        #expect(!MenuLayout.isApplicable(share, selection: Array(repeating: source, count: 21)))
    }

    @Test func enhancementFollowsTheSelectedMediaKind() {
        let photo = MenuEntry(op: .imageEnhance, preset: nil, path: ["Upscale"])
        let audio = MenuEntry(op: .audioEnhance, preset: nil, path: ["Enhance"])
        let imageURL = URL(filePath: "/selection/photo.png")
        let audioURL = URL(filePath: "/selection/song.wav")
        #expect(MenuLayout.isApplicable(photo, selection: [imageURL]))
        #expect(!MenuLayout.isApplicable(photo, selection: [audioURL]))
        #expect(!MenuLayout.isApplicable(photo, selection: [imageURL, imageURL]))
        #expect(MenuLayout.isApplicable(audio, selection: [audioURL]))
        #expect(!MenuLayout.isApplicable(audio, selection: [imageURL]))
    }
}
