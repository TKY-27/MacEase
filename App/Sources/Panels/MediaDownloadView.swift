import AppKit
import Engine
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class MediaDownloadModel {
    let destination: URL
    var urls = "" {
        didSet {
            guard urls != oldValue else { return }
            cancelAnalysis()
            thumbnailTask?.cancel()
            thumbnails = [:]
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
    private(set) var thumbnails: [String: CGImage] = [:]
    private(set) var clipboardHasURL = false
    private var analysisTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private static let thumbnailConcurrency = 4
    private static let maximumThumbnails = 64
    private var generation = 0
    private var closed = false

    init(destination: URL) { self.destination = destination }

    var selectedSources: [MediaSource] { sources.filter { selectedIDs.contains($0.id) } }
    var isAudioOnly: Bool { format.audioOnly }
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

    func resolutionTitle(_ height: Int) -> String {
        let candidates = selectedSources.isEmpty ? sources : selectedSources
        let widths = Set(candidates.flatMap(\.videoDimensions).filter { $0.height == height }.map(\.width))
        if widths.count == 1, let width = widths.first { return "\(width) × \(height)" }
        return "\(height)p"
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
                loadThumbnails(analysis.sources)
            } catch is CancellationError {
                if generation == expected { isAnalyzing = false }
            } catch {
                guard !closed, generation == expected else { return }
                self.error = UserMessages.describeActivity(error)
                isAnalyzing = false
            }
        }
    }

    private func loadThumbnails(_ sources: [MediaSource]) {
        thumbnailTask?.cancel()
        let pending = sources.prefix(Self.maximumThumbnails).compactMap { source in
            source.thumbnailURL.map { (source.id, $0) }
        }
        thumbnailTask = Task {
            await withTaskGroup(of: (String, CGImage?).self) { group in
                var iterator = pending.makeIterator()
                func enqueue() {
                    guard let (id, url) = iterator.next() else { return }
                    group.addTask {
                        do {
                            return (id, try await MediaDownloader.thumbnail(at: url))
                        } catch {
                            Logger(category: "downloads").info(
                                "Thumbnail unavailable: \(error.localizedDescription, privacy: .private)")
                            return (id, nil)
                        }
                    }
                }
                for _ in 0..<Self.thumbnailConcurrency { enqueue() }
                while let (id, image) = await group.next() {
                    guard !closed, !Task.isCancelled else { group.cancelAll(); return }
                    if let image { thumbnails[id] = image }
                    enqueue()
                }
            }
        }
    }

    /// Detection reveals no clipboard contents.
    func checkClipboard(_ name: NSPasteboard.Name = .general) async {
        guard urls.isEmpty else { return }
        let probableURL = \NSPasteboard.DetectedValues.probableWebURL
        do {
            clipboardHasURL = try await NSPasteboard(name: name).detectedPatterns(for: [probableURL])
                .contains(probableURL)
        } catch {
            clipboardHasURL = false
            Logger(category: "downloads").info(
                "Clipboard detection failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func pasteClipboardURLs(_ name: NSPasteboard.Name = .general) {
        guard urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let text = NSPasteboard(name: name).string(forType: .string)
        else { return }
        clipboardHasURL = false
        urls = text
        analyze()
    }

    func addDroppedURLs(_ dropped: [URL]) {
        let accepted = dropped.filter { ["http", "https"].contains($0.scheme?.lowercased()) }
        guard !accepted.isEmpty, !isAnalyzing else { return }
        let existing = urls.trimmingCharacters(in: .whitespacesAndNewlines)
        urls = ([existing].filter { !$0.isEmpty } + accepted.map(\.absoluteString)).joined(separator: "\n")
        analyze()
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
        thumbnailTask?.cancel()
        await analysisTask?.value
        await thumbnailTask?.value
    }
}

enum MediaDownloadKind: CaseIterable {
    case video, audio

    var formats: [MediaDownloadFormat] { MediaDownloadFormat.allCases.filter { $0.audioOnly == (self == .audio) } }
}

struct MediaDownloadView: View {
    @Bindable var model: MediaDownloadModel
    let close: () -> Void
    let run: (MediaDownloadRequest) throws -> Void
    @FocusState private var urlsFocused: Bool

    private var kind: Binding<MediaDownloadKind> {
        Binding(
            get: { model.isAudioOnly ? .audio : .video },
            set: { kind in
                guard !kind.formats.contains(model.format), let first = kind.formats.first else { return }
                model.format = first
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            results.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            options
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .dropDestination(for: URL.self) { dropped, _ in
            model.addDroppedURLs(dropped)
        }
        .task { await model.checkClipboard() }
        .onAppear { urlsFocused = true }
        .onChange(of: model.selectedIDs) { model.normalizeOptions() }
    }

    private var urlBar: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField(
                String(localized: "Paste video or playlist URLs"), text: $model.urls, axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($urlsFocused)
            .disabled(model.isAnalyzing)
            .onSubmit { model.analyze() }
            .accessibilityLabel(Text("URLs, one per line"))
            if model.isAnalyzing {
                Button("Stop Analysis") { model.cancelAnalysis() }
                    .controlSize(.large)
            } else {
                Button("Analyze") { model.analyze() }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canAnalyze)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var results: some View {
        if model.sources.isEmpty {
            VStack(spacing: 12) {
                if model.isAnalyzing {
                    ProgressView()
                    Text("Analyzing…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Paste a URL and press Return").font(.title3.weight(.semibold))
                    Text("You can also drop links from a browser here.")
                        .foregroundStyle(.secondary)
                    Text("Public videos and audio. Live streams and sign-in are not supported.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if model.clipboardHasURL, model.urls.isEmpty {
                        Button {
                            model.pasteClipboardURLs()
                        } label: {
                            Label("Paste Link from Clipboard", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 6)
                    }
                }
                failureList
                if let error = model.error { ProblemLabel(text: error) }
            }
            .padding(24)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.selectedSources.count) of \(model.sources.count) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let allSelected = model.selectedIDs.count == model.sources.count
                    Button(allSelected ? String(localized: "Clear Selection") : String(localized: "Select All")) {
                        model.selectedIDs = allSelected ? [] : Set(model.sources.map(\.id))
                    }
                    .buttonStyle(.link)
                    .disabled(model.isAnalyzing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                List(model.sources) { source in sourceRow(source) }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds(.disabled)
                if !model.failures.isEmpty || model.error != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        failureList
                        if let error = model.error { ProblemLabel(text: error) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
    }

    private func sourceRow(_ source: MediaSource) -> some View {
        let selected = Binding(
            get: { model.selectedIDs.contains(source.id) },
            set: {
                if $0 { model.selectedIDs.insert(source.id) } else { model.selectedIDs.remove(source.id) }
            })
        return HStack(spacing: 12) {
            Toggle(isOn: selected) { Text("Download \(source.title)") }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Group {
                if let thumbnail = model.thumbnails[source.id] {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "play.rectangle").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 36)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title).lineLimit(1).truncationMode(.middle).help(source.title)
                Text(Self.details(source).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selected.wrappedValue.toggle() }
        .disabled(model.isAnalyzing)
    }

    @ViewBuilder private var failureList: some View {
        if !model.failures.isEmpty {
            DisclosureGroup(String(localized: "URLs that could not be analyzed")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.failures.enumerated()), id: \.offset) { _, failure in
                            Text(
                                "\(failure.url.host() ?? "") — \(String(localized: String.LocalizationValue(failure.message)))"
                            )
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

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 16) {
                option(String(localized: "Media Type")) {
                    Picker("Media Type", selection: kind) {
                        Text("Video").tag(MediaDownloadKind.video)
                        Text("Audio Only").tag(MediaDownloadKind.audio)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                option(String(localized: "Format")) {
                    Picker("Format", selection: $model.format) {
                        ForEach(kind.wrappedValue.formats, id: \.self) { format in
                            Text(Self.formatTitle(format)).tag(format)
                        }
                    }
                    .fixedSize()
                }
                if !model.isAudioOnly {
                    option(String(localized: "Resolution")) {
                        Picker("Resolution", selection: $model.resolution) {
                            Text("Best available").tag(nil as Int?)
                            ForEach(model.resolutions, id: \.self) { resolution in
                                Text(model.resolutionTitle(resolution)).tag(Optional(resolution))
                            }
                        }
                        .fixedSize()
                        .disabled(model.sources.isEmpty)
                    }
                }
                option(String(localized: "Subtitles")) {
                    HStack(spacing: 6) {
                        Picker("Subtitles", selection: $model.subtitle) {
                            Text("Off").tag(nil as MediaSubtitle?)
                            ForEach(model.subtitles, id: \.self) { subtitle in
                                Text(Self.subtitleTitle(subtitle)).tag(Optional(subtitle))
                            }
                        }
                        .fixedSize()
                        .disabled(model.subtitles.isEmpty)
                        if model.subtitle != nil {
                            Picker("Subtitle file", selection: $model.subtitleFormat) {
                                ForEach(MediaSubtitleFormat.allCases, id: \.self) { format in
                                    Text(format.rawValue.uppercased()).tag(format)
                                }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .labelsHidden()
            Text(
                model.format.requiresReencoding
                    ? String(localized: "This format may require re-encoding when the source codec is incompatible.")
                    : String(localized: "Keeps source quality without re-encoding. Container merging may be required.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .disabled(model.isAnalyzing)
        .padding(16)
    }

    private func option<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            control()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label {
                Text(model.destination.displayName).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
            }
            .help(model.destination.path(percentEncoded: false))
            .accessibilityLabel(Text("Save to \(model.destination.displayName)"))
            Spacer()
            Button(String(localized: "Cancel", comment: "Panel button"), action: close)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Download")) {
                if model.submit(run) { close() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canDownload)
        }
        .padding(16)
    }

    private static func formatTitle(_ format: MediaDownloadFormat) -> String {
        switch format {
        case .source: String(localized: "Original format (no re-encoding)")
        case .audio: String(localized: "Original audio (no re-encoding)")
        default: format.rawValue.uppercased()
        }
    }

    private static func subtitleTitle(_ subtitle: MediaSubtitle) -> String {
        let language = Locale.current.localizedString(forLanguageCode: subtitle.language) ?? subtitle.language
        return subtitle.automatic
            ? String(localized: "\(language) (automatic)")
            : String(localized: "\(language) (authored)")
    }

    private static func details(_ source: MediaSource) -> [String] {
        var details = [source.webpageURL.host() ?? source.webpageURL.absoluteString]
        if let duration = duration(source.duration) { details.append(duration) }
        if let largest = source.videoDimensions.max(by: { $0.height < $1.height }) {
            details.append("\(largest.width) × \(largest.height)")
        }
        if source.isPlaylistEntry { details.append(String(localized: "Playlist entry")) }
        return details
    }

    private static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
