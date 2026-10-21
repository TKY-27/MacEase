import Engine
import MenuCatalog
import SwiftUI
import os

struct FinderMenuSettingsView: View {
    @Bindable var store: SettingsStore
    let supportDirectory: URL

    @State private var editsPresets = false

    private static let kinds: [FileKind] = [.image, .video, .audio, .pdf, .text, .folder, .archive, .jar, .any]

    /// Adjacent slots sharing an operation and unit.
    private static let slotRows: [[MenuValueSlot]] = MenuValues.slots.reduce(into: []) { rows, slot in
        if let last = rows.last?.last, last.unit == slot.unit, last.operation == slot.operation {
            rows[rows.count - 1].append(slot)
        } else {
            rows.append([slot])
        }
    }

    var body: some View {
        let titles = MenuStrings.titles(settings: store.planning)
        Form {
            Section {
                ForEach(Self.kinds, id: \.self) { kind in
                    MenuTreeRow(name: MenuStrings.kind(kind), sources: visibility(of: kind.menuOperations)) {
                        Text(MenuStrings.kind(kind))
                    } children: {
                        ForEach(kind.menuOperations, id: \.self) { op in
                            operationRow(op, titles: titles)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            } header: {
                Text("Menu Items")
            } footer: {
                HStack {
                    Text("Hidden items stay available in Settings. Unsupported items never appear.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Hide All") { store.hiddenEntries = Set(OperationID.allCases.flatMap(\.menuEntryKeys)) }
                        .disabled(store.hiddenEntries.isSuperset(of: OperationID.allCases.flatMap(\.menuEntryKeys)))
                    Button("Show All") { store.hiddenEntries = [] }
                        .disabled(store.hiddenEntries.isEmpty)
                }
            }
            Section {
                ForEach(Self.slotRows, id: \.first?.id) { slots in
                    MenuValueRow(store: store, slots: slots)
                }
                Toggle(isOn: $store.settings.extraRotationEnabled) {
                    Text("Extra angle")
                    Text("Adds one more angle to Rotate.")
                }
                if store.settings.extraRotationEnabled {
                    ExtraAngleRow(store: store)
                }
            } header: {
                Text(String(localized: "Menu Values", comment: "Editable Finder menu values"))
            } footer: {
                Text(
                    String(
                        localized: "Edited values replace the menu items in place. Sizes use 1 MB = 1,000,000 bytes.",
                        comment: "Editable Finder menu values footer")
                )
                .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Edit Presets…") { editsPresets = true }
                } label: {
                    Text("Platform presets")
                    Text("Size limits for Discord, X, Instagram and other Compress items.")
                }
            }
        }
        .sheet(isPresented: $editsPresets) {
            PresetSheet(store: store, supportDirectory: supportDirectory)
        }
    }

    @ViewBuilder private func operationRow(_ op: OperationID, titles: MenuTitles) -> some View {
        let label = VStack(alignment: .leading) {
            Text(MenuStrings.operationName(op))
            if let note = requirementNote(op) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if op.menuPresetIDs.isEmpty {
            Toggle(sources: visibility(of: [op]), isOn: \.self) { label }
                .padding(.leading, MenuTreeRow<Text, EmptyView>.indent * 2)
        } else {
            MenuTreeRow(name: MenuStrings.operationName(op), sources: visibility(of: [op]), depth: 1) {
                label
            } children: {
                ForEach(shownPresets(of: op), id: \.self) { preset in
                    Toggle(titles.preset(op, preset), isOn: visibility(of: op.menuEntryKey(preset)))
                        .padding(.leading, MenuTreeRow<Text, EmptyView>.indent * 3)
                }
            }
        }
    }

    private func visibility(of operations: [OperationID]) -> [Binding<Bool>] {
        operations.flatMap { op in
            op.menuPresetIDs.isEmpty ? op.menuEntryKeys : shownPresets(of: op).map(op.menuEntryKey)
        }
        .map(visibility(of:))
    }

    /// The extra angle exists only while enabled.
    private func shownPresets(of op: OperationID) -> [String] {
        op.menuPresetIDs.filter { $0 != OperationID.extraAnglePreset || store.settings.extraRotationEnabled }
    }

    private func visibility(of key: String) -> Binding<Bool> {
        Binding {
            !store.hiddenEntries.contains(key)
        } set: { visible in
            if visible {
                store.hiddenEntries.remove(key)
            } else {
                store.hiddenEntries.insert(key)
            }
        }
    }

    private func requirementNote(_ op: OperationID) -> String? {
        switch op.requirement {
        case .appleIntelligence:
            String(localized: "Requires Apple Intelligence", comment: "Menu item visibility note")
        case .java:
            String(localized: "Requires a Java runtime", comment: "Menu item visibility note")
        case nil: nil
        }
    }
}

/// DisclosureGroup hides a Toggle label from VoiceOver.
private struct MenuTreeRow<Label: View, Children: View>: View {
    static var indent: CGFloat { 22 }

    let name: String
    let sources: [Binding<Bool>]
    var depth = 0
    @ViewBuilder let label: Label
    @ViewBuilder let children: Children

    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .frame(width: Self.indent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                isExpanded
                    ? Text("Hide items in \(name)", comment: "Finder Menu tree collapse button")
                    : Text("Show items in \(name)", comment: "Finder Menu tree expand button"))
            Toggle(sources: sources, isOn: \.self) { label }
        }
        .padding(.leading, CGFloat(depth) * Self.indent)
        if isExpanded { children }
    }
}

private struct PresetSheet: View {
    let store: SettingsStore
    let supportDirectory: URL
    @Environment(\.dismiss) private var dismiss

    private static let width: CGFloat = 520
    private static let height: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            PresetSettingsView(store: store, supportDirectory: supportDirectory)
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: Self.width, height: Self.height)
    }
}

private struct MenuValueRow: View {
    @Bindable var store: SettingsStore
    let slots: [MenuValueSlot]
    /// Typed text per slot, kept while invalid.
    @State private var drafts: [String: String] = [:]

    private static let fieldWidth: CGFloat = 56
    private static let spacing: CGFloat = 6

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
            LabeledContent {
                HStack(spacing: Self.spacing) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        TextField(text: text(of: slot)) {
                            Text(verbatim: "\(unitName) \(index + 1)")
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: Self.fieldWidth)
                    }
                    Text(verbatim: unitSymbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } label: {
                Text(title)
                Text(unitName)
            }
            ResetButton(name: title, isDisabled: isDefault) {
                for slot in slots { store.settings.menuValues.reset(slot.id) }
                drafts = [:]
            }
        }
        if slots.contains(where: { !isValid(drafts[$0.id], for: $0) }) {
            Text(
                String(
                    localized:
                        "Use whole numbers from \(slots[0].range.lowerBound.formatted()) to \(slots[0].range.upperBound.formatted()).",
                    comment: "Explains an invalid menu value")
            )
            .foregroundStyle(.red)
        }
    }

    private var op: OperationID? { slots[0].operation }

    private var title: String {
        guard let op else { return slots[0].id }
        return String(
            localized: "\(MenuStrings.kind(op.kind)) ▸ \(MenuStrings.operationName(op))",
            comment: "Menu value row: kind and operation")
    }

    private var unitName: String {
        switch slots[0].unit {
        case .percent: String(localized: "Percentages", comment: "Menu value unit")
        case .pixels where op == .imageResize: String(localized: "Long edge in pixels", comment: "Menu value unit")
        case .pixels: String(localized: "Height in pixels", comment: "Menu value unit")
        case .megabytes: String(localized: "Target sizes in MB", comment: "Menu value unit")
        }
    }

    private var unitSymbol: String {
        switch slots[0].unit {
        case .percent: "%"
        case .pixels: "px"
        case .megabytes: "MB"
        }
    }

    private var isDefault: Bool {
        slots.allSatisfy {
            store.settings.menuValues.value(for: $0.id) == $0.defaultValue && isValid(drafts[$0.id], for: $0)
        }
    }

    private func isValid(_ draft: String?, for slot: MenuValueSlot) -> Bool {
        draft.map { Int($0).map(slot.range.contains) ?? false } ?? true
    }

    private func text(of slot: MenuValueSlot) -> Binding<String> {
        Binding {
            drafts[slot.id] ?? String(store.settings.menuValues.value(for: slot.id) ?? slot.defaultValue)
        } set: { text in
            drafts[slot.id] = text
            guard isValid(text, for: slot), let value = Int(text) else { return }
            var values = store.settings.menuValues
            do {
                try values.set(value, for: slot.id)
                store.settings.menuValues = values
            } catch {
                Logger(category: "settings").error("Validated menu value rejected for \(slot.id, privacy: .public)")
            }
        }
    }
}

private struct ExtraAngleRow: View {
    @Bindable var store: SettingsStore
    @State private var draft: String?

    private static let defaultDegrees = Settings().extraRotationDegrees
    private static let fieldWidth: CGFloat = 64
    private static let spacing: CGFloat = 6

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
            LabeledContent {
                HStack(spacing: Self.spacing) {
                    TextField(text: degrees) { Text("Angle") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: Self.fieldWidth)
                    Text(verbatim: "°")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } label: {
                Text("Angle")
            }
            ResetButton(
                name: String(localized: "Angle"),
                isDisabled: store.settings.extraRotationDegrees == Self.defaultDegrees
                    && draft.map { Self.degrees(from: $0) != nil } ?? true
            ) {
                store.settings.extraRotationDegrees = Self.defaultDegrees
                draft = nil
            }
        }
        if draft.map({ Self.degrees(from: $0) == nil }) ?? false {
            Text(
                String(
                    localized:
                        "Use degrees from \(Settings.extraRotationRange.lowerBound.formatted()) to \(Settings.extraRotationRange.upperBound.formatted()).",
                    comment: "Explains an invalid extra rotation angle")
            )
            .foregroundStyle(.red)
        }
    }

    private var degrees: Binding<String> {
        Binding {
            draft ?? store.settings.extraRotationDegrees.formatted(.number.grouping(.never))
        } set: { text in
            draft = text
            if let degrees = Self.degrees(from: text) { store.settings.extraRotationDegrees = degrees }
        }
    }

    private static func degrees(from text: String) -> Double? {
        guard let degrees = try? FloatingPointFormatStyle<Double>.number.parseStrategy.parse(text),
            degrees.isFinite, Settings.extraRotationRange.contains(degrees)
        else { return nil }
        return degrees
    }
}

private struct ResetButton: View {
    let name: String
    let isDisabled: Bool
    let reset: () -> Void

    var body: some View {
        Button(action: reset) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(String(localized: "Reset to default", comment: "Menu value reset button"))
        .accessibilityLabel(Text("Reset \(name)", comment: "Menu value reset button for VoiceOver"))
    }
}

extension MenuValueSlot {
    fileprivate var operation: OperationID? {
        id.split(separator: "/").first.flatMap { OperationID(rawValue: String($0)) }
    }
}

extension FileKind {
    fileprivate var menuOperations: [OperationID] { OperationID.menuOrder.filter { $0.kind == self } }
}
