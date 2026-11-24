import Foundation
import Testing

@testable import MenuCatalog

@Suite struct FinderCommandMenuTests {
    private let titles = MenuTitles(operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue })
    private let commands: [HostCommand: String] = [
        .newFile: "New File", .cut: "Cut", .moveHere: "Move 3 Items Here", .copyPath: "Copy Path",
        .openTerminal: "Open Terminal Here",
    ]
    private let leaves: [HostCommand: [MenuCommandLeaf]] = [
        .newFile: ["txt", "md", "rtf", "docx"].map { MenuCommandLeaf(preset: $0, title: $0) },
        .copyPath: [
            MenuCommandLeaf(preset: "posix", title: "Copy Path"),
            MenuCommandLeaf(preset: "shellQuoted", title: "Copy Path for Terminal"),
        ],
    ]

    private func file(_ arrangement: MenuArrangement = MenuArrangement()) -> MenuFile {
        MenuFile(
            token: "token", hostAvailable: true, visibleOperations: [], titles: titles,
            arrangement: arrangement, commandTitles: commands, commandLeaves: leaves)
    }

    private func actions(_ nodes: [MenuNode]) -> [MenuCommandAction] {
        nodes.flatMap { node -> [MenuCommandAction] in
            switch node {
            case .command(let command, _, let preset): [MenuCommandAction(command: command, preset: preset)]
            case .submenu(_, let children): actions(children)
            case .action, .separator: []
            }
        }
    }

    @Test func folderBackgroundAndSingleFolderOfferCreationAndDestination() {
        let folder = URL(fileURLWithPath: "/work/", isDirectory: true)
        for container in [false, true] {
            let tree = MenuLayout.tree(for: file(), selection: [folder], isContainer: container)
            #expect(tree.finder.isEmpty)
            let shown = actions(tree.macEase)
            #expect(shown.filter { $0.command == .newFile }.map(\.preset) == ["txt", "md", "rtf", "docx"])
            #expect(shown.contains(MenuCommandAction(command: .moveHere)))
            #expect(shown.contains(MenuCommandAction(command: .cut)) == !container)
            #expect(shown.filter { $0.command == .copyPath }.count == 2)
        }
    }

    @Test func filePackageAndMixedSelectionNeverOfferFolderCommands() {
        let selections: [[URL]] = [
            [URL(fileURLWithPath: "/work/a.txt")],
            [URL(fileURLWithPath: "/work/App.app/", isDirectory: true)],
            [URL(fileURLWithPath: "/work/a.txt"), URL(fileURLWithPath: "/work/folder/", isDirectory: true)],
            [URL(fileURLWithPath: "/work/a/", isDirectory: true), URL(fileURLWithPath: "/work/b/", isDirectory: true)],
        ]
        for selection in selections {
            let shown = actions(MenuLayout.tree(for: file(), selection: selection).macEase)
            #expect(!shown.contains { $0.command == .newFile || $0.command == .moveHere })
            #expect(shown.contains(MenuCommandAction(command: .cut)))
            #expect(shown.contains(MenuCommandAction(command: .openTerminal)) == (selection.count == 1))
        }
        #expect(actions(MenuLayout.tree(for: file(), selection: []).macEase).isEmpty)
    }

    @Test func everyCommandCanMoveAndHideAsOneGroup() throws {
        for command in commands.keys {
            var arrangement = MenuArrangement()
            var scope = arrangement.resolved(.commands)
            let group = MenuGroupID(command)
            #expect(scope.section(of: group) == .menu)
            scope.move([group], to: .finder)
            arrangement.set(scope)
            let shown = actions(
                MenuLayout.tree(for: file(arrangement), selection: [URL(fileURLWithPath: "/work/", isDirectory: true)])
                    .finder)
            #expect(shown.contains { $0.command == command })
            scope.hide([group])
            arrangement.set(scope)
            let roundTrip = try JSONDecoder().decode(MenuArrangement.self, from: JSONEncoder().encode(arrangement))
            #expect(!file(roundTrip).commands.contains { $0.command == command })
        }
    }

    @Test func commandLeavesRoundTripAndBindVersionAndTags() throws {
        let original = file()
        #expect(try MenuFile(json: original.encoded()) == original)
        var builds = MenuBuilds(firstTag: 100)
        _ = builds.record(MenuFile(token: "token", hostAvailable: true, entries: [], kinds: [:]))
        let recorded = builds.record(original)
        let first = try #require(recorded)
        let action = MenuCommandAction(command: .newFile, preset: "docx")
        let tag = try #require(builds.commandTag(action, firstTag: first))
        let paths = ["/work/日本語 & # %/"]
        let request = try #require(builds.commandRequest(tag: tag, paths: paths))
        #expect(request.action == action)
        #expect(request.catalogVersion == original.catalogVersion)
        let url = try #require(request.url(scheme: "macease-test"))
        #expect(HostCommandRequest(url: url, scheme: "macease-test") == request)
        #expect(builds.request(tag: tag, paths: paths) == nil)
        for _ in 0..<MenuBuilds.retainedCount { _ = builds.record(original) }
        #expect(builds.commandRequest(tag: tag, paths: paths) == nil)
        for changesPreset in [false, true] {
            let changedRows = original.commands.map { row in
                MenuCommandItem(
                    group: row.group, title: row.title, placement: row.placement,
                    leaves: row.leaves?.map { leaf in
                        MenuCommandLeaf(
                            preset: changesPreset ? leaf.preset + "-changed" : leaf.preset,
                            title: changesPreset ? leaf.title : leaf.title + " changed")
                    })
            }
            let changed = MenuFile(
                token: original.token, hostAvailable: true, entries: original.entries,
                kinds: [:], commands: changedRows)
            #expect(changed.catalogVersion != original.catalogVersion)
        }
    }

    @Test func malformedCommandSelectionAndDuplicateFieldsAreRejected() throws {
        for query in [
            "t=a&t=a&v=v&path=/a", "t=a&v=v&v=v&path=/a", "t=a&v=v&path=relative",
            "t=a&v=v&path", "t=a&v=v&path=%00/a", "t=a&v=v&path=/a&preset=txt&preset=md",
        ] {
            let url = try #require(URL(string: "macease-test://newfile?\(query)"))
            #expect(HostCommandRequest(url: url, scheme: "macease-test") == nil)
        }
    }
}
