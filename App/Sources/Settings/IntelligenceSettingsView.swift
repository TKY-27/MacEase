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

    var body: some View {
        Form {
            Section {
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
                Picker(
                    String(localized: "Text file encoding", comment: "Saved OCR text encoding"),
                    selection: $store.settings.intelligence.ocrFileEncoding
                ) {
                    ForEach(TextEncodingTarget.allCases, id: \.self) { encoding in
                        Text(MenuStrings.preset(.textEncoding, encoding.rawValue)).tag(encoding)
                    }
                }
            } header: {
                Text("Text Recognition (OCR)")
            } footer: {
                if store.settings.intelligence.ocrFileEncoding == .shiftJIS {
                    Text(
                        String(
                            localized: "Characters Shift_JIS cannot encode follow the policy in Text.",
                            comment: "OCR Shift_JIS policy pointer")
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                SpokenLanguagePicker(selection: $store.settings.intelligence.subtitleLanguage)
                SubtitleFormatPicker(selection: $store.settings.intelligence.subtitleFormat)
                TranslationLanguagePicker(selection: $store.settings.intelligence.translationTarget)
            } header: {
                Text("Subtitles")
            } footer: {
                Text(
                    String(localized: "Used for both audio and video files.", comment: "Shared subtitle settings")
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $store.settings.intelligence.aiEnabled) {
                    Text("Apple Intelligence features")
                    Text("AI rename and natural-language requests in the Finder menu.")
                }
                .accessibilityLabel(Text("Apple Intelligence features"))
                .accessibilityHint(Text("AI rename and natural-language requests in the Finder menu."))
                if case .unavailable = SystemLanguageModel.default.availability {
                    Label("Apple Intelligence is unavailable on this Mac.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showsOCRLanguages) {
            OCRLanguagesSheet(selection: $store.settings.intelligence.ocrLanguages)
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
    fileprivate static func options(_ identifiers: [String], current: String) -> [String] {
        let all = identifiers.contains(current) || current.isEmpty ? identifiers : identifiers + [current]
        return all.sorted { Self.displayName($0).localizedStandardCompare(Self.displayName($1)) == .orderedAscending }
    }

    fileprivate nonisolated static func translationLanguages() async -> [String] {
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

/// Shared by Settings and the Subtitles panel.
struct SpokenLanguagePicker: View {
    @Binding var selection: String
    @State private var locales: [String] = []

    var body: some View {
        Picker("Spoken language", selection: $selection) {
            Text(
                "System (\(IntelligenceSettingsView.displayName(Locale.current.identifier)))",
                comment: "Follow the Mac's language"
            )
            .tag("")
            Divider()
            ForEach(IntelligenceSettingsView.options(locales, current: selection), id: \.self) {
                Text(IntelligenceSettingsView.displayName($0)).tag($0)
            }
        }
        .task { locales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) } }
    }
}

struct SubtitleFormatPicker: View {
    @Binding var selection: SubtitleFormat

    var body: some View {
        Picker("Format", selection: $selection) {
            ForEach(SubtitleFormat.allCases, id: \.self) { format in
                Text(MenuStrings.preset(.videoSubtitles, format.rawValue)).tag(format)
            }
        }
    }
}

struct TranslationLanguagePicker: View {
    @Binding var selection: String
    @State private var languages: [String] = []

    var body: some View {
        Picker("Translate into", selection: $selection) {
            ForEach(IntelligenceSettingsView.options(languages, current: selection), id: \.self) {
                Text(IntelligenceSettingsView.displayName($0)).tag($0)
            }
        }
        .task { languages = await IntelligenceSettingsView.translationLanguages() }
    }
}
