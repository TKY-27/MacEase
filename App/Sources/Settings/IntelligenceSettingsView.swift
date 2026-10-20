import Engine
import FoundationModels
import MenuCatalog
import Speech
import SwiftUI
import Translation
import Vision

struct IntelligenceSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var showsOCRLanguages = false
    @State private var subtitleLocales: [String] = []
    @State private var translationLanguages: [String] = []

    var body: some View {
        Form {
            Section("Text Recognition (OCR)") {
                LabeledContent {
                    Button("Choose…") { showsOCRLanguages = true }
                } label: {
                    Text("Languages")
                    Text(ocrLanguageSummary)
                }
                Picker("Result", selection: $store.settings.intelligence.ocrOutput) {
                    Text("Copy to clipboard").tag(TextOutput.clipboard)
                    Text("Save as text file").tag(TextOutput.file)
                    Text("Show in a window").tag(TextOutput.panel)
                }
            }
            Section("Subtitles") {
                Picker("Spoken language", selection: $store.settings.intelligence.subtitleLanguage) {
                    Text(
                        "System (\(Self.displayName(Locale.current.identifier)))", comment: "Follow the Mac's language"
                    )
                    .tag("")
                    Divider()
                    ForEach(options(subtitleLocales, current: store.settings.intelligence.subtitleLanguage), id: \.self)
                    {
                        Text(Self.displayName($0)).tag($0)
                    }
                }
                Picker("Format", selection: $store.settings.intelligence.subtitleFormat) {
                    ForEach(SubtitleFormat.allCases, id: \.self) { format in
                        Text(MenuStrings.preset(.videoSubtitles, format.rawValue)).tag(format)
                    }
                }
                Picker("Translate into", selection: $store.settings.intelligence.translationTarget) {
                    ForEach(
                        options(translationLanguages, current: store.settings.intelligence.translationTarget),
                        id: \.self
                    ) {
                        Text(Self.displayName($0)).tag($0)
                    }
                }
            }
            Section {
                Toggle(isOn: $store.settings.intelligence.aiEnabled) {
                    Text("Apple Intelligence features")
                    Text("AI rename and natural-language requests in the Finder menu.")
                }
                if case .unavailable = SystemLanguageModel.default.availability {
                    Label("Apple Intelligence is unavailable on this Mac.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showsOCRLanguages) {
            OCRLanguagesSheet(selection: $store.settings.intelligence.ocrLanguages)
        }
        .task {
            subtitleLocales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
            translationLanguages = await Self.translationLanguages()
        }
    }

    private var ocrLanguageSummary: String {
        let chosen = store.settings.intelligence.ocrLanguages
        guard !chosen.isEmpty else {
            return String(localized: "Detected automatically", comment: "OCR language summary")
        }
        return chosen.map(Self.displayName).formatted(.list(type: .and))
    }

    /// Keeps the stored value selectable while loading.
    private func options(_ identifiers: [String], current: String) -> [String] {
        let all = identifiers.contains(current) || current.isEmpty ? identifiers : identifiers + [current]
        return all.sorted { Self.displayName($0).localizedStandardCompare(Self.displayName($1)) == .orderedAscending }
    }

    private nonisolated static func translationLanguages() async -> [String] {
        await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
    }

    /// Vision reports some regions macOS cannot name.
    static func displayName(_ identifier: String) -> String {
        let languageCode = Locale.Language(identifier: identifier).languageCode?.identifier
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? languageCode.flatMap(Locale.current.localizedString(forLanguageCode:)) ?? identifier
    }
}

private struct OCRLanguagesSheet: View {
    @Binding var selection: [String]

    private let languages = RecognizeTextRequest().supportedRecognitionLanguages.map(\.minimalIdentifier)
        .sorted {
            IntelligenceSettingsView.displayName($0)
                .localizedStandardCompare(IntelligenceSettingsView.displayName($1)) == .orderedAscending
        }

    var body: some View {
        ChecklistSheet(resetTitle: "Detect Automatically", canReset: !selection.isEmpty) {
            selection = []
        } content: {
            Section {
                ForEach(languages, id: \.self) { language in
                    Toggle(IntelligenceSettingsView.displayName(language), isOn: chosen(language))
                }
            } header: {
                Text("OCR Languages")
            } footer: {
                Text("With no language chosen, MacEase detects the language automatically.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chosen(_ language: String) -> Binding<Bool> {
        Binding {
            selection.contains(language)
        } set: { isChosen in
            selection.removeAll { $0 == language }
            if isChosen { selection.append(language) }
        }
    }
}
