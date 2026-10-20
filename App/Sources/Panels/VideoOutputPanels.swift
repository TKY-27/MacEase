import Engine
import MenuCatalog
import SwiftUI

struct SubtitleChoice: Codable, Equatable {
    var language: String
    var format: SubtitleFormat
    var translates = false
    var translationTarget: String

    var request: SubtitleRequest {
        SubtitleRequest(format: format, language: language, translation: translates ? translationTarget : nil)
    }
}

struct SubtitlesPanel: View {
    @State var choice: SubtitleChoice
    let cancel: () -> Void
    let run: (SubtitleChoice) -> Void

    var body: some View {
        PanelForm(actionTitle: String(localized: "Create", comment: "Subtitles panel action"), cancel: cancel) {
            run(choice)
        } content: {
            Section {
                SpokenLanguagePicker(selection: $choice.language)
                SubtitleFormatPicker(selection: $choice.format)
            }
            Section {
                Toggle("Translate", isOn: $choice.translates)
                if choice.translates {
                    TranslationLanguagePicker(selection: $choice.translationTarget)
                }
            }
        }
    }
}

struct ExtractAudioFormat {
    let preset: String
    let format: AudioFormat
    /// Empty for lossless formats.
    let bitrates: [Int]
}

struct ExtractAudioChoice: Codable, Equatable {
    var preset: String
    /// `nil` copies the original audio when possible.
    var kilobits: Int?
}

struct ExtractAudioPanel: View {
    let formats: [ExtractAudioFormat]
    @State var choice: ExtractAudioChoice
    let cancel: () -> Void
    let run: (ExtractAudioChoice, AudioFormat) -> Void

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Extract", comment: "Extract audio panel action"), canRun: format != nil,
            cancel: cancel
        ) {
            if let format { run(choice, format) }
        } content: {
            Section {
                Picker("Format", selection: $choice.preset) {
                    ForEach(formats, id: \.preset) {
                        Text(MenuStrings.preset(.videoExtractAudio, $0.preset)).tag($0.preset)
                    }
                }
                if !bitrates.isEmpty {
                    Picker("Bitrate", selection: $choice.kilobits) {
                        Text("Automatic").tag(Int?.none)
                        Divider()
                        ForEach(bitrates, id: \.self) { rate in
                            Text("\(rate) kbps", comment: "Audio bitrate").tag(Int?.some(rate))
                        }
                    }
                }
            } footer: {
                if !bitrates.isEmpty, choice.kilobits == nil {
                    Text("Automatic keeps the original audio when the format allows.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: choice.preset) {
            if let kilobits = choice.kilobits, !bitrates.contains(kilobits) { choice.kilobits = nil }
        }
    }

    private var selected: ExtractAudioFormat? {
        formats.first { $0.preset == choice.preset }
    }

    private var format: AudioFormat? { selected?.format }

    private var bitrates: [Int] { selected?.bitrates ?? [] }
}
