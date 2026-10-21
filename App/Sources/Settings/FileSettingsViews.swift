import Engine
import MenuCatalog
import SwiftUI

struct FolderSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var newExcludedName = ""
    @State private var editsExclusionRules = false
    @State private var showsMatching = false

    private static let renameStartRange = 0...999_999
    private static let renameStepRange = 1...1000
    private static let renameDigitRange = 1...10
    private static let minimumSizeRange = 0...Int.max
    private static let minimumSizeStep = 1000

    var body: some View {
        Form {
            Section {
                Picker(
                    String(localized: "Copy to keep", comment: "Duplicate keep policy"),
                    selection: $store.settings.folder.duplicateKeepPolicy
                ) {
                    Text(String(localized: "Ask every time", comment: "Duplicate keep policy"))
                        .tag(DuplicateKeepPolicy.ask)
                    Text(String(localized: "Keep oldest", comment: "Duplicate keep policy"))
                        .tag(DuplicateKeepPolicy.oldest)
                    Text(String(localized: "Keep newest", comment: "Duplicate keep policy"))
                        .tag(DuplicateKeepPolicy.newest)
                }
                MoreOptionsRow(
                    title: String(localized: "Matching", comment: "Duplicate candidate filters"),
                    isExpanded: $showsMatching)
                if showsMatching {
                    NumberField(
                        title: Text(String(localized: "Minimum size (bytes)", comment: "Duplicate size filter")),
                        value: minimumDuplicateBytes, range: Self.minimumSizeRange, step: Self.minimumSizeStep)
                    Toggle(
                        String(localized: "Ignore empty files", comment: "Duplicate filter"),
                        isOn: $store.settings.folder.duplicatesIgnoreEmpty)
                    Toggle(
                        "Ignore hidden files when finding duplicates",
                        isOn: $store.settings.folder.duplicatesIgnoreHidden)
                    Toggle(
                        String(localized: "Only files with the same name", comment: "Duplicate filter"),
                        isOn: $store.settings.folder.duplicatesMatchNames)
                    Toggle(
                        String(localized: "Only files modified at the same time", comment: "Duplicate filter"),
                        isOn: $store.settings.folder.duplicatesMatchModificationSecond)
                }
            } header: {
                Text(MenuStrings.operationName(.folderRemoveDuplicates))
            } footer: {
                Text(duplicatesFooter)
                    .foregroundStyle(.secondary)
            }
            Section(MenuStrings.operationName(.folderRemoveEmpty)) {
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
                LabeledContent {
                    Button(String(localized: "Edit Rules…", comment: "Opens folder exclusion patterns")) {
                        editsExclusionRules = true
                    }
                } label: {
                    Text(String(localized: "Pattern rules", comment: "Folder exclusion patterns"))
                    Text(
                        String(
                            localized: "Skip folders, files and extensions by pattern, per feature.",
                            comment: "Pattern rules summary"))
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
            Section(String(localized: "Reports", comment: "Folder Tree and Analyze defaults")) {
                Toggle(isOn: $store.settings.folder.treeFoldersOnly) {
                    Text(String(localized: "Folder Tree lists folders only", comment: "Folder Tree omits files"))
                }
                Picker(
                    String(localized: "Analyze export format", comment: "Default analysis export format"),
                    selection: $store.settings.folder.analysisExportFormat
                ) {
                    ForEach(AnalysisExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
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
        .sheet(isPresented: $editsExclusionRules) {
            ExclusionRulesSheet(folder: $store.settings.folder)
        }
    }

    private var duplicatesFooter: String {
        switch store.settings.folder.duplicateKeepPolicy {
        case .ask:
            String(
                localized: "Copies are compared byte by byte, then you choose which to keep.",
                comment: "Duplicate keep policy footer")
        case .oldest, .newest:
            String(
                localized: "Copies are compared byte by byte. The others move to the Trash without asking.",
                comment: "Duplicate keep policy footer")
        }
    }

    private var minimumDuplicateBytes: Binding<Int> {
        Binding {
            Int(store.settings.folder.duplicateMinimumBytes)
        } set: {
            store.settings.folder.duplicateMinimumBytes = Int64($0)
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

private struct ExclusionRulesSheet: View {
    @Binding var folder: FolderSettings
    @State private var scope = Scope.all

    enum Scope: CaseIterable {
        case all
        case duplicates
        case empty
        case tree
        case analyze
        case rename

        var rules: WritableKeyPath<FolderSettings, FolderExclusions> {
            switch self {
            case .all: \.scanExclusions
            case .duplicates: \.duplicateExclusions
            case .empty: \.emptyExclusions
            case .tree: \.treeExclusions
            case .analyze: \.analyzeExclusions
            case .rename: \.renameExclusions
            }
        }

        var title: String {
            switch self {
            case .all: String(localized: "All folder scans", comment: "Exclusion scope")
            case .duplicates: MenuStrings.operationName(.folderRemoveDuplicates)
            case .empty: MenuStrings.operationName(.folderRemoveEmpty)
            case .tree: MenuStrings.operationName(.folderTree)
            case .analyze: MenuStrings.operationName(.folderAnalyze)
            case .rename: MenuStrings.operationName(.folderRename)
            }
        }
    }

    var body: some View {
        ChecklistSheet(resetTitle: "Clear Rules", canReset: folder[keyPath: scope.rules] != FolderExclusions()) {
            folder[keyPath: scope.rules] = FolderExclusions()
        } content: {
            Section {
                Picker(String(localized: "Applies to", comment: "Exclusion scope"), selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField(
                    String(localized: "Folders", comment: "Folder name exclusion patterns"),
                    text: $folder[dynamicMember: scope.rules.appending(path: \.folders)],
                    prompt: Text(verbatim: "build; .cache"))
                TextField(
                    String(localized: "Files", comment: "File name exclusion patterns"),
                    text: $folder[dynamicMember: scope.rules.appending(path: \.files)],
                    prompt: Text(verbatim: "*.log; Thumbs.db"))
                TextField(
                    String(localized: "Extensions", comment: "Extension exclusion patterns"),
                    text: $folder[dynamicMember: scope.rules.appending(path: \.extensions)],
                    prompt: Text(verbatim: "tmp; bak"))
            } header: {
                Text(String(localized: "Exclusion Rules", comment: "Folder exclusion sheet title"))
            } footer: {
                Text(rulesFooter)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rulesFooter: String {
        let syntax = String(
            localized: "Separate rules with semicolons. * matches any text and ? one character. Case is ignored.",
            comment: "Exclusion pattern syntax")
        guard scope != .all else { return syntax }
        return syntax + " "
            + String(localized: "Rules for all folder scans also apply.", comment: "Exclusion scope combination")
    }
}

struct TextSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var substitute: String
    @State private var pinnedKeys: String
    @State private var showsMoreSortOptions = false

    private static let pdfDPIRange = 72...600
    private static let pinnedKeySeparator: Character = ","

    init(store: SettingsStore) {
        self.store = store
        _substitute = State(initialValue: store.settings.text.shiftJISSubstitute)
        _pinnedKeys = State(
            initialValue: store.settings.text.jsonPinnedKeys.joined(separator: "\(Self.pinnedKeySeparator) "))
    }

    var body: some View {
        Form {
            Section {
                Picker("Characters Shift_JIS cannot encode", selection: $store.settings.text.unmappable) {
                    Text("Stop with an error").tag(UnmappablePolicy.fail)
                    Text("Replace with ?").tag(UnmappablePolicy.questionMark)
                    Text("Replace with &#…; reference").tag(UnmappablePolicy.numericReference)
                    Text(String(localized: "Replace with another character", comment: "Shift_JIS custom substitute"))
                        .tag(UnmappablePolicy.custom)
                }
                if store.settings.text.unmappable == .custom {
                    TextField(
                        String(localized: "Replacement character", comment: "Shift_JIS custom substitute"),
                        text: $substitute, prompt: Text(verbatim: "〓"))
                    if !Self.isEncodableSubstitute(substitute) {
                        Text(
                            String(
                                localized: "Enter one character that Shift_JIS can encode.",
                                comment: "Explains an invalid Shift_JIS substitute")
                        )
                        .foregroundStyle(.red)
                    }
                }
            } footer: {
                Text(
                    String(
                        localized: "Applies to the Encoding menu and to recognized text saved as Shift_JIS.",
                        comment: "Shift_JIS policy scope")
                )
                .foregroundStyle(.secondary)
            }
            .onChange(of: substitute) {
                if Self.isEncodableSubstitute(substitute) { store.settings.text.shiftJISSubstitute = substitute }
            }
            Section {
                Picker("Indent", selection: $store.settings.text.jsonIndent) {
                    Text("2 spaces").tag(JSONIndent.two)
                    Text("4 spaces").tag(JSONIndent.four)
                    Text("Tab").tag(JSONIndent.tab)
                }
                Picker("Sort keys", selection: $store.settings.text.keySortScope) {
                    Text("At every level").tag(KeySortScope.recursive)
                    Text("Top level only").tag(KeySortScope.topLevel)
                }
                Picker(
                    String(localized: "Compare keys", comment: "JSON key comparison"),
                    selection: $store.settings.text.jsonKeyComparison
                ) {
                    Text(String(localized: "By character code", comment: "JSON ordinal key comparison"))
                        .tag(JSONKeyComparison.ordinal)
                    Text(String(localized: "Ignoring case", comment: "JSON case-insensitive key comparison"))
                        .tag(JSONKeyComparison.caseInsensitive)
                    Text(String(localized: "Natural (2 before 10)", comment: "JSON natural key comparison"))
                        .tag(JSONKeyComparison.natural)
                }
                Picker(
                    String(localized: "Order", comment: "JSON key sort direction"),
                    selection: $store.settings.text.jsonDescending
                ) {
                    Text(String(localized: "Ascending", comment: "Sort direction")).tag(false)
                    Text(String(localized: "Descending", comment: "Sort direction")).tag(true)
                }
                .pickerStyle(.segmented)
                MoreOptionsRow(
                    title: String(localized: "More Sort Options", comment: "Advanced JSON sort options"),
                    isExpanded: $showsMoreSortOptions)
                if showsMoreSortOptions {
                    TextField(
                        String(localized: "Keys first", comment: "JSON pinned keys"), text: $pinnedKeys,
                        prompt: Text(verbatim: "id, name"))
                    Toggle(isOn: $store.settings.text.jsonSortPrimitiveArrays) {
                        Text(String(localized: "Sort lists of plain values", comment: "JSON primitive array sorting"))
                        Text(
                            String(
                                localized: "Off by default, because list order often carries meaning.",
                                comment: "JSON primitive array sorting"))
                    }
                }
            } header: {
                Text(verbatim: "JSON")
            } footer: {
                if showsMoreSortOptions {
                    Text(
                        String(
                            localized: "Keys first are separated by commas and keep their order.",
                            comment: "JSON pinned keys help")
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .onChange(of: pinnedKeys) {
                store.settings.text.jsonPinnedKeys = pinnedKeys.split(separator: Self.pinnedKeySeparator)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
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
                Picker(
                    String(localized: "Page images", comment: "PDF page image layout"),
                    selection: $store.settings.text.pdfImageLayout
                ) {
                    Text(String(localized: "In a new folder", comment: "PDF page image layout"))
                        .tag(PDFImageLayout.pagesFolder)
                    Text(String(localized: "Next to the PDF", comment: "PDF page image layout"))
                        .tag(PDFImageLayout.looseFiles)
                }
            }
        }
    }

    private static func isEncodableSubstitute(_ text: String) -> Bool {
        text.unicodeScalars.count == 1 && text.data(using: SourceTextEncoding.cp932.foundationEncoding) != nil
    }
}
