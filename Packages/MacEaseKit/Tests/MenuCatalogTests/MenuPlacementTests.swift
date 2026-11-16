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
                speechAvailable: speech), hiddenEntries: hidden, placements: placements, moreTitle: "More")
    }

    private func source(_ name: String) -> URL {
        URL(fileURLWithPath: "/missing/\(name)", isDirectory: name.hasSuffix("/"))
    }

    private func titles(_ nodes: [MenuNode]) -> [String] {
        nodes.compactMap {
            switch $0 {
            case .action(let title, _), .submenu(let title, _): title
            case .separator: nil
            }
        }
    }

    private func leaves(_ nodes: [MenuNode]) -> [Int] {
        nodes.flatMap { node -> [Int] in
            switch node {
            case .action(_, let index): [index]
            case .submenu(_, let children): leaves(children)
            case .separator: []
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
        let nodes = MenuLayout.nodes(for: catalog(), selection: [source(name)])
        #expect(titles(nodes) == expected + ["More"])
    }

    @Test func pruningNeverBackfillsPrimarySlots() throws {
        let file = catalog(speech: false)
        let videos = MenuLayout.nodes(for: file, selection: [source("a.mov"), source("b.mov")])
        #expect(
            titles(videos) == [
                "video.edit", "video.convert", "video.compress", "video.resize", "video.extractAudio",
                "video.thumbnail", "More",
            ])
        let pdfs = MenuLayout.nodes(for: file, selection: [source("a.pdf"), source("b.pdf")])
        #expect(
            titles(pdfs) == [
                "pdf.merge", "pdf.toImages", "pdf.toText", "pdf.compress", "pdf.rotate", "pdf.split", "More",
            ])
        let text = MenuLayout.nodes(for: file, selection: [source("a.txt")])
        #expect(titles(text) == ["More"])
        let hidden = MenuLayout.nodes(for: catalog(hidden: ["video.edit/"]), selection: [source("a.mov")])
        #expect(titles(hidden).first == "video.convert")
        #expect(!titles(hidden).contains("video.rotate"))
    }

    @Test func moreContainsNonPrimaryAndAllFilesGroupsOnce() throws {
        let file = catalog()
        let nodes = MenuLayout.nodes(for: file, selection: [source("a.mov")])
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
        let images = MenuLayout.nodes(for: file, selection: [source("a.png")])
        guard case .submenu("More", let imageMore) = images.last else {
            Issue.record("Expected image More")
            return
        }
        #expect(titles(imageMore).contains("image.enhance"))
        #expect(titles(imageMore).contains("image.traceSVG"))
    }

    @Test func placementsMoveWholeGroupsWithoutChangingEntryIndices() throws {
        let original = catalog()
        let pinned = catalog(placements: ["video.convert": .more, "video.rotate": .primary, "any.checksum": .primary])
        #expect(original.entries.map(\.op) == pinned.entries.map(\.op))
        #expect(original.entries.map(\.preset) == pinned.entries.map(\.preset))
        let nodes = MenuLayout.nodes(for: pinned, selection: [source("a.mov")])
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
        let nodes = MenuLayout.nodes(for: file, selection: [source("a.png")])
        #expect(
            titles(nodes) == [
                "image.edit", "image.convert", "image.compress", "image.resize", "image.rotate", "image.background",
                "image.ocr", "image.enhance", "image.traceSVG", "More",
            ])
    }

    @Test func legacyCatalogOrderChangesOnlyPresentationIndices() {
        let entries = [
            MenuEntry(op: .videoThumbnail, preset: "first", path: ["Thumbnail", "First"]),
            MenuEntry(op: .videoExtractAudio, preset: "wav", path: ["Extract Audio", "WAV"]),
        ]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:])
        let nodes = MenuLayout.nodes(for: file, selection: [source("a.mov")])
        #expect(titles(nodes) == ["Extract Audio", "Thumbnail"])
        #expect(leaves(nodes) == [1, 0])
    }

    @Test func equalLocalizedTitlesNeverMergeDistinctGroups() {
        let entries = [
            MenuEntry(op: .imageRotate, preset: "180", path: ["Shared", "Rotate"]),
            MenuEntry(op: .imageBackground, preset: "remove", path: ["Shared", "Remove"]),
        ]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:])
        #expect(
            MenuLayout.nodes(for: file, selection: [source("a.png")]) == [
                .submenu(title: "Shared", children: [.action(title: "Rotate", entryIndex: 0)]),
                .submenu(title: "Shared", children: [.action(title: "Remove", entryIndex: 1)]),
            ])
    }

    @Test func recipesStayOneMoreGroupAcrossAcceptedKinds() throws {
        let entries = [
            MenuEntry(op: .filesFinish, preset: nil, path: ["Finish", "Choose"], placement: .primary),
            MenuEntry(
                op: .filesFinish, preset: nil, path: ["Finish", "Photo"],
                recipeID: UUID(), acceptedKinds: [.image], placement: .primary),
            MenuEntry(
                op: .filesFinish, preset: nil, path: ["Finish", "Media"],
                recipeID: UUID(), acceptedKinds: [.image, .video], placement: .primary),
        ]
        let file = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:], moreTitle: "More")
        let nodes = MenuLayout.nodes(for: file, selection: [source("a.png"), source("b.mov")])
        #expect(
            nodes == [
                .submenu(
                    title: "More",
                    children: [
                        .submenu(
                            title: "any (2): Finish",
                            children: [
                                .action(title: "Choose", entryIndex: 0), .action(title: "Media", entryIndex: 2),
                            ])
                    ])
            ])
    }

    @Test func jsonLeavesHaveIndependentPlacementGroups() {
        let file = catalog(placements: ["text.json/minify": .more])
        let nodes = MenuLayout.nodes(for: file, selection: [source("a.json")])
        #expect(titles(nodes) == ["text.convert", "pretty", "sort", "More"])
        #expect(
            file.entries.filter { $0.op == .textJSON }.map(\.groupID) == [
                "text.json/pretty", "text.json/minify", "text.json/sort",
            ])
    }

    @Test func mixedSelectionPrefixesMoreGroupsWithoutAnotherKindLevel() throws {
        let file = catalog()
        let selection = [source("a.png"), source("b.mov"), source("c.json")]
        let nodes = MenuLayout.nodes(for: file, selection: selection)
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
            let nodes = MenuLayout.nodes(for: file, selection: urls)
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

    @Test func legacySchemaThreeFallsBackToDefaultPlacement() throws {
        let file = catalog()
        var encoded = try #require(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        var entries = try #require(encoded["entries"] as? [[String: Any]])
        for index in entries.indices {
            entries[index].removeValue(forKey: "groupID")
            entries[index].removeValue(forKey: "placement")
        }
        encoded["entries"] = entries
        encoded.removeValue(forKey: "moreTitle")
        let legacy = try MenuFile(json: JSONSerialization.data(withJSONObject: encoded))
        #expect(legacy.schema == 3)
        #expect(legacy.moreTitle == nil)
        #expect(legacy.entries.allSatisfy { $0.groupID == nil && $0.placement == nil })
        let selection = [source("a.mov")]
        #expect(
            MenuLayout.nodes(for: legacy, selection: selection) == MenuLayout.nodes(for: file, selection: selection))
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
        #expect(MenuLayout.nodes(for: file, selection: [source("a.pdf")]).isEmpty)
        #expect(
            MenuLayout.nodes(for: file, selection: [source("a.pdf"), source("b.pdf")]) == [
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
