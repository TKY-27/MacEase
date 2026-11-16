import AppKit
import Engine
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class MediaDownloadModel {
    typealias StartDownloads = (MediaDownloadRequest) throws -> (batchID: UUID, task: Task<BatchOutcome?, Never>)

    struct Download: Identifiable {
        let id = UUID()
        let selection: MediaDownloadSelection
        let destination: URL
        var batchID: UUID
        var index: Int
        var outcome: ItemOutcome?
    }

    enum DownloadStatus: Equatable {
        case queued
        case running(ItemPhase, fraction: Double?)
        case done([URL])
        case failed(String)
        case cancelled
    }

    var destination: URL
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
    var images = false {
        didSet {
            guard images != oldValue else { return }
            cancelAnalysis()
            thumbnailTask?.cancel()
            thumbnails = [:]
            sources = []
            selectedIDs = []
            failures = []
            error = nil
            resolution = nil
            subtitle = nil
        }
    }
    var resolution: Int?
    var audioBitrate: Int?
    var subtitle: MediaSubtitle?
    var subtitleFormat = MediaSubtitleFormat.vtt
    var selectedIDs: Set<String> = []
    private(set) var sources: [MediaSource] = []
    private(set) var failures: [MediaAnalysisFailure] = []
    private(set) var isAnalyzing = false
    private(set) var error: String?
    private(set) var thumbnails: [String: CGImage] = [:]
    private(set) var clipboardHasURL = false
    private(set) var downloads: [Download] = []
    private let tools: MediaDownloadTools?
    private var analysisTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private static let thumbnailConcurrency = 4
    private static let maximumThumbnails = 64
    private var generation = 0
    private var closed = false

    init(destination: URL, tools: MediaDownloadTools? = nil) {
        self.destination = destination
        self.tools = tools
    }

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

    var resolutionsDiffer: Bool {
        let candidates = selectedSources.isEmpty ? sources : selectedSources
        return candidates.count > 1 && resolutions.isEmpty && candidates.contains { !$0.resolutions.isEmpty }
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
                let downloader = try MediaDownloader(tools: tools)
                let analysis = try await downloader.analyze(urls: parsed, images: images)
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

    /// Results survive only unedited URLs.
    func submitURLs(_ start: StartDownloads) {
        if sources.isEmpty { analyze() } else { download(start) }
    }

    func download(_ start: StartDownloads) {
        guard canDownload else { return }
        normalizeOptions()
        let selections = selectedSources.map {
            MediaDownloadSelection(
                source: $0, format: format, resolution: isAudioOnly ? nil : resolution,
                subtitle: subtitle, subtitleFormat: subtitleFormat,
                audioBitrate: format.acceptsAudioBitrate ? audioBitrate : nil)
        }
        let request = MediaDownloadRequest(destination: destination, selections: selections)
        guard let batchID = track(request, start) else { return }
        downloads += selections.indices.map {
            Download(selection: selections[$0], destination: destination, batchID: batchID, index: $0)
        }
        urls = ""
    }

    func retry(_ id: Download.ID, progress: JobCenter.ActiveBatch? = nil, _ start: StartDownloads) {
        guard let position = downloads.firstIndex(where: { $0.id == id }),
            case .failed(let error) = outcome(of: downloads[position], progress: progress), error != .cancelled
        else { return }
        let download = downloads[position]
        let request = MediaDownloadRequest(destination: download.destination, selections: [download.selection])
        guard let batchID = track(request, start) else { return }
        downloads[position].batchID = batchID
        downloads[position].index = 0
        downloads[position].outcome = nil
    }

    private func track(_ request: MediaDownloadRequest, _ start: StartDownloads) -> UUID? {
        guard !closed else { return nil }
        do {
            let started = try start(request)
            Task { finish(started.batchID, outcome: await started.task.value) }
            return started.batchID
        } catch {
            self.error = UserMessages.describeActivity(error)
            return nil
        }
    }

    private func finish(_ batchID: UUID, outcome: BatchOutcome?) {
        for position in downloads.indices where downloads[position].batchID == batchID {
            let index = downloads[position].index
            downloads[position].outcome =
                outcome.flatMap { $0.outcomes.indices.contains(index) ? $0.outcomes[index] : nil }
                ?? .failed(.cancelled)
        }
    }

    private func outcome(of download: Download, progress: JobCenter.ActiveBatch?) -> ItemOutcome? {
        if let outcome = download.outcome { return outcome }
        guard let progress, progress.batchID == download.batchID,
            progress.itemOutcomes.indices.contains(download.index)
        else { return nil }
        return progress.itemOutcomes[download.index]
    }

    func status(of download: Download, progress: JobCenter.ActiveBatch?) -> DownloadStatus {
        let title = download.selection.source.title
        switch outcome(of: download, progress: progress) {
        case .succeeded(let outputs, _): return .done(outputs)
        case .failed(.cancelled): return .cancelled
        case .failed(let error): return .failed(UserMessages.describeResult(error, file: title))
        case .skipped(let reason): return .failed(UserMessages.describe(reason, file: title))
        case nil: break
        }
        let index = download.index
        guard let progress, progress.batchID == download.batchID,
            progress.itemPhases.indices.contains(index), progress.itemPhases[index] != .queued
        else { return .queued }
        let fraction = progress.stageFractions.indices.contains(index) ? progress.stageFractions[index] : nil
        return .running(progress.itemPhases[index], fraction: fraction)
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
    case video, audio, images

    var formats: [MediaDownloadFormat] {
        self == .images ? [.source] : MediaDownloadFormat.allCases.filter { $0.audioOnly == (self == .audio) }
    }
}

struct MediaDownloadView: View {
    @Bindable var model: MediaDownloadModel
    let close: () -> Void
    let start: MediaDownloadModel.StartDownloads
    let progress: (UUID) -> JobCenter.ActiveBatch?
    @FocusState private var urlsFocused: Bool

    private var kind: Binding<MediaDownloadKind> {
        Binding(
            get: { model.images ? .images : model.isAudioOnly ? .audio : .video },
            set: { kind in
                model.images = kind == .images
                guard !kind.formats.contains(model.format), let first = kind.formats.first else { return }
                model.format = first
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: model.isAnalyzing) { _, analyzing in if !analyzing { urlsFocused = true } }
        .onChange(of: model.selectedIDs) { model.normalizeOptions() }
    }

    private var urlBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Media Type", selection: kind) {
                Text("Video").tag(MediaDownloadKind.video)
                Text("Audio Only").tag(MediaDownloadKind.audio)
                Text("Images").tag(MediaDownloadKind.images)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isAnalyzing)
            HStack(alignment: .top, spacing: 10) {
                TextField(
                    model.images
                        ? String(localized: "Paste image gallery URLs")
                        : String(localized: "Paste video or playlist URLs"),
                    text: $model.urls, axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($urlsFocused)
                .disabled(model.isAnalyzing)
                .onSubmit { model.submitURLs(start) }
                .accessibilityLabel(Text("URLs, one per line"))
                if model.isAnalyzing {
                    Button("Stop Analysis") { model.cancelAnalysis() }
                        .controlSize(.large)
                } else {
                    Button("Analyze") { model.analyze() }
                        .controlSize(.large)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(String(localized: "Analyze Links (⌘R)"))
                        .disabled(!model.canAnalyze)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if !model.sources.isEmpty {
            results
        } else if model.isAnalyzing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Analyzing…").foregroundStyle(.secondary)
            }
        } else if !model.downloads.isEmpty {
            downloadList
        } else {
            ContentUnavailableView {
                Label(
                    model.images
                        ? String(localized: "Paste or drop gallery links")
                        : String(localized: "Paste or drop video links"),
                    systemImage: "arrow.down.circle")
            } description: {
                problems
            } actions: {
                if model.clipboardHasURL, model.urls.isEmpty {
                    Button {
                        model.pasteClipboardURLs()
                    } label: {
                        Label("Paste Link from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder private var problems: some View {
        if !model.failures.isEmpty || model.error != nil {
            VStack(alignment: .leading, spacing: 6) {
                failureList
                if let error = model.error { ProblemLabel(text: error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var results: some View {
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
            problems.padding(16)
        }
    }

    private var downloadList: some View {
        VStack(spacing: 0) {
            Text("Downloads")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityAddTraits(.isHeader)
            List(model.downloads) { download in downloadRow(download) }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
            problems.padding(16)
        }
    }

    private func downloadRow(_ download: MediaDownloadModel.Download) -> some View {
        let status = model.status(of: download, progress: progress(download.batchID))
        return HStack(spacing: 12) {
            statusSymbol(status)
            VStack(alignment: .leading, spacing: 4) {
                Text(download.selection.source.title).lineLimit(1).truncationMode(.middle)
                    .help(download.selection.source.title)
                switch status {
                case .queued:
                    Text(UserMessages.describe(ItemPhase.queued)).font(.caption).foregroundStyle(.secondary)
                case .running(let phase, let fraction):
                    HStack(spacing: 8) {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                            .accessibilityLabel(Text(download.selection.source.title))
                        Text(UserMessages.describe(phase)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                case .done:
                    Text(String(localized: "Done.", comment: "Activity status"))
                        .font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                        .help(message)
                case .cancelled:
                    Text(String(localized: "Cancelled.", comment: "Activity status"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            switch status {
            case .done(let outputs):
                Button(String(localized: "Show in Finder", comment: "Activity button")) {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            case .failed:
                Button(String(localized: "Retry")) {
                    model.retry(download.id, progress: progress(download.batchID), start)
                }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func statusSymbol(_ status: MediaDownloadModel.DownloadStatus) -> some View {
        Group {
            switch status {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .running: Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .font(.title3)
        .frame(width: 24)
        .accessibilityHidden(true)
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
                    Image(systemName: source.galleryCount == nil ? "play.rectangle" : "photo.on.rectangle")
                        .font(.title2).foregroundStyle(.secondary)
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
        .contextMenu {
            Link("Open Source Page", destination: source.webpageURL)
        }
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

    @ViewBuilder private var options: some View {
        if model.images {
            Text("Original images are saved in a new folder with a source record. Select galleries before downloading.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 16) {
                    option(String(localized: "Format")) {
                        Picker("Format", selection: $model.format) {
                            let formats = kind.wrappedValue.formats
                            Section("No Re-encoding") {
                                ForEach(formats.filter { !$0.requiresReencoding }, id: \.self) { format in
                                    Text(Self.formatTitle(format)).tag(format)
                                }
                            }
                            Section("Converts If Needed") {
                                ForEach(formats.filter(\.requiresReencoding), id: \.self) { format in
                                    Text(Self.formatTitle(format)).tag(format)
                                }
                            }
                        }
                        .fixedSize()
                    }
                    if model.format.acceptsAudioBitrate {
                        option(String(localized: "Quality")) {
                            Picker("Quality", selection: $model.audioBitrate) {
                                Text("Standard").tag(nil as Int?)
                                ForEach(MediaDownloadSelection.audioBitrates.filter { $0 != 192 }, id: \.self) {
                                    Text("\($0) kbps").tag(Optional($0))
                                }
                            }
                            .fixedSize()
                            .help(String(localized: "Applies when the audio is converted."))
                        }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        model.format.requiresReencoding
                            ? String(
                                localized: "This format may require re-encoding when the source codec is incompatible.")
                            : String(
                                localized:
                                    "Keeps source quality without re-encoding. Container merging may be required.")
                    )
                    if !model.isAudioOnly, model.resolutionsDiffer {
                        Text("The selected items share no resolution, so each downloads at its best.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(model.isAnalyzing)
            .padding(16)
        }
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
            Button(String(localized: "Choose…", comment: "Choose a download folder")) { chooseDestination() }
                .accessibilityLabel(Text("Choose Download Folder"))
            Spacer()
            Button(
                model.downloads.isEmpty
                    ? String(localized: "Cancel", comment: "Panel button")
                    : String(localized: "Close", comment: "Panel button"),
                action: close
            )
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Download")) {
                model.download(start)
                urlsFocused = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canDownload)
        }
        .padding(16)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.destination
        panel.prompt = String(localized: "Choose", comment: "Download folder panel button")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.destination = folder
    }

    private static func formatTitle(_ format: MediaDownloadFormat) -> String {
        switch format {
        case .source, .audio: String(localized: "Original Format")
        case .webm: "WebM"
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
        if let count = source.galleryCount {
            details.append(String(localized: "\(count) images"))
        } else if source.isPlaylistEntry {
            details.append(String(localized: "Playlist entry"))
        }
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
