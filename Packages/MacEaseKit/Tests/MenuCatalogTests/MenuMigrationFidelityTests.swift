import Foundation
import Testing

@testable import MenuCatalog

/// Legacy menus must survive migration exactly.
@Suite struct MenuMigrationFidelityTests {
    private static let newInstallHidden: Set<String> = [
        "image.resize/long-3840", "image.resize/long-2560", "image.convert/bmp", "image.convert/ico",
        "image.convert/icns", "video.resize/2160p", "video.compress/mb-100", "video.convert/m4v", "video.convert/avi",
        "video.convert/flv", "video.toAPNG/settings", "video.extractAudio/aiff", "video.extractAudio/ogg",
        "video.extractAudio/opus", "any.checksum/sha1", "any.checksum/sha512",
    ]

    private static let selections: [[URL]] = [
        ["a.png"], ["a.png", "b.jpg"], ["a.tga"], ["a.heic"], ["a.mov"], ["a.mov", "b.mp4"], ["a.wav"],
        ["a.mp3", "b.wav"], ["a.pdf"], ["a.pdf", "b.pdf"], ["a.json"], ["a.txt"], ["a.csv"], ["a.docx"],
        ["a.plist"], ["a.zip"], ["a.rar"], ["a.7z"], ["a.jar"], ["folder/"], ["folder/", "other/"],
        ["a.png", "b.mov", "c.json"], ["a.png", "folder/"], ["a.png", "unknown.bin"], ["unknown.bin"],
        ["a.pdf", "b.docx", "c.wav", "d.zip"],
    ].map { names in names.map { URL(fileURLWithPath: "/missing/\($0)", isDirectory: $0.hasSuffix("/")) } }

    private static let placementSets: [[String: MenuPlacement]] = [
        [:],
        ["video.convert": .more, "video.rotate": .primary, "any.checksum": .primary],
        ["image.enhance": .primary, "image.traceSVG": .primary, "image.edit": .more, "image.convert": .primary],
        ["image.toPDF": .primary, "image.aiRename": .primary, "image.ocr": .more],
        ["text.json/minify": .more, "text.encoding": .primary, "text.json/sort": .more],
        [
            "folder.removeDuplicates": .more, "folder.tree": .primary, "folder.downloadMedia": .primary,
            "folder.aiRename": .primary,
        ],
        ["pdf.aiRename": .primary, "pdf.merge": .more, "audio.subtitles": .more, "jar.decompile": .primary],
        ["video.trim": .more, "image.gone": .primary, "archive.browse": .more, "document.convert": .more],
    ]

    private static func keys(_ ops: OperationID...) -> Set<String> {
        Set(ops.flatMap(\.menuEntryKeys))
    }

    private static let hiddenSets: [Set<String>] = [
        [], newInstallHidden,
        newInstallHidden.union(keys(.imageOCR, .videoEdit)),
        keys(.imageRotate, .imageFlip).subtracting(["image.rotate/extra-angle"]),
        keys(.imageRotate, .imageFlip, .videoRotate, .videoFlip),
        keys(.imageConvert, .imageHDRToSDR).subtracting(["image.convert/tga"]),
        keys(.imageConvert, .imageHDRToSDR, .imageResize),
        keys(.imageAIRename, .pdfAIRename, .folderAIRename, .jarDecompile),
        keys(.audioSubtitles, .videoSubtitles, .folderDownloadMedia),
        ["text.json/pretty", "text.convert/csv-json", "folder.removeDuplicates/", "image.toPDF/"],
        keys(.textJSON, .imageToPDF, .imageIconSet, .folderRemoveDuplicates, .folderRemoveEmpty),
        keys(.videoConvert, .videoToGIF, .videoToAnimatedWebP, .videoToAPNG).subtracting(["video.toGIF/x"]),
        ["any.checksum/sha256", "files.finish/", "any.share/", "image.rotate/extra-angle", "audio.compress/custom"],
        Set(OperationID.allCases.flatMap(\.menuEntryKeys)),
    ]

    private struct Conditions {
        var extraAngle = false
        var speech = true
        var tga = true
        var intelligence = true
        var java = true
        var update = false
        var preview = true
    }

    private static let conditionSets: [Conditions] = [
        Conditions(),
        Conditions(extraAngle: true, update: true),
        Conditions(speech: false, tga: false, intelligence: false, java: false, preview: false),
        Conditions(extraAngle: true, speech: false, tga: false, update: true),
        Conditions(intelligence: false, update: true, preview: false),
    ]

    @Test func everyLegacySettingsMatrixMenuSurvivesMigration() {
        var compared = 0
        for placements in Self.placementSets {
            for hidden in Self.hiddenSets {
                for conditions in Self.conditionSets {
                    compared += compare(placements: placements, hidden: hidden, conditions: conditions)
                }
            }
        }
        #expect(compared == 8 * 14 * 5 * 26 * 2)
    }

    @Test func randomLegacySettingsSurviveMigration() {
        var random = SeededRandom(seed: 0xF1DE_1171)
        let groups =
            MenuScope.allCases.flatMap(MenuGroupCatalog.current.groups(in:)).map(\.rawValue)
            + ["video.trim", "image.gone", "command.update"]
        let keys = OperationID.allCases.flatMap(\.menuEntryKeys)
        var compared = 0
        for _ in 0..<300 {
            var placements: [String: MenuPlacement] = [:]
            for group in groups where random.next() % 4 == 0 {
                placements[group] = random.next() % 2 == 0 ? .primary : .more
            }
            var hidden = Set(keys.filter { _ in random.next() % 7 == 0 })
            for group in groups where random.next() % 9 == 0 {
                hidden.formUnion(MenuGroupID(rawValue: group).entryKeys)
            }
            let bits = random.next()
            let conditions = Conditions(
                extraAngle: bits & 1 != 0, speech: bits & 2 != 0, tga: bits & 4 != 0, intelligence: bits & 8 != 0,
                java: bits & 16 != 0, update: bits & 32 != 0, preview: bits & 64 != 0)
            compared += compare(placements: placements, hidden: hidden, conditions: conditions)
        }
        #expect(compared == 300 * 26 * 2)
    }

    /// Compares every selection with both hidden sets.
    private func compare(placements: [String: MenuPlacement], hidden: Set<String>, conditions: Conditions) -> Int {
        let visible = OperationID.menuOrder.filter { op in
            switch op.requirement {
            case .appleIntelligence: conditions.intelligence
            case .java: conditions.java
            case nil: true
            }
        }
        let degrees: Double? = conditions.extraAngle ? 45 : nil
        let legacy = LegacyMenuOracle.menus(
            LegacyMenuOracle.Settings(
                visibleOperations: visible, hiddenEntries: hidden, placements: placements,
                extraRotationDegrees: degrees, speechAvailable: conditions.speech, tgaAvailable: conditions.tga,
                updateTitle: conditions.update ? "Update" : nil, previewTitle: conditions.preview ? "Preview" : nil),
            selections: Self.selections)
        let migrated = MenuArrangement.migrating(
            placements: placements, hiddenEntries: hidden, newInstallHidden: Self.newInstallHidden,
            extraAngleEnabled: conditions.extraAngle)
        let oracle = LegacyMenuOracle.titles
        let titles = MenuTitles(
            operation: oracle.operation, preset: oracle.preset, kind: oracle.kind,
            speechAvailable: conditions.speech, tgaAvailable: conditions.tga)
        var commandTitles: [HostCommand: String] = [:]
        if conditions.update { commandTitles[.update] = "Update" }
        if conditions.preview { commandTitles[.preview] = "Preview" }
        var compared = 0
        for hiddenEntries in [migrated.hiddenEntries, hidden] {
            let file = MenuFile(
                token: "token", hostAvailable: true, visibleOperations: visible, titles: titles,
                hiddenEntries: hiddenEntries, extraRotationDegrees: degrees, arrangement: migrated.arrangement,
                moreTitle: "More", commandTitles: commandTitles)
            for (selection, expected) in zip(Self.selections, legacy) {
                let tree = MenuLayout.tree(for: file, selection: selection)
                let actual =
                    Self.flatten(tree.finder, file: file, prefix: "F ")
                    + Self.flatten(tree.macEase, file: file, prefix: "M ")
                if actual != expected {
                    Issue.record(
                        "\(placements) \(hidden.sorted()) \(conditions) \(selection.map(\.lastPathComponent))")
                }
                compared += 1
            }
        }
        return compared
    }

    private static func flatten(_ nodes: [MenuNode], file: MenuFile, prefix: String) -> [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case .separator: ["\(prefix)—"]
            case .command(_, let title): ["\(prefix)\(title) [command]"]
            case .action(let title, let index):
                ["\(prefix)\(title) [\(file.entries[index].op.rawValue)/\(file.entries[index].preset ?? "")]"]
            case .submenu(let title, let children):
                ["\(prefix)▸ \(title)"] + flatten(children, file: file, prefix: prefix + "  ")
            }
        }
    }
}
