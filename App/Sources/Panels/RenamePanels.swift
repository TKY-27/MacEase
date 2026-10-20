import Engine
import SwiftUI

struct RenameChoice: Codable, Equatable {
    var prefix: String
    var suffix: String
    var find = ""
    var replacement = ""
    var numbers = false
    var start: Int
    var step: Int
    var digits: Int
    var addsDate = false
    var date = RenameRules.DateSource.creation

    init(settings: FolderSettings) {
        prefix = settings.renamePrefix
        suffix = settings.renameSuffix
        start = settings.renameStart
        step = settings.renameStep
        digits = settings.renameDigits
    }

    var rules: RenameRules {
        RenameRules(
            prefix: prefix, suffix: suffix, find: find, replacement: replacement,
            numbering: numbers ? RenameRules.Numbering(start: start, step: step, digits: digits) : nil,
            date: addsDate ? date : nil)
    }
}

struct RenamePanel: View {
    let selection: [URL]
    @State var choice: RenameChoice
    let cancel: () -> Void
    let run: (RenameChoice) -> Void

    @State private var plans: [RenamePlan] = []
    @State private var failure: String?

    private static let startRange = 0...999_999
    private static let stepRange = 1...1_000
    private static let digitRange = 1...9

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Prefix", text: $choice.prefix)
                    TextField("Suffix", text: $choice.suffix)
                    TextField("Find", text: $choice.find)
                    TextField("Replace with", text: $choice.replacement)
                        .disabled(choice.find.isEmpty)
                }
                Section {
                    Toggle("Add numbers", isOn: $choice.numbers)
                    if choice.numbers {
                        NumberField(title: Text("Start at"), value: $choice.start, range: Self.startRange)
                        NumberField(title: Text("Step"), value: $choice.step, range: Self.stepRange)
                        NumberField(title: Text("Digits"), value: $choice.digits, range: Self.digitRange)
                    }
                    Toggle("Add date", isOn: $choice.addsDate)
                    if choice.addsDate {
                        Picker("Date", selection: $choice.date) {
                            Text("Created").tag(RenameRules.DateSource.creation)
                            Text("Photo taken (EXIF)").tag(RenameRules.DateSource.exif)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            preview
            PanelBar(
                actionTitle: String(localized: "Rename", comment: "Rename panel action"),
                canRun: failure == nil && !plans.isEmpty, cancel: cancel
            ) { run(choice) }
        }
        .frame(width: PanelLayout.wideWidth)
        .task(id: choice) { await refreshPreview() }
    }

    @ViewBuilder private var preview: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: .infinity, minHeight: PanelLayout.listHeight)
        } else {
            Table(plans) {
                TableColumn("Current Name") { Text($0.url.lastPathComponent) }
                TableColumn("New Name") { Text($0.newName) }
            }
            .frame(height: PanelLayout.listHeight)
        }
    }

    private func refreshPreview() async {
        let selection = selection
        let rules = choice.rules
        do {
            plans = try await offMain { try rules.plans(for: RenameRules.targets(for: selection)) }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = UserMessages.describe(
                EngineError.wrapping(error, path: selection.first?.path ?? ""),
                file: selection.first?.lastPathComponent ?? "")
        }
    }
}

extension RenamePlan: @retroactive Identifiable {
    public var id: URL { url }
}

/// One AI suggestion, editable before applying.
struct NameSuggestion: Identifiable {
    let url: URL
    var name = ""
    var isSelected = true
    var failure: String?

    var id: URL { url }

    var plan: RenamePlan? {
        let base = name.trimmingCharacters(in: .whitespaces)
        guard failure == nil, !base.isEmpty else { return nil }
        let pathExtension = url.pathExtension
        return RenamePlan(url: url, newName: pathExtension.isEmpty ? base : "\(base).\(pathExtension)")
    }
}

struct AIRenamePanel: View {
    let files: [URL]
    let cancel: () -> Void
    let run: ([RenamePlan]) -> Void

    @State private var suggestions: [NameSuggestion] = []
    @State private var finished = 0
    @State private var isSuggesting = true

    private static let developmentLanguage = "en"

    var body: some View {
        VStack(spacing: 0) {
            if isSuggesting {
                ProgressView(value: Double(finished), total: Double(max(files.count, 1))) {
                    Text("Suggesting names… \(finished) of \(files.count)")
                }
                .padding()
            }
            Table($suggestions) {
                TableColumn("") { $suggestion in
                    Toggle("Apply", isOn: $suggestion.isSelected)
                        .labelsHidden()
                        .accessibilityLabel(Text("Rename “\(suggestion.url.lastPathComponent)”"))
                        .disabled(suggestion.plan == nil)
                }
                .width(PanelLayout.thumbnailEdge / 2)
                TableColumn("Current Name") { $suggestion in Text(suggestion.url.lastPathComponent) }
                TableColumn("Suggested Name") { $suggestion in
                    if let failure = suggestion.failure {
                        Text(failure).foregroundStyle(.secondary)
                    } else {
                        TextField("Suggested Name", text: $suggestion.name)
                            .labelsHidden()
                    }
                }
            }
            .frame(height: PanelLayout.listHeight)
            PanelBar(
                actionTitle: String(localized: "Rename Selected", comment: "AI rename action"),
                canRun: !isSuggesting && !selectedPlans.isEmpty, cancel: cancel
            ) {
                run(selectedPlans)
            } accessory: {
                Button("Rename All") { run(suggestions.compactMap(\.plan)) }
                    .disabled(isSuggesting || suggestions.allSatisfy { $0.plan == nil })
            }
        }
        .frame(width: PanelLayout.wideWidth)
        .task { await suggest() }
    }

    private var selectedPlans: [RenamePlan] {
        suggestions.filter(\.isSelected).compactMap(\.plan)
    }

    private func suggest() async {
        suggestions = files.map { NameSuggestion(url: $0) }
        let language = Bundle.main.preferredLocalizations.first ?? Self.developmentLanguage
        for index in suggestions.indices {
            let url = suggestions[index].url
            do {
                suggestions[index].name = try await offMain {
                    try await AINaming.suggestedName(for: url, languageCode: language)
                }
            } catch is CancellationError {
                return
            } catch {
                suggestions[index].failure = UserMessages.describe(
                    EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
                suggestions[index].isSelected = false
            }
            finished += 1
        }
        isSuggesting = false
    }
}
