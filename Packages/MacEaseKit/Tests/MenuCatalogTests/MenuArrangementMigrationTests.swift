import Testing

@testable import MenuCatalog

@Suite struct MenuArrangementMigrationTests {
    private let newInstallHidden: Set<String> = ["image.resize/long-3840", "image.resize/long-2560"]

    private func ids(_ names: String...) -> [MenuGroupID] {
        names.map(MenuGroupID.init(rawValue:))
    }

    private func migrate(
        placements: [String: MenuPlacement] = [:], hidden: Set<String> = [], extraAngle: Bool = false
    ) -> (arrangement: MenuArrangement, hiddenEntries: Set<String>) {
        MenuArrangement.migrating(
            placements: placements, hiddenEntries: hidden, newInstallHidden: newInstallHidden,
            extraAngleEnabled: extraAngle)
    }

    @Test func untouchedSettingsStayUncustomized() {
        let result = migrate(hidden: newInstallHidden.union(["image.ocr/copy", "video.edit/x"]))
        #expect(result.arrangement == MenuArrangement())
        #expect(result.hiddenEntries == newInstallHidden.union(["image.ocr/copy", "video.edit/x"]))
    }

    @Test func placementsRebuildTodaysPrimaryOrder() {
        let result = migrate(placements: [
            "video.convert": .more, "video.rotate": .primary, "video.edit": .primary, "video.fps": .primary,
            "any.checksum": .primary, "folder.downloadMedia": .primary, "image.gone": .primary,
            "text.json/minify": .more,
        ])
        let video = result.arrangement.resolved(.video)
        #expect(
            video[.menu]
                == ids(
                    "video.edit", "video.compress", "video.resize", "video.extractAudio", "video.thumbnail",
                    "video.subtitles", "video.rotate", "video.fps"))
        #expect(video[.more] == ids("video.convert", "video.speed", "video.removeAudio", "video.background"))
        let text = result.arrangement.resolved(.text)
        #expect(text[.menu] == ids("text.convert", "text.json/pretty", "text.json/sort"))
        #expect(text[.more] == ids("text.encoding", "text.lineEndings", "text.json/minify"))
        for scope in [MenuScope.any, .commands, .image, .folder] {
            #expect(!result.arrangement.isCustomized(scope))
        }
        let catalog = MenuGroupCatalog.current
        #expect(catalog.isCanonical(video[.menu], in: .menu, of: .video))
        #expect(catalog.isCanonical(video[.more], in: .more, of: .video))
    }

    @Test func renamedPlacementKeysStayIgnoredAsBefore() {
        let result = migrate(placements: ["video.trim": .more])
        #expect(!result.arrangement.isCustomized(.video))
        #expect(result.arrangement.resolved(.video)[.menu].first == MenuGroupID(rawValue: "video.edit"))
    }

    @Test func fullyHiddenGroupsFoldIntoHiddenAndKeepNewInstallLeafDefaults() {
        let ocr = OperationID.imageOCR.menuEntryKeys
        let resize = OperationID.imageResize.menuEntryKeys
        let partial = ["image.compress/x", "image.compress/web"]
        let result = migrate(hidden: Set(ocr + resize + partial + ["image.gone/"]))
        let image = result.arrangement.resolved(.image)
        #expect(image[.hidden] == ids("image.resize", "image.ocr"))
        #expect(!image[.menu].contains(MenuGroupID(rawValue: "image.ocr")))
        #expect(result.hiddenEntries == newInstallHidden.union(partial + ["image.gone/"]))
    }

    @Test func extraAngleCountsOnlyWhileEnabled() {
        let leaves = OperationID.imageRotate.menuEntryKeys.filter { !$0.hasSuffix("extra-angle") }
        let hidden = Set(leaves + OperationID.imageFlip.menuEntryKeys)
        let disabled = migrate(hidden: hidden)
        #expect(disabled.arrangement.resolved(.image)[.hidden] == ids("image.rotate"))
        #expect(disabled.hiddenEntries.isEmpty)
        let enabled = migrate(hidden: hidden, extraAngle: true)
        #expect(!enabled.arrangement.isCustomized(.image))
        #expect(enabled.hiddenEntries == hidden)
        let all = migrate(hidden: hidden.union(["image.rotate/extra-angle"]), extraAngle: true)
        #expect(all.arrangement.resolved(.image)[.hidden] == ids("image.rotate"))
    }

    @Test func visibleTGAKeepsConvertShown() {
        let convert = Set(OperationID.imageConvert.menuEntryKeys + OperationID.imageHDRToSDR.menuEntryKeys)
        let tgaShown = migrate(hidden: convert.subtracting(["image.convert/tga"]))
        #expect(!tgaShown.arrangement.isCustomized(.image))
        let allHidden = migrate(hidden: convert)
        #expect(allHidden.arrangement.resolved(.image)[.hidden] == ids("image.convert"))
    }

    @Test func gatedAndCommandGroupsFoldOnlyThroughTheirOwnKeys() {
        let hidden = Set(
            OperationID.imageAIRename.menuEntryKeys + OperationID.audioSubtitles.menuEntryKeys
                + OperationID.jarDecompile.menuEntryKeys + ["folder.downloadMedia/"])
        let result = migrate(hidden: hidden)
        #expect(result.arrangement.resolved(.image)[.hidden] == ids("image.aiRename"))
        #expect(result.arrangement.resolved(.audio)[.hidden] == ids("audio.subtitles"))
        #expect(result.arrangement.resolved(.jar)[.hidden] == ids("jar.decompile"))
        let commands = result.arrangement.resolved(.commands)
        #expect(commands[.hidden] == ids("folder.downloadMedia"))
        #expect(commands[.menu] == ids("command.update", "command.preview"))
        #expect(result.hiddenEntries.isEmpty)
    }

    @Test func hideAllFoldsEveryOperationGroup() {
        let result = migrate(
            placements: ["image.traceSVG": .primary], hidden: Set(OperationID.allCases.flatMap(\.menuEntryKeys)),
            extraAngle: true)
        for scope in MenuScope.allCases {
            let resolved = result.arrangement.resolved(scope)
            #expect(resolved[.menu] == (scope == .commands ? ids("command.update", "command.preview") : []))
            #expect(resolved[.more].isEmpty)
        }
        #expect(result.hiddenEntries == newInstallHidden)
    }
}
