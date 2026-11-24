/// One app version's groups and defaults.
public struct MenuGroupCatalog: Sendable {
    private let groupsByScope: [MenuScope: [MenuGroupID]]
    private let defaultsByScope: [MenuScope: ScopeArrangement]
    private let renames: [MenuGroupID: MenuGroupID]

    init(
        groups: [MenuScope: [MenuGroupID]], finder: [MenuScope: [MenuGroupID]], menu: [MenuScope: [MenuGroupID]],
        renames: [MenuGroupID: MenuGroupID]
    ) {
        groupsByScope = groups
        self.renames = renames
        defaultsByScope = Dictionary(
            uniqueKeysWithValues: MenuScope.allCases.map { scope in
                let finder = finder[scope] ?? []
                let menu = menu[scope] ?? []
                let more = (groups[scope] ?? []).filter { !finder.contains($0) && !menu.contains($0) }
                return (scope, ScopeArrangement(scope: scope, groups: [.finder: finder, .menu: menu, .more: more]))
            })
    }

    public static let current: MenuGroupCatalog = {
        var groups: [MenuScope: [MenuGroupID]] = [.commands: HostCommand.allCases.map(MenuGroupID.init)]
        for op in OperationID.menuOrder {
            let scope = commandOperations.contains(op) ? MenuScope.commands : MenuScope(op.kind)
            for group in op.menuGroups where groups[scope]?.contains(group) != true {
                groups[scope, default: []].append(group)
            }
        }
        var menu: [MenuScope: [MenuGroupID]] = [.commands: HostCommand.allCases.map(MenuGroupID.init)]
        for op in OperationID.primaryMenuOrder {
            menu[MenuScope(op.kind), default: []] += op.menuGroups
        }
        return MenuGroupCatalog(
            groups: groups, finder: [.commands: commandOperations.flatMap(\.menuGroups)], menu: menu,
            renames: [:])
    }()

    private static let commandOperations: [OperationID] = [.folderDownloadMedia]

    public func groups(in scope: MenuScope) -> [MenuGroupID] {
        groupsByScope[scope] ?? []
    }

    public func defaultArrangement(_ scope: MenuScope) -> ScopeArrangement {
        defaultsByScope[scope] ?? ScopeArrangement(scope: scope, groups: [:])
    }

    func renamed(_ group: MenuGroupID) -> MenuGroupID {
        renames[group] ?? group
    }

    /// The order legacy placements produced.
    func isCanonical(_ groups: [MenuGroupID], in section: MenuSection, of scope: MenuScope) -> Bool {
        let catalog = self.groups(in: scope)
        let ranked = section == .menu ? defaultArrangement(scope)[.menu] : []
        let keys = groups.map { group in
            (ranked.firstIndex(of: group) ?? ranked.count, catalog.firstIndex(of: group) ?? catalog.count)
        }
        return zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }
    }
}

extension MenuGroupID {
    private static let keysByGroup: [String: [String]] = OperationID.menuOrder.reduce(into: [:]) { keys, op in
        for preset in op.menuPresetIDs.isEmpty ? [""] : op.menuPresetIDs {
            keys[op.menuGroupID(preset: preset.isEmpty ? nil : preset), default: []].append(op.menuEntryKey(preset))
        }
    }

    /// `op/preset` keys of the group's leaves.
    public var entryKeys: [String] {
        Self.keysByGroup[rawValue] ?? []
    }
}

extension OperationID {
    fileprivate var menuGroups: [MenuGroupID] {
        let presets: [String?] = self == .textJSON ? presets : [nil]
        return presets.map { MenuGroupID(rawValue: menuGroupID(preset: $0)) }
    }
}
