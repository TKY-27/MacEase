import Engine
import MenuCatalog
import SwiftUI

struct FinderMenuSettingsView: View {
    @Bindable var store: SettingsStore
    let supportDirectory: URL

    @State private var scope = MenuScope.image
    @State private var selection: Set<MenuGroupID> = []
    @State private var expanded: Set<MenuGroupID> = []
    @State private var options: MenuGroupOptions?
    @State private var confirmsRestore = false

    var body: some View {
        let arrangement = store.menuScope(scope)
        let contents = MenuGroupContent.all(store: store)
        VStack(spacing: 0) {
            HStack {
                Picker("Menu for", selection: $scope) {
                    Text(MenuScope.commands.title).tag(MenuScope.commands)
                    Divider()
                    ForEach(FileKind.menuOrder, id: \.self) { kind in
                        Text(MenuScope(kind).title).tag(MenuScope(kind))
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding()
            List(selection: $selection) {
                ForEach(arrangement.rows, id: \.self) { row in
                    switch row {
                    case .header(let section):
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                            .selectionDisabled(true)
                    case .placeholder(let section):
                        Text(section.placeholder)
                            .foregroundStyle(.secondary)
                            .selectionDisabled(true)
                    case .group(let group):
                        groupRow(group, content: contents[group], arrangement: arrangement)
                            .tag(group)
                    }
                }
                // Movable headers: fixed rows block adjacent drops.
                .onMove { offsets, destination in
                    let moving = offsets.compactMap { offset -> MenuGroupID? in
                        if case .group(let group) = arrangement.rows[offset] { group } else { nil }
                    }
                    rearrange(moving) { $0.move(fromOffsets: offsets, toOffset: destination) }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: MenuGroupID.self) { groups in
                commands(for: arrangement.groups.filter(groups.contains), in: arrangement)
            } primaryAction: { groups in
                guard groups.count == 1, let group = groups.first else { return }
                options = MenuGroupOptions(group)
            }
            if scope != .commands, scope != .any {
                Text("Mixed selections show these items in a submenu for each kind.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, Self.footerSpacing)
            }
            HStack {
                Button("Restore Defaults…") { confirmsRestore = true }
                    .disabled(store.isMenuDefault(scope))
                Spacer()
                let selected = arrangement.groups.filter(selection.contains)
                Button("Move Up") { moveUp(selected) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                    .disabled(selected.isEmpty)
                Button("Move Down") { moveDown(selected) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                    .disabled(selected.isEmpty)
                Menu("Move To") {
                    ForEach(scope.sections, id: \.self) { section in
                        Button(section.title) { move(selected, to: section) }
                            .disabled(selected.allSatisfy { arrangement.section(of: $0) == section })
                    }
                }
                .fixedSize()
                .disabled(selected.isEmpty)
            }
            .padding()
        }
        .sheet(item: $options) { options in
            MenuOptionsSheet(store: store, options: options, supportDirectory: supportDirectory)
        }
        .confirmationDialog(
            Text("Restore the default \(scope.title) menu?", comment: "Finder menu organizer confirmation"),
            isPresented: $confirmsRestore
        ) {
            Button("Restore", role: .destructive) {
                store.restoreMenuDefaults(scope)
                selection = []
            }
        } message: {
            Text("Item order, visibility and checked items return to their defaults. Options values are kept.")
        }
        .onChange(of: scope) {
            selection = []
            expanded = []
        }
    }

    private static let footerSpacing: CGFloat = 6

    private func groupRow(
        _ group: MenuGroupID, content: MenuGroupContent?, arrangement: ScopeArrangement
    ) -> some View {
        let title = content?.title ?? group.rawValue
        let note = note(for: group, content: content)
        let section = arrangement.section(of: group) ?? .hidden
        let position = String(
            localized:
                "\(section.title), \((arrangement[section].firstIndex(of: group) ?? 0) + 1) of \(arrangement[section].count)",
            comment: "VoiceOver value: section and position")
        return MenuGroupRow(
            title: title, note: note, accessibilityValue: [position, note].compactMap(\.self).joined(separator: ", "),
            leaves: content?.leaves ?? [], hiddenEntries: $store.hiddenEntries,
            isExpanded: Binding {
                expanded.contains(group)
            } set: { isExpanded in
                if isExpanded { expanded.insert(group) } else { expanded.remove(group) }
            },
            openOptions: MenuGroupOptions(group).map { groupOptions in { options = groupOptions } }
        ) {
            commands(for: [group], in: arrangement)
        }
    }

    private func note(for group: MenuGroupID, content: MenuGroupContent?) -> String? {
        if group == MenuGroupID(.update) {
            return String(localized: "Appears when an update is available.")
        }
        if group.rawValue == OperationID.folderDownloadMedia.menuGroupID(preset: nil) {
            return String(localized: "Folder background only.")
        }
        switch content?.operation?.requirement {
        case .appleIntelligence:
            return String(localized: "Requires Apple Intelligence", comment: "Menu item visibility note")
        case .java:
            return String(localized: "Requires a Java runtime", comment: "Menu item visibility note")
        case nil:
            guard let leaves = content?.leaves, leaves.count > 1 else { return nil }
            let shown = leaves.filter { !store.hiddenEntries.contains($0.key) }.count
            return String(localized: "\(shown) of \(leaves.count) items", comment: "Checked leaves of a menu group")
        }
    }

    @ViewBuilder private func commands(for groups: [MenuGroupID], in arrangement: ScopeArrangement) -> some View {
        if !groups.isEmpty {
            Button("Move Up") { moveUp(groups) }
            Button("Move Down") { moveDown(groups) }
            Divider()
            ForEach(scope.sections.filter { $0 != .hidden }, id: \.self) { section in
                if !groups.allSatisfy({ arrangement.section(of: $0) == section }) {
                    Button(String(localized: "Move to \(section.title)", comment: "Finder menu organizer command")) {
                        move(groups, to: section)
                    }
                }
            }
            if groups.contains(where: { arrangement.section(of: $0) != .hidden }) {
                Button("Hide") { move(groups, to: .hidden) }
            }
            if groups.contains(where: { arrangement.section(of: $0) == .hidden }) {
                Button("Show") { rearrange(groups) { $0.show(groups) } }
            }
            if groups.count == 1, let group = groups.first, let groupOptions = MenuGroupOptions(group) {
                Divider()
                Button("Options…") { options = groupOptions }
            }
        }
    }

    private func move(_ groups: [MenuGroupID], to section: MenuSection) {
        rearrange(groups) { $0.move(groups, to: section) }
    }

    private func moveUp(_ groups: [MenuGroupID]) {
        rearrange(groups) { $0.moveUp(groups) }
    }

    private func moveDown(_ groups: [MenuGroupID]) {
        rearrange(groups) { $0.moveDown(groups) }
    }

    private func rearrange(_ groups: [MenuGroupID], _ change: (inout ScopeArrangement) -> Void) {
        let before = store.menuScope(scope)
        store.rearrangeMenu(scope, change)
        let after = store.menuScope(scope)
        guard before != after, let first = groups.first, let section = after.section(of: first) else { return }
        let message =
            if groups.count == 1 {
                String(
                    localized:
                        "\(MenuGroupContent.title(of: first, store: store)) moved to \(section.title), position \((after[section].firstIndex(of: first) ?? 0) + 1)",
                    comment: "VoiceOver announcement after a move")
            } else {
                String(
                    localized: "\(groups.count) items moved to \(section.title)",
                    comment: "VoiceOver announcement after a move")
            }
        AccessibilityNotification.Announcement(message).post()
    }
}

private struct MenuGroupRow<Actions: View>: View {
    let title: String
    let note: String?
    let accessibilityValue: String
    let leaves: [MenuLeaf]
    @Binding var hiddenEntries: Set<String>
    @Binding var isExpanded: Bool
    let openOptions: (() -> Void)?
    @ViewBuilder let actions: Actions

    private static var disclosureWidth: CGFloat { 16 }
    private static var leafIndent: CGFloat { 22 }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                ZStack {
                    if leaves.count > 1 {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            isExpanded
                                ? Text("Hide items in \(title)", comment: "Finder Menu tree collapse button")
                                : Text("Show items in \(title)", comment: "Finder Menu tree expand button"))
                    }
                }
                .frame(width: Self.disclosureWidth)
                HStack {
                    Text(title)
                    Spacer()
                    if let note {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
                .accessibilityActions { actions }
                if let openOptions {
                    Button("Options…", action: openOptions)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Options for \(title)", comment: "Finder menu organizer button"))
                }
            }
            if isExpanded {
                ForEach(leaves, id: \.key) { leaf in
                    let isLastShown = !hiddenEntries.contains(leaf.key) && shownCount == 1
                    Toggle(leaf.title, isOn: visibility(of: leaf))
                        .toggleStyle(.checkbox)
                        .disabled(isLastShown)
                        .help(isLastShown ? String(localized: "Hide it instead to remove it from the menu.") : "")
                        .padding(.leading, Self.disclosureWidth + Self.leafIndent)
                }
            }
        }
    }

    private var shownCount: Int {
        leaves.filter { !hiddenEntries.contains($0.key) }.count
    }

    private func visibility(of leaf: MenuLeaf) -> Binding<Bool> {
        Binding {
            !hiddenEntries.contains(leaf.key)
        } set: { visible in
            if visible { hiddenEntries.remove(leaf.key) } else { hiddenEntries.insert(leaf.key) }
        }
    }
}

private struct MenuLeaf: Hashable {
    let key: String
    let title: String
}

private struct MenuGroupContent {
    let title: String
    let operation: OperationID?
    let leaves: [MenuLeaf]

    /// Includes hidden and unavailable leaves.
    @MainActor static func all(store: SettingsStore) -> [MenuGroupID: MenuGroupContent] {
        let titles = MenuStrings.titles(settings: store.planning)
        let file = MenuFile(
            token: "", hostAvailable: true, visibleOperations: OperationID.menuOrder,
            titles: MenuTitles(operation: titles.operation, preset: titles.preset, kind: titles.kind),
            extraRotationDegrees: store.settings.extraRotationEnabled ? store.settings.extraRotationDegrees : nil)
        var contents = Dictionary(grouping: file.entries) { MenuGroupID(rawValue: $0.resolvedGroupID) }
            .compactMapValues { entries -> MenuGroupContent? in
                guard let first = entries.first, let title = first.path.first else { return nil }
                return MenuGroupContent(
                    title: title, operation: first.op,
                    leaves: entries.map {
                        MenuLeaf(key: $0.op.menuEntryKey($0.preset ?? ""), title: $0.path.last ?? title)
                    })
            }
        contents[MenuGroupID(.update)] = MenuGroupContent(
            title: String(localized: "Update Available"), operation: nil, leaves: [])
        contents[MenuGroupID(.preview)] = MenuGroupContent(
            title: MenuStrings.previewTitle(open: store.finderPreviewEnabled), operation: nil, leaves: [])
        return contents
    }

    @MainActor static func title(of group: MenuGroupID, store: SettingsStore) -> String {
        all(store: store)[group]?.title ?? group.rawValue
    }
}

extension MenuScope {
    fileprivate var title: String {
        if let kind = FileKind.menuOrder.first(where: { MenuScope($0) == self }) { return MenuStrings.kind(kind) }
        return String(localized: "Commands", comment: "Finder menu organizer scope")
    }
}

extension MenuSection {
    fileprivate var title: String {
        switch self {
        case .finder: String(localized: "Finder Menu")
        case .menu: String(localized: "MacEase Menu")
        case .more: String(localized: "More")
        case .hidden: String(localized: "Hidden", comment: "Finder menu organizer section")
        }
    }

    fileprivate var placeholder: String {
        switch self {
        case .finder: String(localized: "Drag items here to show them in the Finder menu.")
        case .menu: String(localized: "Drag items here to show them in the MacEase menu.")
        case .more: String(localized: "Drag items here to show them in More.")
        case .hidden: String(localized: "Drag items here to hide them.")
        }
    }
}
