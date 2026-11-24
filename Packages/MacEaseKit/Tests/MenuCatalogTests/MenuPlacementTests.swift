import Foundation
import Testing

@testable import MenuCatalog

@Suite struct MenuPlacementTests {
    private func catalog(
        placements: [String: MenuPlacement] = [:], hidden: Set<String> = [], speech: Bool = true
    ) -> MenuFile {
        MenuFile(
            token: "token", hostAvailable: true, visibleOperations: OperationID.menuOrder,
            titles: MenuTitles(
                operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue },
                speechAvailable: speech), hiddenEntries: hidden,
            arrangement: MenuArrangement.migrating(
                placements: placements, hiddenEntries: hidden, newInstallHidden: [], extraAngleEnabled: false
            ).arrangement, moreTitle: "More")
    }

    private func source(_ name: String) -> URL {
        URL(fileURLWithPath: "/missing/\(name)", isDirectory: name.hasSuffix("/"))
    }

    private func titles(_ nodes: [MenuNode]) -> [String] {
        nodes.compactMap {
            switch $0 {
            case .action(let title, _), .submenu(let title, _): title
            case .command(_, let title, _): title
            case .separator: nil
            }
        }
    }

    private func leaves(_ nodes: [MenuNode]) -> [Int] {
        nodes.flatMap { node -> [Int] in
            switch node {
            case .action(_, let index): [index]
            case .submenu(_, let children): leaves(children)
            case .command, .separator: []
            }
        }
    }

    @Test(arguments: [
        (
            "a.png",
            [
                "image.edit", "image.convert", "image.compress", "image.resize", "image.rotate", "image.background",
                "image.ocr",
            ]
        ),
        (
            "a.mov",
            [
                "video.edit", "video.convert", "video.compress", "video.resize", "video.extractAudio",
                "video.thumbnail", "video.subtitles",
            ]
        ),
        (
            "a.wav",
            ["audio.trim", "audio.enhance", "audio.convert", "audio.compress", "audio.normalize", "audio.subtitles"]
        ),
        (
            "a.pdf",
            [
                "pdf.editPages", "pdf.toImages", "pdf.toText", "pdf.compress", "pdf.rotate", "pdf.extractPages",
                "pdf.split",
            ]
        ),
        ("a.json", ["text.convert", "pretty", "minify", "sort"]),
        ("a.docx", ["document.convert"]), ("a.plist", ["plist.convert"]),
        (
            "folder/",
            [
                "folder.compress", "folder.rename", "folder.organize", "folder.analyze", "folder.removeDuplicates",
                "folder.removeEmpty",
            ]
        ),
        ("a.zip", ["archive.hatchExtract", "archive.browse"]), ("a.rar", ["archive.extract"]), ("a.jar", []),
        ("unknown.bin", []),
    ])
    func defaultsKeepFixedPrimaryOrder(name: String, expected: [String]) {
        let nodes = MenuLayout.tree(for: catalog(), selection: [source(name)]).macEase
        #expect(titles(nodes) == expected + ["More"])
    }

    @Test func pruningNeverBackfillsPrimarySlots() throws {
        let file = catalog(speech: false)
        let videos = MenuLayout.tree(for: file, selection: [source("a.mov"), source("b.mov")]).macEase
        #expect(
            titles(videos) == [
                "video.edit", "video.convert", "video.compress", "video.resize", "video.extractAudio",
                "video.thumbnail", "More",
            ])
        let pdfs = MenuLayout.tree(for: file, selection: [source("a.pdf"), source("b.pdf")]).macEase
        #expect(
            titles(pdfs) == [
                "pdf.merge", "pdf.toImages", "pdf.toText", "pdf.compress", "pdf.rotate", "pdf.split", "More",
            ])
        let text = MenuLayout.tree(for: file, selection: [source("a.txt")]).macEase
        #expect(titles(text) == ["More"])
        let hidden = MenuLayout.tree(for: catalog(hidden: ["video.edit/"]), selection: [source("a.mov")]).macEase
        #expect(titles(hidden).first == "video.convert")
        #expect(!titles(hidden).contains("video.rotate"))
    }

    @Test func moreContainsNonPrimaryAndAllFilesGroupsOnce() throws {
        let file = catalog()
        let nodes = MenuLayout.tree(for: file, selection: [source("a.mov")]).macEase
        guard case .submenu("More", let overflow) = try #require(nodes.last) else {
            Issue.record("Expected More last")
            return
        }
        #expect(
            titles(overflow) == [
                "video.rotate", "video.speed", "video.removeAudio", "video.fps", "video.background",
                "files.finish", "any.share", "any.findRelated", "any.protect", "any.checksum",
            ])
        #expect(nodes.dropLast().last == .separator)
        let images = MenuLayout.tree(for: file, selection: [source("a.png")]).macEase
        guard case .submenu("More", let imageMore) = images.last else {
            Issue.record("Expected image More")
            return
        }
        #expect(titles(imageMore).contains("image.enhance"))
        #expect(titles(imageMore).contains("image.traceSVG"))
    }

    @Test func placementsMoveWholeGroupsAndReorderEntries() throws {
        let original = catalog()
        let pinned = catalog(placements: ["video.convert": .more, "video.rotate": .primary, "any.checksum": .primary])
        let keys = { (file: MenuFile) in file.entries.map { $0.op.menuEntryKey($0.preset ?? "") } }
        #expect(Set(keys(original)) == Set(keys(pinned)))
        #expect(keys(original) != keys(pinned))
        let nodes = MenuLayout.tree(for: pinned, selection: [source("a.mov")]).macEase
        #expect(!titles(nodes).contains("video.convert"))
        #expect(titles(nodes).contains("video.rotate"))
        #expect(!titles(nodes).contains("any.checksum"))
        guard case .submenu("More", let overflow) = try #require(nodes.last),
            case .submenu("video.convert", let converted) = try #require(overflow.first)
        else {
            Issue.record("Expected whole Convert group in More")
            return
        }
        #expect(
            Set(leaves(converted).map { pinned.entries[$0].op }) == [
                .videoConvert, .videoToGIF, .videoToAnimatedWebP, .videoToAPNG, .videoHDRToSDR,
            ])
        let rotate = try #require(nodes.first { if case .submenu("video.rotate", _) = $0 { true } else { false } })
        #expect(Set(leaves([rotate]).map { pinned.entries[$0].op }) == [.videoRotate, .videoFlip])
        #expect(original.catalogVersion != pinned.catalogVersion)
    }

    @Test func additionalPinsFollowTheFixedPrimaryGroups() {
        let file = catalog(placements: ["image.enhance": .primary, "image.traceSVG": .primary])
        let nodes = MenuLayout.tree(for: file, selection: [source("a.png")]).macEase
        #expect(
            titles(nodes) == [
                "image.edit", "image.convert", "image.compress", "image.resize", "image.rotate", "image.background",
                "image.ocr", "image.enhance", "image.traceSVG", "More",
            ])
    }

    @Test func fileOrderIsDisplayOrder() {
        let entries = [
            MenuEntry(op: .videoThumbnail, preset: "first", path: ["Thumbnail", "First"]),
            MenuEntry(op: .videoExtractAudio, preset: "wav", path: ["Extract Audio", "WAV"]),
        ]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:])
        let nodes = MenuLayout.tree(for: file, selection: [source("a.mov")]).macEase
        #expect(titles(nodes) == ["Thumbnail", "Extract Audio"])
        #expect(leaves(nodes) == [0, 1])
        let reversed = MenuFile(token: "token", hostAvailable: true, entries: entries.reversed(), kinds: [:])
        #expect(
            titles(MenuLayout.tree(for: reversed, selection: [source("a.mov")]).macEase) == [
                "Extract Audio", "Thumbnail",
            ])
    }

    @Test func equalLocalizedTitlesNeverMergeDistinctGroups() {
        let entries = [
            MenuEntry(op: .imageRotate, preset: "180", path: ["Shared", "Rotate"]),
            MenuEntry(op: .imageBackground, preset: "remove", path: ["Shared", "Remove"]),
        ]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:])
        #expect(
            MenuLayout.tree(for: file, selection: [source("a.png")]).macEase == [
                .submenu(title: "Shared", children: [.action(title: "Rotate", entryIndex: 0)]),
                .submenu(title: "Shared", children: [.action(title: "Remove", entryIndex: 1)]),
            ])
    }

    @Test(arguments: [MenuPlacement.more, .primary])
    func recipesStayOneGroupAcrossAcceptedKinds(placement: MenuPlacement) throws {
        let entries = [
            MenuEntry(op: .filesFinish, preset: nil, path: ["Finish", "Choose"], placement: placement),
            MenuEntry(
                op: .filesFinish, preset: nil, path: ["Finish", "Photo"],
                recipeID: UUID(), acceptedKinds: [.image], placement: placement),
            MenuEntry(
                op: .filesFinish, preset: nil, path: ["Finish", "Media"],
                recipeID: UUID(), acceptedKinds: [.image, .video], placement: placement),
        ]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:], moreTitle: "More")
        let nodes = MenuLayout.tree(for: file, selection: [source("a.png"), source("b.mov")]).macEase
        let choices: [MenuNode] = [.action(title: "Choose", entryIndex: 0), .action(title: "Media", entryIndex: 2)]
        let expected: [MenuNode] =
            placement == .more
            ? [.submenu(title: "More", children: [.submenu(title: "any (2): Finish", children: choices)])]
            : [.submenu(title: "Finish", children: choices)]
        #expect(nodes == expected)
    }

    @Test func allFilesInTheMacEaseMenuFollowKindItemsBehindASeparator() throws {
        var any = MenuGroupCatalog.current.defaultArrangement(.any)
        any.move([MenuGroupID(rawValue: "any.checksum")], to: .menu)
        var arrangement = MenuArrangement()
        arrangement.set(any)
        let file = MenuFile(
            token: "token", hostAvailable: true, visibleOperations: OperationID.menuOrder,
            titles: MenuTitles(operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue }),
            arrangement: arrangement, moreTitle: "More")
        let single = MenuLayout.tree(for: file, selection: [source("a.pdf")]).macEase
        #expect(titles(single).suffix(2) == ["any.checksum", "More"])
        let checksum = try #require(
            single.firstIndex { if case .submenu("any.checksum", _) = $0 { true } else { false } })
        #expect(single[checksum - 1] == .separator)
        #expect(titles(single)[checksum - 2] == "pdf.split")
        let mixed = MenuLayout.tree(for: file, selection: [source("a.png"), source("b.mov")]).macEase
        #expect(titles(mixed) == ["image (1)", "video (1)", "any.checksum", "More"])
        #expect(mixed[2] == .separator)
        let unknown = MenuLayout.tree(for: file, selection: [source("a.bin")]).macEase
        #expect(titles(unknown) == ["any.checksum", "More"])
        checkStructure(mixed, level: 2)
    }

    @Test func jsonLeavesHaveIndependentPlacementGroups() {
        let file = catalog(placements: ["text.json/minify": .more])
        let nodes = MenuLayout.tree(for: file, selection: [source("a.json")]).macEase
        #expect(titles(nodes) == ["text.convert", "pretty", "sort", "More"])
        #expect(
            file.entries.filter { $0.op == .textJSON }.map(\.groupID) == [
                "text.json/pretty", "text.json/sort", "text.json/minify",
            ])
    }

    @Test func mixedSelectionPrefixesMoreGroupsWithoutAnotherKindLevel() throws {
        let file = catalog()
        let selection = [source("a.png"), source("b.mov"), source("c.json")]
        let nodes = MenuLayout.tree(for: file, selection: selection).macEase
        #expect(titles(nodes) == ["image (1)", "video (1)", "text (1)", "More"])
        guard case .submenu("More", let overflow) = try #require(nodes.last) else {
            Issue.record("Expected More last")
            return
        }
        #expect(titles(overflow).contains("video (1): video.fps"))
        #expect(titles(overflow).contains("image (1): image.traceSVG"))
        #expect(titles(overflow).contains("text (1): text.encoding"))
        #expect(titles(overflow).filter { $0 == "any (3): any.checksum" }.count == 1)
        checkStructure(nodes, level: 2)
    }

    @Test func everyApplicableLeafIsReachableAtItsOriginalIndex() {
        let file = catalog(placements: ["image.rotate": .more, "video.fps": .primary])
        for selection in [
            ["a.png"], ["a.mov"], ["a.wav"], ["a.pdf"], ["a.json"], ["a.docx"], ["a.plist"], ["folder/"],
            ["a.jar"], ["a.zip"], ["a.rar"], ["a.png", "b.mov", "c.json", "folder/", "unknown.bin"],
        ] {
            let urls = selection.map(source)
            let nodes = MenuLayout.tree(for: file, selection: urls).macEase
            let expected = file.entries.indices.filter {
                file.entries[$0].op != .folderDownloadMedia
                    && MenuLayout.isApplicable(file.entries[$0], selection: urls)
            }
            let indices = leaves(nodes)
            #expect(indices.sorted() == expected)
            #expect(Set(indices).count == indices.count)
            checkStructure(nodes, level: 2)
        }
    }

    @Test func randomArrangementsKeepEveryLeafReachableOnce() {
        var random = SeededRandom(seed: 0xA11_1EAF)
        let selections = [
            ["a.png"], ["a.mov"], ["a.wav"], ["a.pdf", "b.pdf"], ["a.json"], ["folder/"], ["a.zip"], ["unknown.bin"],
            ["a.png", "b.mov", "c.json", "folder/", "unknown.bin"],
        ].map { $0.map(source) }
        for _ in 0..<40 {
            var arrangement = MenuArrangement()
            for scope in MenuScope.allCases {
                var edited = arrangement.resolved(scope)
                for _ in 0..<6 {
                    let count = UInt64(edited.rows.count)
                    edited.move(
                        fromOffsets: IndexSet([Int(random.next() % count)]), toOffset: Int(random.next() % (count + 1)))
                }
                arrangement.set(edited)
            }
            let file = MenuFile(
                token: "token", hostAvailable: true, visibleOperations: OperationID.menuOrder,
                titles: MenuTitles(operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue }),
                arrangement: arrangement, moreTitle: "More", commandTitles: [.update: "Update", .preview: "Preview"])
            for urls in selections {
                let tree = MenuLayout.tree(for: file, selection: urls)
                let expected = file.entries.indices.filter {
                    MenuLayout.isApplicable(file.entries[$0], selection: urls)
                }
                let indices = leaves(tree.finder) + leaves(tree.macEase)
                #expect(indices.sorted() == expected)
                #expect(Set(indices).count == indices.count)
                if !tree.macEase.isEmpty { checkStructure(tree.macEase, level: 2) }
            }
        }
    }

    @Test func reorderedSectionsDropOnlyClusterSeparators() {
        func menu(_ edit: (inout ScopeArrangement) -> Void, scope: MenuScope, selection: String) -> [MenuNode] {
            var scoped = MenuGroupCatalog.current.defaultArrangement(scope)
            edit(&scoped)
            var arrangement = MenuArrangement()
            arrangement.set(scoped)
            let file = MenuFile(
                token: "token", hostAvailable: true, visibleOperations: OperationID.menuOrder,
                titles: MenuTitles(operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue }),
                arrangement: arrangement, moreTitle: "More")
            return MenuLayout.tree(for: file, selection: [source(selection)]).macEase
        }
        let canonical = menu({ $0.hide([MenuGroupID(rawValue: "folder.organize")]) }, scope: .folder, selection: "f/")
        #expect(
            titles(canonical) == [
                "folder.compress", "folder.rename", "folder.analyze", "folder.removeDuplicates", "folder.removeEmpty",
                "More",
            ])
        #expect(canonical[3] == .separator)
        let reordered = menu(
            { $0.move([MenuGroupID(rawValue: "folder.removeEmpty")], to: .menu, at: 0) }, scope: .folder,
            selection: "f/")
        #expect(
            titles(reordered) == [
                "folder.removeEmpty", "folder.compress", "folder.rename", "folder.organize", "folder.analyze",
                "folder.removeDuplicates", "More",
            ])
        #expect(reordered.filter { $0 == .separator }.count == 1)
        guard case .submenu("More", let more) = reordered.last else {
            Issue.record("Expected More last")
            return
        }
        #expect(titles(more) == ["folder.tree", "folder.aiRename"])
        #expect(more.contains(.separator))
    }

    @Test func commandsFollowTheirSections() throws {
        var commands = MenuGroupCatalog.current.defaultArrangement(.commands)
        commands.move([MenuGroupID(rawValue: "folder.downloadMedia")], to: .menu, at: 1)
        commands.move([MenuGroupID(.preview)], to: .more)
        var arrangement = MenuArrangement()
        arrangement.set(commands)
        let titled = MenuTitles(operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue })
        let file = MenuFile(
            token: "token", hostAvailable: true, visibleOperations: OperationID.menuOrder, titles: titled,
            arrangement: arrangement, moreTitle: "More", commandTitles: [.update: "Update", .preview: "Preview"])
        #expect(file.commands.map(\.placement) == [.primary, .primary, .more])
        let tree = MenuLayout.tree(for: file, selection: [source("folder/")])
        #expect(tree.finder.isEmpty)
        let download = try #require(file.entries.firstIndex { $0.op == .folderDownloadMedia })
        #expect(
            Array(tree.macEase.prefix(3)) == [
                .command(.update, title: "Update"), .action(title: "folder.downloadMedia", entryIndex: download),
                .separator,
            ])
        guard case .submenu("More", let more) = try #require(tree.macEase.last) else {
            Issue.record("Expected More last")
            return
        }
        #expect(Array(more.suffix(2)) == [.separator, .command(.preview, title: "Preview")])
        let image = MenuLayout.tree(for: file, selection: [source("a.png")])
        #expect(image.macEase.first == .command(.update, title: "Update"))
        #expect(image.macEase[1] == .separator)
        commands.move([MenuGroupID(.update)], to: .finder)
        commands.hide([MenuGroupID(.preview)])
        arrangement.set(commands)
        let moved = MenuFile(
            token: "token", hostAvailable: true, visibleOperations: OperationID.menuOrder, titles: titled,
            arrangement: arrangement, moreTitle: "More", commandTitles: [.update: "Update", .preview: "Preview"])
        #expect(
            MenuLayout.tree(for: moved, selection: [source("a.png")]).finder == [.command(.update, title: "Update")])
        #expect(moved.commands.map(\.command) == [.update, nil])
        #expect(moved.catalogVersion != file.catalogVersion)
    }

    @Test func schemaThreeFilesAndMissingPlacementsAreRejected() throws {
        let file = catalog()
        var encoded = try #require(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        encoded["schema"] = 3
        encoded.removeValue(forKey: "commands")
        encoded["updateTitle"] = "Update"
        #expect(throws: MenuFileError.unsupportedSchema(3)) {
            try MenuFile(json: JSONSerialization.data(withJSONObject: encoded))
        }
        encoded["schema"] = MenuFile.currentSchema
        encoded["commands"] = []
        var entries = try #require(encoded["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "placement")
        encoded["entries"] = entries
        #expect(throws: DecodingError.self) { try MenuFile(json: JSONSerialization.data(withJSONObject: encoded)) }
    }

    @Test func groupPlacementAndMoreTitleInvalidateCatalog() {
        let original = MenuEntry(op: .imageRotate, preset: "180", path: ["Rotate", "180"])
        let grouped = MenuEntry(op: .imageRotate, preset: "180", path: ["Rotate", "180"], groupID: "image.rotate")
        let moved = MenuEntry(op: .imageRotate, preset: "180", path: ["Rotate", "180"], placement: .more)
        #expect(MenuFile.version(of: [original]) != MenuFile.version(of: [grouped]))
        #expect(MenuFile.version(of: [original]) != MenuFile.version(of: [moved]))
        #expect(
            MenuFile.version(of: [original], moreTitle: "More") != MenuFile.version(of: [original], moreTitle: "Other"))
    }

    @Test func emptyMoreAndPrunedGroupsDisappear() {
        let entries = [MenuEntry(op: .pdfMerge, preset: nil, path: ["Merge"])]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:])
        #expect(MenuLayout.tree(for: file, selection: [source("a.pdf")]).macEase.isEmpty)
        #expect(
            MenuLayout.tree(for: file, selection: [source("a.pdf"), source("b.pdf")]).macEase == [
                .action(title: "Merge", entryIndex: 0)
            ])
    }

    private func checkStructure(_ nodes: [MenuNode], level: Int) {
        #expect(level <= 4)
        #expect(!nodes.isEmpty)
        #expect(nodes.first != .separator && nodes.last != .separator)
        #expect(!zip(nodes, nodes.dropFirst()).contains { $0 == .separator && $1 == .separator })
        for node in nodes {
            if case .submenu(_, let children) = node { checkStructure(children, level: level + 1) }
        }
    }
}
