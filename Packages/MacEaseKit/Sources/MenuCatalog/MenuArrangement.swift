import Foundation

public struct MenuGroupID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ command: HostCommand) {
        rawValue = "\(HostCommand.groupPrefix)\(command.rawValue)"
    }
}

/// Raw values are the host URL routes.
public enum HostCommand: String, CaseIterable, Codable, Sendable {
    case update, preview

    fileprivate static let groupPrefix = "command."

    public init?(group: MenuGroupID) {
        guard group.rawValue.hasPrefix(Self.groupPrefix) else { return nil }
        self.init(rawValue: String(group.rawValue.dropFirst(Self.groupPrefix.count)))
    }
}

public enum MenuScope: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case commands
    case image, video, audio, pdf, document, plist, text, folder, archive, jar, any

    public init(_ kind: FileKind) {
        switch kind {
        case .image: self = .image
        case .video: self = .video
        case .audio: self = .audio
        case .pdf: self = .pdf
        case .document: self = .document
        case .plist: self = .plist
        case .text: self = .text
        case .folder: self = .folder
        case .archive: self = .archive
        case .jar: self = .jar
        case .any: self = .any
        }
    }

    public var sections: [MenuSection] {
        self == .commands ? [.finder, .menu, .more, .hidden] : [.menu, .more, .hidden]
    }
}

public enum MenuSection: String, Codable, CodingKeyRepresentable, Sendable {
    case finder, menu, more, hidden

    public var placement: MenuPlacement? {
        switch self {
        case .finder: .finder
        case .menu: .primary
        case .more: .more
        case .hidden: nil
        }
    }
}

public enum ArrangementRow: Hashable, Sendable {
    case header(MenuSection)
    case group(MenuGroupID)
    case placeholder(MenuSection)
}

/// Each group sits in exactly one section.
public struct ScopeArrangement: Equatable, Sendable {
    public let scope: MenuScope
    private var groupsBySection: [MenuSection: [MenuGroupID]]

    init(scope: MenuScope, groups: [MenuSection: [MenuGroupID]]) {
        self.scope = scope
        groupsBySection = Dictionary(uniqueKeysWithValues: scope.sections.map { ($0, groups[$0] ?? []) })
    }

    public subscript(section: MenuSection) -> [MenuGroupID] {
        groupsBySection[section] ?? []
    }

    public var groups: [MenuGroupID] {
        scope.sections.flatMap { self[$0] }
    }

    public func section(of group: MenuGroupID) -> MenuSection? {
        scope.sections.first { self[$0].contains(group) }
    }

    public var rows: [ArrangementRow] {
        scope.sections.flatMap { section -> [ArrangementRow] in
            let groups = self[section]
            return [.header(section)] + (groups.isEmpty ? [.placeholder(section)] : groups.map(ArrangementRow.group))
        }
    }

    /// Mirrors SwiftUI `onMove`; headers stay put.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let rows = rows
        precondition(offsets.allSatisfy(rows.indices.contains) && (0...rows.count).contains(destination))
        let moving = offsets.compactMap { offset -> MenuGroupID? in
            if case .group(let group) = rows[offset] { group } else { nil }
        }
        guard !moving.isEmpty else { return }
        var target = scope.sections[0]
        var index = 0
        for row in rows[..<destination] {
            switch row {
            case .header(let section):
                target = section
                index = 0
            case .group(let group) where !moving.contains(group): index += 1
            case .group, .placeholder: break
            }
        }
        insert(moving, into: target, at: index)
    }

    /// `index` counts the section's remaining groups.
    public mutating func move(_ groups: [MenuGroupID], to section: MenuSection, at index: Int? = nil) {
        precondition(scope.sections.contains(section) && groups.allSatisfy { self.section(of: $0) != nil })
        let moving = self.groups.filter(groups.contains)
        let remaining = self[section].filter { !moving.contains($0) }
        let position = index ?? remaining.count
        precondition((0...remaining.count).contains(position))
        insert(moving, into: section, at: position)
    }

    /// May cross into the previous section.
    public mutating func moveUp(_ group: MenuGroupID) {
        guard let row = rows.firstIndex(of: .group(group)) else { preconditionFailure("Unknown group") }
        move(fromOffsets: [row], toOffset: row - 1)
    }

    /// May cross into the next section.
    public mutating func moveDown(_ group: MenuGroupID) {
        let rows = rows
        guard let row = rows.firstIndex(of: .group(group)) else { preconditionFailure("Unknown group") }
        move(fromOffsets: [row], toOffset: min(row + 2, rows.count))
    }

    /// Blocked groups block the group below.
    public mutating func moveUp(_ groups: [MenuGroupID]) {
        var blocked: Set<MenuGroupID> = []
        for group in self.groups.filter(groups.contains) {
            let rows = rows
            guard let row = rows.firstIndex(of: .group(group)) else { preconditionFailure("Unknown group") }
            if row == 1 || blocked.contains(where: { rows[row - 1] == .group($0) }) {
                blocked.insert(group)
            } else {
                moveUp(group)
            }
        }
    }

    /// Blocked groups block the group above.
    public mutating func moveDown(_ groups: [MenuGroupID]) {
        var blocked: Set<MenuGroupID> = []
        for group in self.groups.filter(groups.contains).reversed() {
            let rows = rows
            guard let row = rows.firstIndex(of: .group(group)) else { preconditionFailure("Unknown group") }
            if row == rows.count - 1 || blocked.contains(where: { rows[row + 1] == .group($0) }) {
                blocked.insert(group)
            } else {
                moveDown(group)
            }
        }
    }

    public mutating func hide(_ groups: [MenuGroupID]) {
        move(groups, to: .hidden)
    }

    /// Returns groups to their default section.
    public mutating func show(_ groups: [MenuGroupID], catalog: MenuGroupCatalog = .current) {
        let defaults = catalog.defaultArrangement(scope)
        for group in self[.hidden].filter(groups.contains) {
            move([group], to: defaults.section(of: group) ?? .more)
        }
    }

    private mutating func insert(_ moving: [MenuGroupID], into section: MenuSection, at index: Int) {
        for key in groupsBySection.keys {
            groupsBySection[key]?.removeAll(where: moving.contains)
        }
        groupsBySection[section, default: []].insert(contentsOf: moving, at: index)
    }
}

/// Uncustomized scopes follow the catalog defaults.
public struct MenuArrangement: Equatable, Sendable {
    public static let currentVersion = 1

    private var custom: [MenuScope: ScopeArrangement] = [:]

    public init() {}

    public func isCustomized(_ scope: MenuScope) -> Bool {
        custom[scope] != nil
    }

    /// New groups are appended to More.
    public func resolved(_ scope: MenuScope, catalog: MenuGroupCatalog = .current) -> ScopeArrangement {
        guard let stored = custom[scope] else { return catalog.defaultArrangement(scope) }
        let known = Set(catalog.groups(in: scope))
        var placed: Set<MenuGroupID> = []
        var groups: [MenuSection: [MenuGroupID]] = [:]
        for section in scope.sections {
            groups[section] = stored[section].compactMap { group in
                let current = catalog.renamed(group)
                return known.contains(current) && placed.insert(current).inserted ? current : nil
            }
        }
        groups[.more, default: []] += catalog.groups(in: scope).filter { !placed.contains($0) }
        return ScopeArrangement(scope: scope, groups: groups)
    }

    /// Storing the defaults clears the customization.
    public mutating func set(_ arrangement: ScopeArrangement, catalog: MenuGroupCatalog = .current) {
        let scope = arrangement.scope
        custom[scope] = arrangement == catalog.defaultArrangement(scope) ? nil : arrangement
    }

    public mutating func restoreDefaults(_ scope: MenuScope) {
        custom[scope] = nil
    }
}

extension MenuArrangement: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, scopes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported arrangement version \(version)")
        }
        let scopes = try container.decode([MenuScope: [MenuSection: [MenuGroupID]]].self, forKey: .scopes)
        for (scope, groups) in scopes {
            let ids = groups.values.flatMap { $0 }
            guard Set(groups.keys).isSubset(of: scope.sections), Set(ids).count == ids.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .scopes, in: container, debugDescription: "Invalid \(scope.rawValue) arrangement")
            }
            custom[scope] = ScopeArrangement(scope: scope, groups: groups)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        let scopes = custom.mapValues { arrangement in
            Dictionary(uniqueKeysWithValues: arrangement.scope.sections.map { ($0, arrangement[$0]) })
        }
        try container.encode(scopes, forKey: .scopes)
    }
}

extension MenuArrangement {
    /// Reproduces the menu legacy settings produced.
    public static func migrating(
        placements: [String: MenuPlacement], hiddenEntries: Set<String>, newInstallHidden: Set<String>,
        extraAngleEnabled: Bool, catalog: MenuGroupCatalog = .current
    ) -> (arrangement: MenuArrangement, hiddenEntries: Set<String>) {
        // Legacy menus never applied renamed keys.
        let overrides = Dictionary(uniqueKeysWithValues: placements.map { (MenuGroupID(rawValue: $0.key), $0.value) })
        var arrangement = MenuArrangement()
        var remainingHidden = hiddenEntries
        for scope in MenuScope.allCases {
            var migrated = catalog.defaultArrangement(scope)
            // Legacy placements never applied to these scopes.
            if scope != .commands, scope != .any {
                let groups = catalog.groups(in: scope)
                let primaries = migrated[.menu]
                let menu =
                    primaries.filter { overrides[$0] != .more }
                    + groups.filter { overrides[$0] == .primary && !primaries.contains($0) }
                migrated = ScopeArrangement(
                    scope: scope, groups: [.menu: menu, .more: groups.filter { !menu.contains($0) }])
            }
            let folded = migrated.groups.filter {
                $0.isEmptied(by: hiddenEntries, extraAngleEnabled: extraAngleEnabled)
            }
            migrated.hide(folded)
            remainingHidden.subtract(folded.flatMap(\.entryKeys).filter { !newInstallHidden.contains($0) })
            arrangement.set(migrated, catalog: catalog)
        }
        return (arrangement, remainingHidden)
    }
}
