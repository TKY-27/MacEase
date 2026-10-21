import Foundation
import Testing

@testable import MenuCatalog

struct MediaConversionMenuTests {
    @Test func conversionsAreReachableFromClassifiedSelections() throws {
        let file = catalog(tgaAvailable: true)
        for (operation, preset, name) in [
            (OperationID.videoExtractAudio, "m4a-alac", "clip.mov"),
            (.audioConvert, "caf-pcm", "tone.aifc"),
            (.audioConvert, "caf-alac", "tone.wav"),
            (.pdfToImages, "tiff", "pages.pdf"),
            (.imageConvert, "tga", "photo.png"),
            (.imageConvert, "png", "photo.tga"),
            (.imageConvert, "png", "layers.psd"),
            (.imageConvert, "jpeg", "layers.psd"),
            (.imageConvert, "tiff", "layers.psd"),
        ] {
            let entry = try #require(file.entries.first { $0.op == operation && $0.preset == preset })
            #expect(MenuLayout.isApplicable(entry, selection: [URL(fileURLWithPath: "/selection/" + name)]))
        }
    }

    @Test func photoshopOffersOnlyCompositeRasterTargets() {
        let file = catalog(tgaAvailable: true)
        let selection = [URL(fileURLWithPath: "/selection/layers.psd")]
        let targets = file.entries.filter {
            $0.op == .imageConvert && MenuLayout.isApplicable($0, selection: selection)
        }
        #expect(targets.compactMap(\.preset) == ["png", "jpeg", "tiff"])
    }

    @Test func cafCodecChoicesRemainVisibleForCAFInputs() {
        let file = catalog(tgaAvailable: true)
        let selection = [URL(fileURLWithPath: "/selection/tone.caf")]
        let targets = file.entries.filter {
            $0.op == .audioConvert && MenuLayout.isApplicable($0, selection: selection)
        }
        #expect(targets.contains { $0.preset == "caf-pcm" })
        #expect(targets.contains { $0.preset == "caf-alac" })
    }

    @Test func unavailableTGADestinationIsHidden() {
        #expect(!catalog(tgaAvailable: false).entries.contains { $0.op == .imageConvert && $0.preset == "tga" })
        #expect(catalog(tgaAvailable: true).entries.contains { $0.op == .imageConvert && $0.preset == "tga" })
    }

    private func catalog(tgaAvailable: Bool) -> MenuFile {
        MenuFile(
            token: "test-token", hostAvailable: true,
            visibleOperations: [.imageConvert, .videoExtractAudio, .audioConvert, .pdfToImages],
            titles: MenuTitles(
                operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue },
                tgaAvailable: tgaAvailable))
    }
}
