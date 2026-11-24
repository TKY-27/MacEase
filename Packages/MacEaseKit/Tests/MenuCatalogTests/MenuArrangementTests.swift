import Foundation
import Testing

@testable import MenuCatalog

private func ids(_ names: String...) -> [MenuGroupID] {
    names.map(MenuGroupID.init(rawValue:))
}

private func id(_ name: String) -> MenuGroupID {
    MenuGroupID(rawValue: name)
}

@Suite struct MenuGroupCatalogTests {
    private let catalog = MenuGroupCatalog.current

    @Test(arguments: [
        (
            MenuScope.image,
            ids(
                "image.edit", "image.convert", "image.compress", "image.resize", "image.rotate", "image.background",
                "image.ocr")
        ),
        (
            .video,
            ids(
                "video.edit", "video.convert", "video.compress", "video.resize", "video.extractAudio",
                "video.thumbnail", "video.subtitles")
        ),
        (
            .audio,
            ids(
                "audio.trim", "audio.enhance", "audio.convert", "audio.compress", "audio.normalize", "audio.subtitles")
        ),
        (
            .pdf,
            ids(
                "pdf.editPages", "pdf.merge", "pdf.toImages", "pdf.toText", "pdf.compress", "pdf.rotate",
                "pdf.extractPages", "pdf.split")
        ),
        (.text, ids("text.convert", "text.json/pretty", "text.json/minify", "text.json/sort")),
        (.document, ids("document.convert")), (.plist, ids("plist.convert")),
        (
            .folder,
            ids(
                "folder.compress", "folder.rename", "folder.organize", "folder.analyze", "folder.removeDuplicates",
                "folder.removeEmpty")
        ),
        (.archive, ids("archive.hatchExtract", "archive.extract", "archive.browse")), (.jar, []), (.any, []),
        (.commands, ids("command.update", "command.preview")),
    ])
    func defaultsReproduceTheFixedPrimaryTable(scope: MenuScope, menu: [MenuGroupID]) {
        let defaults = catalog.defaultArrangement(scope)
        #expect(defaults[.menu] == menu)
        #expect(defaults[.hidden].isEmpty)
        #expect(
            defaults[.more]
                == catalog.groups(in: scope).filter { !menu.contains($0) && !defaults[.finder].contains($0) })
        #expect(Set(defaults.groups) == Set(catalog.groups(in: scope)))
        #expect(catalog.isCanonical(defaults[.menu], in: .menu, of: scope))
        #expect(catalog.isCanonical(defaults[.more], in: .more, of: scope))
    }

    @Test func everyOperationGroupBelongsToExactlyOneScope() {
        let all = MenuScope.allCases.flatMap(catalog.groups(in:))
        #expect(Set(all).count == all.count)
        let expected = Set(
            OperationID.menuOrder.flatMap { op in
                (op == .textJSON ? op.presets.map(Optional.some) : [nil]).map { id(op.menuGroupID(preset: $0)) }
            }
        ).union(HostCommand.allCases.map(MenuGroupID.init))
        #expect(Set(all) == expected)
        #expect(catalog.defaultArrangement(.commands)[.finder] == ids("folder.downloadMedia"))
        #expect(!catalog.groups(in: .folder).contains(id("folder.downloadMedia")))
        #expect(catalog.groups(in: .image).first == id("image.edit"))
        #expect(catalog.groups(in: .image).filter { $0 == id("image.convert") }.count == 1)
    }

    @Test func entryKeysCoverEveryLeafOfTheGroup() {
        #expect(
            id("image.rotate").entryKeys == [
                "image.rotate/right-90", "image.rotate/left-90", "image.rotate/180", "image.rotate/extra-angle",
                "image.flip/horizontal", "image.flip/vertical",
            ])
        #expect(id("text.json/minify").entryKeys == ["text.json/minify"])
        #expect(id("pdf.merge").entryKeys == ["pdf.merge/"])
        #expect(id("image.convert").entryKeys.last == "image.hdrToSDR/")
        #expect(id("command.update").entryKeys.isEmpty)
        let all = MenuScope.allCases.flatMap(catalog.groups(in:)).flatMap(\.entryKeys)
        #expect(all.sorted() == OperationID.allCases.flatMap(\.menuEntryKeys).sorted())
    }

    @Test func commandGroupsRoundTrip() {
        for command in HostCommand.allCases {
            #expect(HostCommand(group: MenuGroupID(command)) == command)
        }
        #expect(HostCommand(group: id("folder.downloadMedia")) == nil)
        #expect(HostCommand(group: id("command.unknown")) == nil)
    }
}

@Suite struct MenuArrangementResolutionTests {
    private let previous = MenuGroupCatalog(
        groups: [.image: ids("image.a", "image.b", "image.c", "image.old")],
        finder: [:], menu: [.image: ids("image.a", "image.b")],
        renames: [:])
    private let next = MenuGroupCatalog(
        groups: [.image: ids("image.new", "image.a", "image.b", "image.c", "image.renamed")],
        finder: [:], menu: [.image: ids("image.new", "image.a", "image.b")],
        renames: [id("image.old"): id("image.renamed")])

    @Test func uncustomizedScopesFollowTheDefaults() {
        let arrangement = MenuArrangement()
        #expect(!arrangement.isCustomized(.image))
        #expect(arrangement.resolved(.image, catalog: next) == next.defaultArrangement(.image))
        #expect(arrangement.resolved(.image, catalog: next)[.menu] == ids("image.new", "image.a", "image.b"))
    }

    @Test func customizedScopesAppendNewGroupsToMoreAndApplyRenames() {
        var scope = previous.defaultArrangement(.image)
        scope.move(ids("image.c"), to: .menu, at: 0)
        scope.hide(ids("image.b"))
        var arrangement = MenuArrangement()
        arrangement.set(scope, catalog: previous)
        #expect(arrangement.isCustomized(.image))
        let resolved = arrangement.resolved(.image, catalog: next)
        #expect(resolved[.menu] == ids("image.c", "image.a"))
        #expect(resolved[.more] == ids("image.renamed", "image.new"))
        #expect(resolved[.hidden] == ids("image.b"))
    }

    @Test func removedGroupsAreDroppedAndRenameCollisionsKeepTheFirst() {
        let removing = MenuGroupCatalog(
            groups: [.image: ids("image.a", "image.c", "image.renamed")], finder: [:], menu: [.image: ids("image.a")],
            renames: [id("image.old"): id("image.renamed"), id("image.b"): id("image.renamed")])
        var scope = previous.defaultArrangement(.image)
        scope.hide(ids("image.old"))
        var arrangement = MenuArrangement()
        arrangement.set(scope, catalog: previous)
        let resolved = arrangement.resolved(.image, catalog: removing)
        #expect(resolved[.menu] == ids("image.a", "image.renamed"))
        #expect(resolved[.more] == ids("image.c"))
        #expect(resolved[.hidden].isEmpty)
    }

    @Test func settingTheDefaultsOrRestoringClearsCustomization() {
        var arrangement = MenuArrangement()
        var scope = previous.defaultArrangement(.image)
        scope.hide(ids("image.a"))
        arrangement.set(scope, catalog: previous)
        #expect(arrangement.isCustomized(.image))
        scope.show(ids("image.a"), catalog: previous)
        #expect(scope[.menu] == ids("image.b", "image.a"))
        arrangement.set(scope, catalog: previous)
        #expect(arrangement.isCustomized(.image))
        scope.moveUp(id("image.a"))
        arrangement.set(scope, catalog: previous)
        #expect(!arrangement.isCustomized(.image))
        arrangement.set(scope.hiding("image.c"), catalog: previous)
        arrangement.restoreDefaults(.image)
        #expect(arrangement == MenuArrangement())
    }

    @Test func storedArrangementsRoundTripThroughJSON() throws {
        var arrangement = MenuArrangement()
        var commands = MenuGroupCatalog.current.defaultArrangement(.commands)
        commands.move(ids("folder.downloadMedia"), to: .more)
        arrangement.set(commands)
        arrangement.set(MenuGroupCatalog.current.defaultArrangement(.text).hiding("text.json/sort"))
        let data = try JSONEncoder().encode(arrangement)
        #expect(try JSONDecoder().decode(MenuArrangement.self, from: data) == arrangement)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == MenuArrangement.currentVersion)
        let scopes = try #require(object["scopes"] as? [String: [String: [String]]])
        #expect(scopes["commands"]?["more"] == ["folder.downloadMedia"])
        #expect(scopes["text"]?["hidden"] == ["text.json/sort"])
        #expect(Set(scopes.keys) == ["commands", "text"])
    }

    @Test(arguments: [
        #"{"version":2,"scopes":{}}"#,
        #"{"version":1,"scopes":{"image":{"menu":["image.edit"],"hidden":["image.edit"]}}}"#,
        #"{"version":1,"scopes":{"image":{"menu":["image.edit","image.edit"]}}}"#,
        #"{"version":1,"scopes":{"image":{"finder":["image.edit"]}}}"#,
        #"{"version":1,"scopes":{"image":{"top":["image.edit"]}}}"#,
        #"{"version":1,"scopes":{"spreadsheet":{"menu":[]}}}"#,
        #"{"scopes":{}}"#,
    ])
    func invalidStoredArrangementsFailToDecode(json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MenuArrangement.self, from: Data(json.utf8)) }
    }

    @Test func unknownStoredGroupsDecodeAndResolveAway() throws {
        let json = #"{"version":1,"scopes":{"image":{"menu":["image.gone","image.ocr"],"more":[],"hidden":[]}}}"#
        let decoded = try JSONDecoder().decode(MenuArrangement.self, from: Data(json.utf8))
        let resolved = decoded.resolved(.image)
        #expect(resolved[.menu] == ids("image.ocr"))
        #expect(Set(resolved.groups) == Set(MenuGroupCatalog.current.groups(in: .image)))
    }
}

@Suite struct ScopeArrangementEditingTests {
    private let catalog = MenuGroupCatalog(
        groups: [.image: ids("a", "b", "c", "d"), .commands: ids("x", "y", "z")],
        finder: [.commands: ids("x")], menu: [.image: ids("a", "b"), .commands: ids("y")], renames: [:])

    @Test func rowsListHeadersAndPlaceholders() {
        let scope = catalog.defaultArrangement(.image)
        #expect(
            scope.rows == [
                .header(.menu), .group(id("a")), .group(id("b")), .header(.more), .group(id("c")), .group(id("d")),
                .header(.hidden), .placeholder(.hidden),
            ])
        #expect(catalog.defaultArrangement(.commands).rows.first == .header(.finder))
    }

    @Test func dropsAboveTheFirstHeaderLandFirstInTheFirstSection() {
        var scope = catalog.defaultArrangement(.image)
        scope.move(fromOffsets: [4], toOffset: 0)
        #expect(scope[.menu] == ids("c", "a", "b"))
        #expect(scope[.more] == ids("d"))
    }

    @Test func dropsOnPlaceholdersAndAfterHeadersEnterThatSection() {
        var scope = catalog.defaultArrangement(.image)
        scope.move(fromOffsets: [1], toOffset: 7)
        #expect(scope[.hidden] == ids("a"))
        scope = catalog.defaultArrangement(.image)
        scope.move(fromOffsets: [2], toOffset: 8)
        #expect(scope[.hidden] == ids("b"))
        scope = catalog.defaultArrangement(.image)
        scope.move(fromOffsets: [5], toOffset: 4)
        #expect(scope[.more] == ids("d", "c"))
        scope.move(fromOffsets: [1], toOffset: 4)
        #expect(scope[.menu] == ids("b"))
        #expect(scope[.more] == ids("a", "d", "c"))
    }

    @Test func multiRowMovesKeepRelativeOrderAndIgnoreHeaders() {
        var scope = catalog.defaultArrangement(.image)
        scope.move(fromOffsets: [0, 5, 1, 3], toOffset: 8)
        #expect(scope[.hidden] == ids("a", "d"))
        #expect(scope[.menu] == ids("b"))
        #expect(scope[.more] == ids("c"))
        let expected = scope.moved(fromOffsets: [0, 3], toOffset: 1)
        scope.move(fromOffsets: [0, 3], toOffset: 1)
        #expect(scope == expected)
        #expect(scope[.menu] == ids("c", "b"))
    }

    @Test func moveUpAndDownCrossSectionBoundaries() {
        var scope = catalog.defaultArrangement(.image)
        scope.moveUp(id("a"))
        #expect(scope[.menu] == ids("a", "b"))
        scope.moveUp(id("c"))
        #expect(scope[.menu] == ids("a", "b", "c"))
        scope.moveDown(id("c"))
        #expect(scope[.more] == ids("c", "d"))
        scope.moveDown(id("d"))
        #expect(scope[.hidden] == ids("d"))
        scope.moveDown(id("d"))
        #expect(scope[.hidden] == ids("d"))
        scope.moveUp(id("d"))
        #expect(scope[.more] == ids("c", "d"))
    }

    @Test func selectedGroupsStepTogetherAndStopAtTheEnds() {
        var scope = catalog.defaultArrangement(.image)
        scope.moveUp(ids("c", "a"))
        #expect(scope[.menu] == ids("a", "b", "c"))
        #expect(scope[.more] == ids("d"))
        scope.moveUp(ids("a", "c"))
        #expect(scope[.menu] == ids("a", "c", "b"))
        scope.moveDown(ids("b", "d"))
        #expect(scope[.more] == ids("b"))
        #expect(scope[.hidden] == ids("d"))
        scope.moveDown(ids("b", "d"))
        #expect(scope[.more].isEmpty)
        #expect(scope[.hidden] == ids("b", "d"))
        scope.moveDown(ids("b", "d"))
        #expect(scope[.hidden] == ids("b", "d"))
        scope.moveUp(ids("b", "d"))
        #expect(scope[.more] == ids("b", "d"))
        #expect(scope[.hidden].isEmpty)
    }

    @Test func moveToSectionAndShowUseExplicitPositions() {
        var scope = catalog.defaultArrangement(.commands)
        scope.move(ids("z", "x"), to: .menu, at: 0)
        #expect(scope[.menu] == ids("x", "z", "y"))
        #expect(scope[.finder].isEmpty)
        scope.hide(ids("y", "x"))
        #expect(scope[.hidden] == ids("x", "y"))
        scope.show(ids("x", "y"), catalog: catalog)
        #expect(scope[.finder] == ids("x"))
        #expect(scope[.menu] == ids("z", "y"))
        scope.move(ids("y"), to: .menu, at: 0)
        #expect(scope[.menu] == ids("y", "z"))
    }

    @Test func randomEditSequencesMatchAFlatListModel() {
        var random = SeededRandom(seed: 0x5EED)
        var checked = 0
        for scope in [MenuScope.image, .commands] {
            for _ in 0..<200 {
                var arrangement = catalog.defaultArrangement(scope)
                let groups = Set(arrangement.groups)
                for _ in 0..<12 {
                    let rows = arrangement.rows
                    let offsets = IndexSet((0..<rows.count).filter { _ in random.next() % 3 == 0 })
                    let destination = Int(random.next() % UInt64(rows.count + 1))
                    let expected = arrangement.moved(fromOffsets: offsets, toOffset: destination)
                    switch random.next() % 4 {
                    case 0:
                        let group = arrangement.groups[Int(random.next() % UInt64(groups.count))]
                        arrangement.moveUp(group)
                    case 1:
                        let group = arrangement.groups[Int(random.next() % UInt64(groups.count))]
                        arrangement.moveDown(group)
                    default:
                        arrangement.move(fromOffsets: offsets, toOffset: destination)
                        #expect(arrangement == expected)
                    }
                    let placed = arrangement.groups
                    #expect(placed.count == groups.count)
                    #expect(Set(placed) == groups)
                    #expect(placed.allSatisfy { arrangement.section(of: $0) != nil })
                    checked += 1
                }
            }
        }
        #expect(checked == 4800)
    }
}

extension ScopeArrangement {
    fileprivate func hiding(_ name: String) -> ScopeArrangement {
        var copy = self
        copy.hide([MenuGroupID(rawValue: name)])
        return copy
    }

    /// Splices flat rows, then reassigns sections.
    fileprivate func moved(fromOffsets offsets: IndexSet, toOffset destination: Int) -> ScopeArrangement {
        let rows = rows
        let moving = offsets.filter { if case .group = rows[$0] { true } else { false } }
        let before = rows[..<destination].indices.filter { !moving.contains($0) }.map { rows[$0] }
        let after = rows[destination...].indices.filter { !moving.contains($0) }.map { rows[$0] }
        var section = scope.sections[0]
        var groups: [MenuSection: [MenuGroupID]] = [:]
        for row in before + moving.map({ rows[$0] }) + after {
            switch row {
            case .header(let next): section = next
            case .group(let group): groups[section, default: []].append(group)
            case .placeholder: break
            }
        }
        return ScopeArrangement(scope: scope, groups: groups)
    }
}

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
