import Engine
import MenuCatalog
import SwiftUI

struct FolderSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var newExcludedName = ""

    private static let renameStartRange = 0...999_999
    private static let renameStepRange = 1...1000
    private static let renameDigitRange = 1...10

    var body: some View {
        Form {
            Section("Duplicates and Empty Folders") {
                Toggle(
                    "Ignore hidden files when finding duplicates", isOn: $store.settings.folder.duplicatesIgnoreHidden)
                Toggle(isOn: $store.settings.folder.emptyIgnoresDSStore) {
                    Text("Treat folders with only .DS_Store as empty")
                }
            }
            Section {
                ForEach(store.settings.folder.excludedNames, id: \.self) { name in
                    LabeledContent(name) {
                        Button {
                            store.settings.folder.excludedNames.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove \(name)", comment: "Remove an excluded folder name"))
                    }
                }
                HStack {
                    TextField("Folder name", text: $newExcludedName, prompt: Text(verbatim: "build"))
                        .onSubmit(addExcludedName)
                    Button("Add", action: addExcludedName)
                        .disabled(trimmedNewName.isEmpty)
                }
            } header: {
                Text("Excluded Folders")
            } footer: {
                HStack {
                    Text("Folder scans skip folders with these names.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        store.settings.folder.excludedNames = FolderSettings.defaultExcludedNames
                    }
                    .disabled(store.settings.folder.excludedNames == FolderSettings.defaultExcludedNames)
                }
            }
            Section("Rename Defaults") {
                TextField("Prefix", text: $store.settings.folder.renamePrefix, prompt: Text("None"))
                TextField("Suffix", text: $store.settings.folder.renameSuffix, prompt: Text("None"))
                NumberField(
                    title: Text("Start number"), value: $store.settings.folder.renameStart,
                    range: Self.renameStartRange)
                NumberField(title: Text("Step"), value: $store.settings.folder.renameStep, range: Self.renameStepRange)
                NumberField(
                    title: Text("Digits"), value: $store.settings.folder.renameDigits, range: Self.renameDigitRange)
            }
            Section("Archives") {
                Picker("Format", selection: $store.settings.folder.archiveFormat) {
                    ForEach(ArchiveFormat.allCases, id: \.self) { format in
                        Text(MenuStrings.preset(.folderCompress, format.rawValue)).tag(format)
                    }
                }
                Toggle(isOn: $store.settings.folder.archiveExcludesMacMetadata) {
                    Text("Leave out Mac metadata files")
                    Text(verbatim: ".DS_Store, __MACOSX, ._*")
                }
            }
        }
    }

    private var trimmedNewName: String {
        newExcludedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addExcludedName() {
        let name = trimmedNewName
        guard !name.isEmpty else { return }
        if !store.settings.folder.excludedNames.contains(name) {
            store.settings.folder.excludedNames.append(name)
        }
        newExcludedName = ""
    }
}

struct TextSettingsView: View {
    @Bindable var store: SettingsStore

    private static let pdfDPIRange = 72...600

    var body: some View {
        Form {
            Section {
                Picker("Characters Shift_JIS cannot encode", selection: $store.settings.text.unmappable) {
                    Text("Stop with an error").tag(UnmappablePolicy.fail)
                    Text("Replace with ?").tag(UnmappablePolicy.questionMark)
                    Text("Replace with &#…; reference").tag(UnmappablePolicy.numericReference)
                }
            }
            Section("JSON") {
                Picker("Indent", selection: $store.settings.text.jsonIndent) {
                    Text("2 spaces").tag(JSONIndent.two)
                    Text("4 spaces").tag(JSONIndent.four)
                    Text("Tab").tag(JSONIndent.tab)
                }
                Picker("Sort keys", selection: $store.settings.text.keySortScope) {
                    Text("At every level").tag(KeySortScope.recursive)
                    Text("Top level only").tag(KeySortScope.topLevel)
                }
            }
            Section("CSV") {
                Toggle(isOn: $store.settings.text.csvTypeInference) {
                    Text("Detect numbers and booleans")
                    Text("When off, every CSV value converts as text.")
                }
            }
            Section(String(localized: "PDF", comment: "PDF export defaults")) {
                NumberField(
                    title: Text(
                        String(localized: "Page image resolution (dpi)", comment: "Saved PDF raster resolution")),
                    value: $store.settings.text.pdfImageDPI,
                    range: Self.pdfDPIRange)
            }
        }
    }
}
