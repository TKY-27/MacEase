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
                    DisclosureGroup {
                        ForEach(kind.menuOperations, id: \.self) { op in
                            operationRow(op, titles: titles)
                        }
                    } label: {
                        Toggle(sources: visibility(of: kind.menuOperations), isOn: \.self) {
                            Text(MenuStrings.kind(kind))
                        }
                    }
                }
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
        } else {
            DisclosureGroup {
                ForEach(op.menuPresetIDs, id: \.self) { preset in
                    Toggle(titles.preset(op, preset), isOn: visibility(of: op.menuEntryKey(preset)))
                }
            } label: {
                Toggle(sources: visibility(of: [op]), isOn: \.self) { label }
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
