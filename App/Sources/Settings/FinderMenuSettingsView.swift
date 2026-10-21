import Engine
import MenuCatalog
import SwiftUI

struct FinderMenuSettingsView: View {
    @Bindable var store: SettingsStore
    let supportDirectory: URL

    @State private var editsPresets = false

    private static let kinds: [FileKind] = [.image, .video, .audio, .pdf, .text, .folder, .archive, .jar, .any]
    private static let rotationRange = -360.0...360.0

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
            Section("Rotation") {
                Toggle(isOn: $store.settings.extraRotationEnabled) {
                    Text("Extra angle")
                    Text("Adds one more angle to Rotate.")
                }
                if store.settings.extraRotationEnabled {
                    LabeledContent("Angle") {
                        Stepper(value: $store.settings.extraRotationDegrees, in: Self.rotationRange) {
                            Text("\(store.settings.extraRotationDegrees.formatted())°", comment: "Extra rotation angle")
                                .monospacedDigit()
                        }
                    }
                }
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
                ForEach(op.menuPresetIDs, id: \.self) { preset in
                    Toggle(titles.preset(op, preset), isOn: visibility(of: op.menuEntryKey(preset)))
                        .padding(.leading, MenuTreeRow<Text, EmptyView>.indent * 3)
                }
            }
        }
    }

    private func visibility(of operations: [OperationID]) -> [Binding<Bool>] {
        operations.flatMap(\.menuEntryKeys).map(visibility(of:))
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

extension FileKind {
    fileprivate var menuOperations: [OperationID] { OperationID.menuOrder.filter { $0.kind == self } }
}
