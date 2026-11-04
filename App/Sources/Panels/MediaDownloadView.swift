import AppKit
import Engine
import Observation
import SwiftUI

@MainActor
@Observable
final class MediaDownloadModel {
    let destination: URL
    var urls = "" {
        didSet {
            guard urls != oldValue else { return }
            cancelAnalysis()
            sources = []
            selectedIDs = []
            failures = []
            error = nil
        }
    }
    var format = MediaDownloadFormat.source
    var resolution: Int?
    var subtitle: MediaSubtitle?
    var subtitleFormat = MediaSubtitleFormat.vtt
    var selectedIDs: Set<String> = []
    private(set) var sources: [MediaSource] = []
    private(set) var failures: [MediaAnalysisFailure] = []
    private(set) var isAnalyzing = false
    private(set) var error: String?
    private var analysisTask: Task<Void, Never>?
    private var generation = 0
    private var closed = false

    init(destination: URL) { self.destination = destination }

    var selectedSources: [MediaSource] { sources.filter { selectedIDs.contains($0.id) } }
    var isAudioOnly: Bool { [.audio, .m4a, .mp3, .wav, .flac].contains(format) }
    var canAnalyze: Bool { !closed && !isAnalyzing && !urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canDownload: Bool { !closed && !isAnalyzing && !selectedSources.isEmpty }

    var resolutions: [Int] {
        let candidates = selectedSources.isEmpty ? sources : selectedSources
        guard let first = candidates.first else { return [] }
        return candidates.dropFirst().reduce(Set(first.resolutions)) {
            $0.intersection($1.resolutions)
        }.sorted(by: >)
    }

    var subtitles: [MediaSubtitle] {
        let candidates = selectedSources.isEmpty ? sources : selectedSources
        guard let first = candidates.first else { return [] }
        return candidates.dropFirst().reduce(Set(first.subtitles)) {
            $0.intersection($1.subtitles)
        }.sorted {
            $0.language == $1.language ? !$0.automatic && $1.automatic : $0.language < $1.language
        }
    }

    func normalizeOptions() {
        if let resolution, !resolutions.contains(resolution) { self.resolution = nil }
        if let subtitle, !subtitles.contains(subtitle) { self.subtitle = nil }
    }

    func analyze() {
        guard canAnalyze else { return }
        error = nil
        failures = []
        sources = []
        selectedIDs = []
        let parsed: [URL]
        do {
            parsed = try urls.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { try MediaDownloader.validateURL($0) }
            guard !parsed.isEmpty else { return }
        } catch {
            self.error = String(localized: "Enter one valid HTTP or HTTPS URL per line.")
            return
        }
        generation += 1
        let expected = generation
        isAnalyzing = true
        analysisTask = Task {
            do {
                let downloader = try MediaDownloader()
                let analysis = try await downloader.analyze(urls: parsed)
                guard !closed, !Task.isCancelled, generation == expected else { return }
                sources = analysis.sources
                failures = analysis.failures
                selectedIDs = Set(analysis.sources.filter { !$0.isPlaylistEntry }.map(\.id))
                normalizeOptions()
                isAnalyzing = false
            } catch is CancellationError {
                if generation == expected { isAnalyzing = false }
            } catch {
                guard !closed, generation == expected else { return }
                self.error = UserMessages.describeActivity(error)
                isAnalyzing = false
            }
        }
    }

    func cancelAnalysis() {
        generation += 1
        analysisTask?.cancel()
        isAnalyzing = false
    }

    func submit(_ run: (MediaDownloadRequest) throws -> Void) -> Bool {
        guard canDownload else { return false }
        normalizeOptions()
        let selections = selectedSources.map {
            MediaDownloadSelection(
                source: $0, format: format, resolution: isAudioOnly ? nil : resolution,
                subtitle: subtitle, subtitleFormat: subtitleFormat)
        }
        do {
            try run(MediaDownloadRequest(destination: destination, selections: selections))
            return true
        } catch {
            self.error = UserMessages.describeActivity(error)
            return false
        }
    }

    func close() async {
        closed = true
        cancelAnalysis()
        await analysisTask?.value
    }
}

struct MediaDownloadView: View {
    @Bindable var model: MediaDownloadModel
    let close: () -> Void
    let run: (MediaDownloadRequest) throws -> Void
    @FocusState private var urlsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            destination
            urlInput
            results
            options
            if let error = model.error { ProblemLabel(text: error) }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download") {
                    if model.submit(run) { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canDownload)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 580)
        .onAppear { urlsFocused = true }
        .onChange(of: model.selectedIDs) { model.normalizeOptions() }
    }

    private var destination: some View {
        LabeledContent("Save to") {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.destination.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help(model.destination.path(percentEncoded: false))
        }
    }

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("URLs, one per line")
            TextEditor(text: $model.urls)
                .font(.body.monospaced())
                .focused($urlsFocused)
                .frame(height: 86)
                .border(.separator)
                .accessibilityLabel(Text("URLs, one per line"))
                .disabled(model.isAnalyzing)
            HStack {
                Text("Public videos and audio. Live streams and sign-in are not supported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("Stop Analysis") { model.cancelAnalysis() }
                } else {
                    Button("Analyze") { model.analyze() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!model.canAnalyze)
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Media")
                Spacer()
                Button("Select All") { model.selectedIDs = Set(model.sources.map(\.id)) }
                    .disabled(model.sources.isEmpty || model.isAnalyzing)
                Button("Clear Selection") { model.selectedIDs = [] }
                    .disabled(model.selectedIDs.isEmpty || model.isAnalyzing)
            }
            Table(model.sources) {
                TableColumn("") { source in
                    Toggle(
                        source.title,
                        isOn: Binding(
                            get: { model.selectedIDs.contains(source.id) },
                            set: {
                                if $0 {
                                    model.selectedIDs.insert(source.id)
                                } else {
                                    model.selectedIDs.remove(source.id)
                                }
                            })
                    )
                    .labelsHidden()
                    .accessibilityLabel(Text("Download \(source.title)"))
                }
                .width(28)
                TableColumn("Title") { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title).lineLimit(1)
                        if source.isPlaylistEntry {
                            Text("Playlist entry").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(source.title)
                }
                TableColumn("Duration") { source in
                    Text(Self.duration(source.duration)).monospacedDigit()
                }
                .width(74)
                TableColumn("Available formats") { source in
                    Text(source.availableFormats.joined(separator: ", "))
                        .lineLimit(1)
                        .help(source.availableFormats.joined(separator: ", "))
                }
                .width(min: 110, ideal: 140)
            }
            .frame(minHeight: 140)
            .overlay {
                if model.sources.isEmpty {
                    Text(
                        model.isAnalyzing
                            ? String(localized: "Analyzing…")
                            : String(localized: "Analyze URLs to choose media and available options.")
                    )
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
            }
            if model.sources.contains(where: \.isPlaylistEntry) {
                Text("Choose the playlist entries you want to download.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.failures.isEmpty {
                DisclosureGroup(String(localized: "URLs that could not be analyzed")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.failures.enumerated()), id: \.offset) { _, failure in
                                Text("\(failure.url.host() ?? "") — \(failure.message)")
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.callout)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Picker("Format", selection: $model.format) {
                    ForEach(MediaDownloadFormat.allCases, id: \.self) { format in
                        Text(Self.formatTitle(format)).tag(format)
                    }
                }
                Picker("Resolution", selection: $model.resolution) {
                    Text("Best available").tag(nil as Int?)
                    ForEach(model.resolutions, id: \.self) { resolution in
                        Text("\(resolution)p").tag(Optional(resolution))
                    }
                }
                .disabled(model.isAudioOnly || model.sources.isEmpty)
            }
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Picker("Subtitles", selection: $model.subtitle) {
                    Text("Off").tag(nil as MediaSubtitle?)
                    ForEach(model.subtitles, id: \.self) { subtitle in
                        Text(Self.subtitleTitle(subtitle)).tag(Optional(subtitle))
                    }
                }
                Picker("Subtitle file", selection: $model.subtitleFormat) {
                    ForEach(MediaSubtitleFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .disabled(model.subtitle == nil)
            }
            Text(
                model.format.requiresReencoding
                    ? String(localized: "This format may require re-encoding when the source codec is incompatible.")
                    : String(localized: "Keeps source quality without re-encoding. Container merging may be required.")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .disabled(model.isAnalyzing)
    }

    private static func formatTitle(_ format: MediaDownloadFormat) -> String {
        switch format {
        case .source: String(localized: "Best video (original format)")
        case .audio: String(localized: "Original audio")
        default: format.rawValue.uppercased()
        }
    }

    private static func subtitleTitle(_ subtitle: MediaSubtitle) -> String {
        let language = Locale.current.localizedString(forLanguageCode: subtitle.language) ?? subtitle.language
        return subtitle.automatic
            ? String(localized: "\(language) (automatic)")
            : String(localized: "\(language) (authored)")
    }

    private static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
