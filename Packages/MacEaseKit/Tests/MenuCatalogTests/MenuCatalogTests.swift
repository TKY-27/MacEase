import Foundation
import Testing

@testable import MenuCatalog

private let titles = MenuTitles(
    operation: { $0.rawValue },
    preset: { op, preset in "\(op.rawValue)/\(preset)" },
    kind: { $0.rawValue.capitalized }
)

private func menuFile(_ operations: [OperationID] = OperationID.allCases) -> MenuFile {
    MenuFile(
        token: String(repeating: "a", count: 64), hostAvailable: true, visibleOperations: operations, titles: titles)
}

@Suite struct ClassificationTests {
    @Test(arguments: [
        ("photo.HEIC", FileKind.image), ("clip.mkv", .video), ("song.opus", .audio), ("doc.pdf", .pdf),
        ("data.yml", .text), ("backup.tgz", .archive), ("lib.jar", .jar), ("raw.CR3", .image),
    ])
    func classifiesFilesByExtension(name: String, kind: FileKind) {
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: false)) == kind)
    }

    @Test func unknownExtensionHasNoKind() {
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/notes.pages", isDirectory: false)) == nil)
    }

    @Test func directoriesAreFoldersButPackagesAreFiles() {
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/Photos 2024.v2", isDirectory: true)) == .folder)
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)) == nil)
    }
}

@Suite struct MenuFileTests {
    @Test func schemaThreeFilesAreRejected() {
        let json = Data(
            #"{"schema":3,"catalogVersion":"legacy","token":"token","hostAvailable":true,"entries":[],"kinds":{}}"#.utf8
        )
        #expect(throws: MenuFileError.unsupportedSchema(3)) { try MenuFile(json: json) }
    }

    @Test(arguments: [HostCommand.preview, .update])
    func commandTitlesRoundTripAndInvalidateTheCatalog(command: HostCommand) throws {
        let original = menuFile()
        var versions: Set<String> = [original.catalogVersion]
        for title in ["Finder Preview", "Finderプレビュー", "Update Available (v3.2.0)"] {
            let titled = MenuFile(
                token: original.token, hostAvailable: true, visibleOperations: OperationID.allCases, titles: titles,
                commandTitles: [command: title])
            let decoded = try MenuFile(json: titled.encoded())
            #expect(decoded.schema == 4)
            #expect(
                decoded.commands.filter { $0.command != nil }
                    == [MenuCommandItem(group: MenuGroupID(command), title: title, placement: .primary)])
            #expect(decoded.entries == original.entries)
            #expect(decoded == titled)
            #expect(versions.insert(titled.catalogVersion).inserted)
        }
        let cleared = MenuFile(
            token: original.token, hostAvailable: true, entries: original.entries, kinds: [:],
            commands: original.commands)
        #expect(cleared.catalogVersion == original.catalogVersion)
    }

    @Test func commandOrderAndPlacementInvalidateTheCatalog() {
        let update = MenuCommandItem(group: MenuGroupID(.update), title: "Update", placement: .primary)
        let preview = MenuCommandItem(group: MenuGroupID(.preview), title: "Preview", placement: .primary)
        let moved = MenuCommandItem(group: MenuGroupID(.preview), title: "Preview", placement: .more)
        let versions = [[update, preview], [preview, update], [update, moved], [update], []].map {
            MenuFile.version(of: [], commands: $0)
        }
        #expect(Set(versions).count == versions.count)
    }

    @Test func duplicateTitleChangesInvalidatePreviousCatalogs() {
        let ask = MenuFile(
            token: "token", hostAvailable: true,
            entries: [MenuEntry(op: .folderRemoveDuplicates, preset: nil, path: ["Remove Duplicates…"])],
            kinds: [.folder: "Folders"])
        let automatic = MenuFile(
            token: "token", hostAvailable: true,
            entries: [MenuEntry(op: .folderRemoveDuplicates, preset: nil, path: ["Remove Duplicates"])],
            kinds: [.folder: "Folders"])

        #expect(ask.catalogVersion != automatic.catalogVersion)
    }

    @Test func everyOperationWithPresetsEndsWithCustom() {
        let file = menuFile()
        for op in OperationID.allCases where op.offersCustom {
            let entries = file.entries.filter { $0.op == op }
            #expect(entries.map(\.preset) == op.presets + [MenuEntry.customPreset])
        }
    }

    @Test func versionChangesWithEntriesAndRoundTripsThroughJSON() throws {
        let full = menuFile()
        let reduced = menuFile(OperationID.allCases.filter { $0 != .imageResize })
        #expect(full.catalogVersion != reduced.catalogVersion)
        #expect(full.catalogVersion.count == 64)
        let decoded = try MenuFile(json: try full.encoded())
        #expect(decoded == full)
        #expect(
            MenuFile.version(of: decoded.entries, moreTitle: decoded.moreTitle, commands: decoded.commands)
                == full.catalogVersion)
    }
}

@Suite struct MenuLayoutTests {
    private func url(_ name: String, directory: Bool = false) -> URL {
        URL(fileURLWithPath: "/Users/me/\(name)", isDirectory: directory)
    }

    @Test func singleKindListsPrimariesThenMore() throws {
        let file = menuFile()
        let nodes = MenuLayout.tree(for: file, selection: [url("a.png"), url("b.jpg")]).macEase
        guard case .action(_, let editIndex) = try #require(nodes.first) else {
            Issue.record("expected photo editing first")
            return
        }
        #expect(file.entries[editIndex].op == .imageEdit)
        guard case .submenu(let title, let children) = try #require(nodes.dropFirst().first) else {
            Issue.record("expected submenu")
            return
        }
        #expect(title == "image.convert")
        #expect(children.suffix(2).first == .separator)
        #expect(nodes.contains(.separator))
        #expect(nodes.last.map { if case .submenu(let title, _) = $0 { title } else { "" } } == "More")
        #expect(!nodes.contains { if case .submenu(let title, _) = $0 { title.hasPrefix("video") } else { false } })
    }

    @Test func mixedSelectionGroupsByKindWithCounts() {
        let nodes = MenuLayout.tree(for: menuFile(), selection: [url("a.png"), url("b.mov"), url("c.mp4")]).macEase
        let titles = nodes.compactMap { if case .submenu(let title, _) = $0 { title } else { nil } }
        #expect(titles == ["Image (1)", "Video (2)", "More"])
    }

    @Test func pdfMergeNeedsTwoPDFs() {
        let file = menuFile([.pdfMerge, .pdfSplit])
        let one = MenuLayout.tree(for: file, selection: [url("a.pdf")]).macEase
        let two = MenuLayout.tree(for: file, selection: [url("a.pdf"), url("b.pdf")]).macEase
        func operations(_ nodes: [MenuNode]) -> [OperationID] {
            nodes.compactMap { node in
                if case .action(_, let index) = node { return file.entries[index].op }
                return nil
            }
        }
        #expect(operations(one) == [.pdfSplit])
        #expect(operations(two) == [.pdfMerge, .pdfSplit])
    }

    @Test func foldersGetNoAllFilesSection() {
        let nodes = MenuLayout.tree(for: menuFile(), selection: [url("Docs", directory: true)]).macEase
        #expect(nodes.filter { $0 == .separator }.count == 2)
        #expect(!nodes.contains { if case .submenu("any.checksum", _) = $0 { true } else { false } })
        #expect(!nodes.isEmpty)
    }

    @Test func entryIndicesPointAtTheirEntries() {
        let file = menuFile()
        func leaves(_ nodes: [MenuNode]) -> [(String, Int)] {
            nodes.flatMap { node -> [(String, Int)] in
                switch node {
                case .submenu(_, let children): leaves(children)
                case .action(let title, let index): [(title, index)]
                case .command, .separator: []
                }
            }
        }
        for (title, index) in leaves(MenuLayout.tree(for: file, selection: [url("a.wav"), url("b.txt")]).macEase) {
            let entry = file.entries[index]
            let leafTitle = entry.path.last ?? ""
            let expected =
                entry.path.count == 1 && entry.placement == .more
                ? "\(file.kindTitle(entry.kind)) (\(entry.kind == .any ? 2 : 1)): \(leafTitle)" : leafTitle
            #expect(title == expected)
        }
    }

    @Test func buildsWithinBudgetForOneThousandItems() {
        let file = menuFile()
        let selection = (0..<1000).map { url("file \($0).\(["png", "mov", "mp3", "pdf"][$0 % 4])") }
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MenuLayout.tree(for: file, selection: selection).macEase }
        #expect(elapsed < .milliseconds(30))
    }
}

@Suite struct MenuRestructureTests {
    private func selection(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/missing/\($0)", isDirectory: false) }
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

    private func presets(_ op: OperationID, _ names: [String]) -> Set<String> {
        let file = menuFile()
        return Set(
            leaves(MenuLayout.tree(for: file, selection: selection(names)).macEase).compactMap {
                file.entries[$0].op == op ? file.entries[$0].preset : nil
            })
    }

    @Test func customExistsForSizeAndPlaybackSpeedOperations() {
        let file = menuFile()
        #expect(
            Set(file.entries.filter(\.isCustom).map(\.op)) == [
                .imageResize, .videoResize, .imageCompress, .videoCompress, .audioCompress, .videoSpeed,
            ])
        #expect(file.entries.contains { $0.op == .videoThumbnail && $0.preset == "choose-frame" && !$0.isCustom })
        #expect(file.entries.filter { $0.op == .imageConvert }.count == 14)
    }

    @Test func sharedSubmenusAndFlatJSONHaveExpectedPaths() throws {
        let file = menuFile()
        #expect(
            file.entries.filter { $0.op == .imageFlip }.map(\.path) == [
                ["image.rotate", "image.flip/horizontal"], ["image.rotate", "image.flip/vertical"],
            ])
        #expect(
            file.entries.filter { [.videoToGIF, .videoToAnimatedWebP, .videoToAPNG].contains($0.op) }
                .map(\.path) == [
                    ["video.convert", "video.toGIF/settings"], ["video.convert", "video.toGIF/x"],
                    ["video.convert", "video.toAnimatedWebP/settings"], ["video.convert", "video.toAPNG/settings"],
                ])
        #expect(file.entries.filter { $0.op == .textJSON }.allSatisfy { $0.path.count == 1 })
        let rotate = MenuLayout.tree(for: file, selection: selection(["photo.png"])).macEase.first {
            if case .submenu("image.rotate", _) = $0 { true } else { false }
        }
        guard case .submenu(_, let children) = try #require(rotate) else {
            Issue.record("Expected Rotate submenu")
            return
        }
        #expect(children.count == 6)
        #expect(children[3] == .separator)
    }

    @Test func hiddenFlipDoesNotHideRotate() {
        let file = menuFile(OperationID.allCases.filter { $0 != .imageFlip })
        let indices = leaves(MenuLayout.tree(for: file, selection: selection(["photo.png"])).macEase)
        #expect(indices.contains { file.entries[$0].op == .imageRotate })
        #expect(!indices.contains { file.entries[$0].op == .imageFlip })
    }

    @Test func extraAngleIsOneStableSlotAndChangesVersion() {
        func catalog(_ degrees: Double?) -> MenuFile {
            MenuFile(
                token: "token", hostAvailable: true, visibleOperations: [.imageRotate, .videoRotate],
                titles: titles, extraRotationDegrees: degrees)
        }
        #expect(!catalog(nil).entries.contains { $0.preset == "extra-angle" })
        #expect(catalog(45).entries.filter { $0.preset == "extra-angle" }.count == 2)
        #expect(catalog(45).entries.filter { $0.preset == "extra-angle" }.allSatisfy { $0.rotationDegrees == 45 })
        #expect(catalog(45).catalogVersion != catalog(30).catalogVersion)
    }

    @Test func schemaOneIsRejectedBeforeEntriesDecode() throws {
        let legacy = Data(#"{"schema":1,"entries":[]}"#.utf8)
        #expect(throws: MenuFileError.unsupportedSchema(1)) { try MenuFile(json: legacy) }
        #expect(MenuFile.currentSchema == 4)
        let previous = Data(#"{"schema":2,"entries":[]}"#.utf8)
        #expect(throws: MenuFileError.unsupportedSchema(2)) { try MenuFile(json: previous) }
    }

    @Test func separatorsAndConstraintsAreSerializedAndHashed() throws {
        let grouped = MenuEntry(op: .audioTrim, preset: nil, path: ["Trim"], separatorBefore: true)
        let plain = MenuEntry(op: .audioTrim, preset: nil, path: ["Trim"])
        #expect(MenuFile.version(of: [grouped]) != MenuFile.version(of: [plain]))
        let file = MenuFile(token: "token", hostAvailable: true, entries: [grouped], kinds: [:])
        let decoded = try MenuFile(json: file.encoded())
        #expect(decoded.entries[0].separatorBefore)
        #expect(decoded.entries[0].minimumSelection == 1)
        #expect(decoded.entries[0].maximumSelection == 1)
    }

    @Test func resolvedValuesInvalidateCatalogEvenWithUnchangedTitles() {
        func file(rate: Int, loudness: Double, version: String) -> MenuFile {
            MenuFile(
                token: "token", hostAvailable: true, visibleOperations: [.videoFPS, .audioNormalize],
                titles: titles, frameRates: ["24": rate], loudnessTargets: ["lufs-14": loudness],
                parameterVersion: version)
        }
        #expect(
            file(rate: 24, loudness: -14, version: "a").catalogVersion
                != file(rate: 25, loudness: -14, version: "a").catalogVersion)
        #expect(
            file(rate: 24, loudness: -14, version: "a").catalogVersion
                != file(rate: 24, loudness: -16, version: "a").catalogVersion)
        #expect(
            file(rate: 24, loudness: -14, version: "a").catalogVersion
                != file(rate: 24, loudness: -14, version: "b").catalogVersion)
    }

    @Test func hiddenGroupLeadersKeepOperationSeparators() {
        let file = menuFile([.imageResize, .imageIconSet, .imageAIRename])
        let nodes = MenuLayout.tree(for: file, selection: selection(["photo.png"])).macEase
        #expect(nodes.filter { $0 == .separator }.count == 1)
        guard case .submenu("More", let overflow) = nodes.last else {
            Issue.record("Expected More submenu")
            return
        }
        #expect(overflow.filter { $0 == .separator }.count == 1)
        checkSeparators(nodes)
        let hiddenLeaf = MenuFile(
            token: "token", hostAvailable: true,
            visibleOperations: [.textEncoding, .textJSON], titles: titles,
            hiddenEntries: ["text.json/pretty"])
        let json = MenuLayout.tree(for: hiddenLeaf, selection: selection(["notes.json"])).macEase
        #expect(json.filter { $0 == .separator }.count == 1)
        checkSeparators(json)
    }

    @Test(arguments: [
        (["a.jpg", "b.JPE"], "jpeg"), (["a.tif", "b.tiff"], "tiff"),
        (["a.heif", "b.hif"], "heic"), (["a.png", "b.png"], "png"),
    ])
    func imageAliasesPruneOnlyUniformTargets(names: [String], target: String) {
        #expect(!presets(.imageConvert, names).contains(target))
        #expect(presets(.imageConvert, [names[0], "other.avif"]).contains(target))
    }

    @Test func videoAndAudioPruneKnownFormatsButKeepM4AVariants() {
        #expect(!presets(.videoConvert, ["a.m4v"]).contains("m4v"))
        #expect(presets(.videoConvert, ["a.m4v"]).contains("mp4"))
        #expect(presets(.videoConvert, ["a.mp4"]).contains("m4v"))
        #expect(!presets(.videoConvert, ["a.mov"]).contains("mov"))
        #expect(presets(.videoConvert, ["a.mov", "b.mp4"]).contains("mov"))
        #expect(!presets(.audioConvert, ["a.aif", "b.aiff"]).contains("aiff"))
        #expect(!presets(.audioConvert, ["a.oga", "b.ogg"]).contains("ogg"))
        #expect(presets(.audioConvert, ["a.m4a"]).isSuperset(of: ["m4a-aac", "m4a-alac"]))
        #expect(presets(.audioConvert, ["a.mp3", "b.wav"]).contains("mp3"))
    }

    private static let textTargets: [(String, Set<String>)] = [
        ("csv", Set(["csv-json", "csv-xml", "csv-html", "csv-md", "txt"])),
        (
            "json",
            Set(["json-csv", "json-xml", "json-plist-xml", "json-plist-binary", "json-yaml", "json-toml", "txt"])
        ),
        ("xml", Set(["xml-json", "txt"])),
        ("md", Set(["md-html", "md-pdf", "txt"])), ("markdown", Set(["md-html", "md-pdf", "txt"])),
        ("yaml", Set(["yaml-json", "txt"])), ("yml", Set(["yaml-json", "txt"])), ("toml", Set(["toml-json", "txt"])),
        ("html", Set(["html-pdf", "html-txt", "txt"])), ("htm", Set(["html-pdf", "html-txt", "txt"])),
        ("srt", Set(["srt-vtt", "txt"])), ("vtt", Set(["vtt-srt", "txt"])),
        ("cfg", Set(["ini-json", "ini-xml", "txt"])), ("tsv", Set(["txt"])),
        ("swift", Set(["txt"])), ("txt", Set<String>()), ("text", Set<String>()),
    ]

    @Test(arguments: textTargets)
    func textOffersOnlySourceTargets(source: String, expected: Set<String>) {
        #expect(presets(.textConvert, ["a.\(source)"]) == expected)
    }

    @Test func documentAndPropertyListExportsAppearInTheCatalog() {
        for suffix in ["docx", "odt", "rtf", "rtfd"] {
            #expect(presets(.documentConvert, ["source.\(suffix)"]) == ["pdf", "txt"])
        }
        #expect(presets(.plistConvert, ["source.plist"]) == ["json"])
    }

    @Test func structuralTextRequiresOneCanonicalSourceFormat() {
        #expect(presets(.textConvert, ["a.csv", "b.json"]).isEmpty)
        #expect(presets(.textConvert, ["a.cfg", "b.conf"]) == ["ini-json", "ini-xml", "txt"])
        #expect(presets(.textEncoding, ["a.csv", "b.json"]) == ["utf-8", "utf-8-bom", "utf-16", "shift-jis"])
    }

    @Test func jsonCommandsRequireAllTextInputsToBeJSON() {
        #expect(presets(.textJSON, ["a.json", "b.JSON"]) == ["pretty", "minify", "sort"])
        #expect(presets(.textJSON, ["a.json", "b.csv"]).isEmpty)
        #expect(presets(.textJSON, ["a.xml"]).isEmpty)
        #expect(presets(.textJSON, ["a.json", "b.png"]) == ["pretty", "minify", "sort"])
    }

    @Test(arguments: [
        (OperationID.pdfEditPages, "pdf"), (.audioTrim, "wav"), (.pdfExtractPages, "pdf"),
    ])
    func singleOnlyOperationsUsePerKindCounts(op: OperationID, suffix: String) {
        let file = menuFile([op])
        let mixed = MenuLayout.tree(for: file, selection: selection(["a.\(suffix)", "unknown.bin"])).macEase
        #expect(leaves(mixed).contains { file.entries[$0].op == op })
        #expect(MenuLayout.tree(for: file, selection: selection(["a.\(suffix)", "b.\(suffix)"])).macEase.isEmpty)
    }

    @Test func chooseFrameOnlyNeedsOneVideoButPresetsAllowBatches() {
        #expect(presets(.videoThumbnail, ["a.mov", "photo.png"]).contains("choose-frame"))
        #expect(presets(.videoThumbnail, ["a.mov", "b.mp4"]) == ["first", "middle"])
        #expect(presets(.videoThumbnail, []).isEmpty)
    }

    @Test func analyzeSupportsMultipleFolders() {
        let folders = ["one", "two"].map { URL(fileURLWithPath: "/missing/\($0)", isDirectory: true) }
        let file = menuFile([.folderAnalyze])
        let nodes = MenuLayout.tree(for: file, selection: folders).macEase
        #expect(leaves(nodes).contains { file.entries[$0].op == .folderAnalyze })
        #expect(OperationID.folderAnalyze.maximumSelection == nil)
    }

    @Test func separatorsNormalizeAcrossHiddenAndPrunedGroups() {
        let file = MenuFile(
            token: "token", hostAvailable: true, visibleOperations: [.imageResize], titles: titles,
            hiddenEntries: [
                "image.resize/percent-75", "image.resize/percent-50", "image.resize/percent-25",
                "image.resize/long-3840", "image.resize/custom",
            ])
        let nodes = MenuLayout.tree(for: file, selection: selection(["a.png"])).macEase
        #expect(
            Set(leaves(nodes).compactMap { file.entries[$0].preset }) == [
                "long-360", "long-480", "long-720", "long-1080", "long-1920", "long-2560",
            ])
        checkSeparators(nodes)
        let entries = [
            MenuEntry(op: .imageConvert, preset: "jpeg", path: ["Convert", "JPEG"]),
            MenuEntry(op: .imageConvert, preset: "png", path: ["Convert", "PNG"], separatorBefore: true),
            MenuEntry(op: .imageConvert, preset: "webp", path: ["Convert", "WebP"]),
        ]
        let pruned = MenuFile(token: "token", hostAvailable: true, entries: entries, kinds: [:])
        let result = MenuLayout.tree(for: pruned, selection: selection(["a.png"])).macEase
        guard case .submenu(_, let children) = result.first else {
            Issue.record("Expected Convert submenu")
            return
        }
        #expect(children.count == 3)
        #expect(children[1] == .separator)
        checkSeparators(result)
    }

    @Test func allMenusMeetDepthAndSeparatorContracts() {
        let file = menuFile()
        for suffix in ["png", "mov", "wav", "pdf", "json", "csv", "swift", "zip", "jar"] {
            let nodes = MenuLayout.tree(for: file, selection: selection(["a.\(suffix)"])).macEase
            #expect(depth(nodes) + 1 <= 4)
            checkSeparators(nodes)
        }
        let mixed = MenuLayout.tree(for: file, selection: selection(["a.png", "b.mov", "c.json"])).macEase
        #expect(depth(mixed) + 1 <= 4)
        checkSeparators(mixed)
    }

    private func depth(_ nodes: [MenuNode]) -> Int {
        nodes.map { node in
            if case .submenu(_, let children) = node { return 1 + depth(children) }
            return node == .separator ? 0 : 1
        }.max() ?? 0
    }

    private func checkSeparators(_ nodes: [MenuNode]) {
        #expect(nodes.first != .separator)
        #expect(nodes.last != .separator)
        #expect(!zip(nodes, nodes.dropFirst()).contains { $0 == .separator && $1 == .separator })
        for node in nodes {
            if case .submenu(_, let children) = node { checkSeparators(children) }
        }
    }
}

@Suite struct RunRequestTests {
    @Test func roundTripsAwkwardPaths() throws {
        let paths = ["/tmp/a & b #1 100%.png", "/Users/me/写真/テスト+1=2?.heic", "/tmp/semi;colon,comma.txt"]
        let request = RunRequest(catalogVersion: "abc", entryIndex: 42, token: "tok", paths: paths)
        let url = try #require(request.url(scheme: "macease"))
        #expect(try RunRequest(url: url, scheme: "macease") == request)
    }

    @Test func carriesFiveThousandPaths() throws {
        let paths = (0..<5000).map { "/Users/me/Pictures/フォルダ & more/image #\($0) 50%.jpg" }
        let request = RunRequest(catalogVersion: "v", entryIndex: 1, token: "t", paths: paths)
        let url = try #require(request.url(scheme: "macease"))
        #expect(try RunRequest(url: url, scheme: "macease").paths == paths)
    }

    @Test func rejectsMalformedRequests() throws {
        let wrongScheme = try #require(URL(string: "other://run?v=a&e=1&t=b&path=/x"))
        #expect(throws: RunRequestError.notARunRequest) { try RunRequest(url: wrongScheme, scheme: "macease") }
        let noToken = try #require(URL(string: "macease://run?v=a&e=1&path=/x"))
        #expect(throws: RunRequestError.missingField("t")) { try RunRequest(url: noToken, scheme: "macease") }
        let relative = try #require(URL(string: "macease://run?v=a&e=1&t=b&path=x"))
        #expect(throws: RunRequestError.invalidPaths) { try RunRequest(url: relative, scheme: "macease") }
    }
}

@Suite struct RequestTokenTests {
    @Test func generatesDistinctWellFormedTokens() throws {
        let first = try RequestToken.generate()
        let second = try RequestToken.generate()
        #expect(RequestToken.isWellFormed(first))
        #expect(first != second)
        #expect(!RequestToken.isWellFormed("abc"))
        #expect(!RequestToken.isWellFormed(String(repeating: "g", count: 64)))
    }

    @Test func matchesOnlyIdenticalTokens() {
        let token = String(repeating: "a", count: 64)
        let other = String(repeating: "a", count: 63) + "b"
        #expect(RequestToken.matches(token, token))
        #expect(!RequestToken.matches(other, token))
        #expect(!RequestToken.matches("", token))
    }
}

@Suite struct MenuFileIntegrityTests {
    private func tampered(_ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var encoded = try #require(JSONSerialization.jsonObject(with: menuFile().encoded()) as? [String: Any])
        try change(&encoded)
        return try JSONSerialization.data(withJSONObject: encoded)
    }

    @Test func untouchedFilesLoad() throws {
        #expect(try MenuFile(json: try tampered { _ in }) == menuFile())
    }

    @Test func reorderedEntriesUnderTheOldVersionAreRejected() throws {
        let json = try tampered { encoded in
            var entries = try #require(encoded["entries"] as? [Any])
            entries.swapAt(0, 1)
            encoded["entries"] = entries
        }
        #expect(throws: MenuFileError.catalogMismatch) { try MenuFile(json: json) }
    }

    @Test func editedTitlesAndCommandsUnderTheOldVersionAreRejected() throws {
        let retitled = try tampered { $0["moreTitle"] = "Other" }
        #expect(throws: MenuFileError.catalogMismatch) { try MenuFile(json: retitled) }
        let commandless = try tampered { $0["commands"] = [] }
        #expect(throws: MenuFileError.catalogMismatch) { try MenuFile(json: commandless) }
    }
}

@Suite struct MenuBuildsTests {
    private let shown = menuFile()
    private let rewritten: MenuFile = {
        var arrangement = MenuArrangement()
        var image = arrangement.resolved(.image)
        image.move([MenuGroupID(rawValue: "image.convert")], to: .more)
        arrangement.set(image)
        return MenuFile(
            token: "rotated", hostAvailable: true, visibleOperations: OperationID.allCases, titles: titles,
            arrangement: arrangement)
    }()

    @Test func clicksSendTheVersionTheirMenuWasBuiltFrom() {
        #expect(shown.catalogVersion != rewritten.catalogVersion)
        var builds = MenuBuilds()
        let open = MenuBuilds.tag(build: builds.record(shown), entryIndex: 3)
        let later = MenuBuilds.tag(build: builds.record(rewritten), entryIndex: 3)
        #expect(
            builds.request(tag: open, paths: ["/a.png"])
                == RunRequest(
                    catalogVersion: shown.catalogVersion, entryIndex: 3, token: shown.token, paths: ["/a.png"]))
        #expect(
            builds.request(tag: later, paths: ["/a.png"])
                == RunRequest(
                    catalogVersion: rewritten.catalogVersion, entryIndex: 3, token: "rotated", paths: ["/a.png"]))
    }

    @Test func replacedBuildsAndForeignTagsYieldNoRequest() {
        var builds = MenuBuilds()
        let oldest = MenuBuilds.tag(build: builds.record(shown), entryIndex: 0)
        for _ in 0..<MenuBuilds.retainedCount {
            #expect(builds.request(tag: oldest, paths: ["/a"]) != nil)
            _ = builds.record(rewritten)
        }
        #expect(builds.request(tag: oldest, paths: ["/a"]) == nil)
        #expect(builds.request(tag: -1, paths: ["/a"]) == nil)
        for _ in 0..<MenuBuilds.idCount {
            let tag = MenuBuilds.tag(build: builds.record(shown), entryIndex: 7)
            #expect(builds.request(tag: tag, paths: ["/a"])?.catalogVersion == shown.catalogVersion)
        }
    }

    @Test func tagsKeepLargeIndicesWithin31Bits() {
        var builds = MenuBuilds()
        let entryIndex = 1_000_000
        let tag = MenuBuilds.tag(build: MenuBuilds.idCount - 1, entryIndex: entryIndex)
        #expect(tag <= Int(Int32.max))
        for _ in 0..<MenuBuilds.idCount { _ = builds.record(shown) }
        #expect(builds.request(tag: tag, paths: ["/a"])?.entryIndex == entryIndex)
    }
}
