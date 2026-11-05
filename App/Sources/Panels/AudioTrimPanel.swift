import AVFoundation
import Engine
import Observation
import SwiftUI

@Observable @MainActor
final class AudioTrimModel {
    let url: URL
    private let staging: StagingArea
    private let prefill: ClosedRange<Double>?
    let clipID = UUID()
    var duration = 0.0
    var sampleRate = 0.0
    var start = 0.0
    var end = 0.0
    var position = 0.0
    var zoom = 1.0
    var viewportWidth = 600.0
    var playing = false
    var ready = false
    var failure: String?
    var waveform: AudioWaveformSnapshot?
    var detailWaveform: AudioWaveformSnapshot?
    private var source: AudioPreviewSource?
    private var stamp: MediaSourceStamp?
    private var player: AVPlayer?
    private var observer: Any?
    private var playbackEndObserver: (any NSObjectProtocol)?
    private var waveformTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var desiredSeek: Double?
    private var requestedRange: Range<Double>?
    private var detailGeneration = 0
    private var waveformComplete = false
    private var closed = false
    private var dragStart: ClosedRange<Double>?
    private var draggingStart = false
    private var undoRanges: [ClosedRange<Double>] = []
    private var redoRanges: [ClosedRange<Double>] = []
    var canUndo: Bool { !undoRanges.isEmpty }
    var canRedo: Bool { !redoRanges.isEmpty }
    var maximumZoom: Double {
        max(zoom, MediaTimeline.maximumZoom(duration: duration, viewport: viewportWidth, interval: 0.001))
    }
    var canSave: Bool { ready && !closed && failure == nil && start >= 0 && end > start && end <= duration }

    init(url: URL, staging: StagingArea, prefill: ClosedRange<Double>?) {
        self.url = url
        self.staging = staging
        self.prefill = prefill
    }

    func load() async {
        do {
            let source = try await AudioPreviewSource.open(url, staging: staging)
            self.source = source
            duration = await source.duration
            sampleRate = await source.sampleRate
            stamp = await source.stamp
            guard !closed, !Task.isCancelled else { await source.close(); return }
            start = rounded(prefill?.lowerBound ?? 0)
            end = rounded(min(prefill?.upperBound ?? duration, duration))
            position = start
            waveformTask = Task {
                do {
                    let result = try await AudioWaveform.load(url: url) { snapshot in
                        Task { @MainActor in
                            guard !self.closed, !self.waveformComplete else { return }
                            self.waveform = snapshot
                        }
                    }
                    try Task.checkCancellation()
                    guard !closed else { return }
                    waveformComplete = true
                    waveform = result
                } catch is CancellationError { return } catch { report(error) }
            }
            let address = try await source.playbackURL()
            try Task.checkCancellation()
            guard !closed else { await source.close(); return }
            let playerItem = AVPlayerItem(url: address)
            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.position = self.end
                    self.pause()
                }
            }
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.playing, self.player?.rate != 0, time.seconds.isFinite else { return }
                    self.position = min(self.end, time.seconds)
                    if self.position >= self.end { self.pause() }
                }
            }
            ready = true
            seek(start)
        } catch is CancellationError { await source?.close() } catch { report(error) }
    }

    func refineWaveform(_ range: Range<Double>) {
        guard !closed else { return }
        guard zoom > 2, duration > 0 else {
            detailTask?.cancel()
            if detailWaveform != nil { detailWaveform = nil }
            requestedRange = nil
            return
        }
        let margin = (range.upperBound - range.lowerBound) / 2
        let requested = max(0, range.lowerBound - margin)..<min(duration, range.upperBound + margin)
        if let requestedRange,
            requestedRange.lowerBound <= range.lowerBound, requestedRange.upperBound >= range.upperBound
        {
            return
        }
        requestedRange = requested
        detailTask?.cancel()
        detailGeneration += 1
        let generation = detailGeneration
        detailTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await AudioWaveform.load(url: url, range: requested, bins: 8_192)
                try Task.checkCancellation()
                guard !closed, generation == detailGeneration else { return }
                detailWaveform = result
            } catch is CancellationError { return } catch { report(error) }
        }
    }

    func rounded(_ seconds: Double) -> Double {
        guard seconds.isFinite, sampleRate > 0 else { return 0 }
        return min(duration, max(0, (seconds * sampleRate).rounded() / sampleRate))
    }

    func changeRange(start: Double, end: Double) {
        let left = rounded(start)
        let right = rounded(end)
        guard right > left else { return }
        let previous = self.start...self.end
        guard previous != left...right else { return }
        if dragStart == nil { remember(previous) }
        self.start = left; self.end = right
        pause()
    }

    func beginTrim(_ id: UUID, start: Bool) {
        guard id == clipID else { return }
        pause()
        dragStart = self.start...end
        draggingStart = start
    }

    func trim(to seconds: Double) {
        guard let original = dragStart else { return }
        if draggingStart {
            changeRange(start: min(seconds, original.upperBound - 1 / sampleRate), end: original.upperBound)
        } else {
            changeRange(start: original.lowerBound, end: max(seconds, original.lowerBound + 1 / sampleRate))
        }
    }

    func endTrim() {
        if let original = dragStart, original != start...end { remember(original) }
        dragStart = nil
    }

    func setBoundary(start: Bool) {
        if start {
            changeRange(start: min(position, end - 1 / sampleRate), end: end)
        } else {
            changeRange(start: self.start, end: max(position, self.start + 1 / sampleRate))
        }
    }

    private func remember(_ range: ClosedRange<Double>) {
        undoRanges.append(range)
        if undoRanges.count > 100 { undoRanges.removeFirst() }
        redoRanges.removeAll()
    }

    func undo() {
        endTrim()
        guard let previous = undoRanges.popLast() else { return }
        redoRanges.append(start...end)
        start = previous.lowerBound; end = previous.upperBound
        pause()
    }

    func redo() {
        guard let next = redoRanges.popLast() else { return }
        undoRanges.append(start...end)
        start = next.lowerBound; end = next.upperBound
        pause()
    }

    func seek(_ seconds: Double) {
        pause()
        position = rounded(seconds)
        desiredSeek = position
        guard seekTask == nil, let player else { return }
        seekTask = Task {
            defer { seekTask = nil }
            while let next = desiredSeek, !closed, !Task.isCancelled {
                desiredSeek = nil
                await player.seek(
                    to: CMTime(seconds: next, preferredTimescale: 1_000_000_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func play() {
        guard let player, ready else { return }
        if playing { pause(); return }
        if position < start || position >= end { seek(start) }
        playing = true
        playbackTask = Task {
            await seekTask?.value
            guard !closed, !Task.isCancelled else { return }
            player.play()
        }
    }

    func pause() { playbackTask?.cancel(); player?.pause(); playing = false }

    func validate() throws {
        guard canSave else { throw EngineError.invalidInput(.invalidNumericParameter) }
        try stamp?.validate(url)
    }

    private func report(_ error: any Error) {
        guard !closed else { return }
        failure = UserMessages.describe(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
    }

    func close() async {
        closed = true
        pause()
        waveformTask?.cancel(); detailTask?.cancel(); seekTask?.cancel()
        playbackTask?.cancel()
        player?.currentItem?.cancelPendingSeeks()
        if let observer { player?.removeTimeObserver(observer) }
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil
        observer = nil
        player?.replaceCurrentItem(with: nil); player = nil
        await waveformTask?.value; await detailTask?.value; await seekTask?.value
        await playbackTask?.value
        await source?.close()
        source = nil; waveform = nil; detailWaveform = nil
    }
}

struct AudioTrimPanel: View {
    @Bindable var model: AudioTrimModel
    let cancel: () -> Void
    let run: (Double, Double) -> Void
    @State private var startDraft = ""
    @State private var endDraft = ""

    private var draftsAreValid: Bool {
        [(startDraft, model.start), (endDraft, model.end)].allSatisfy { !TimecodeField.isInvalid($0, from: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            MediaTimeline(
                duration: max(model.duration, 0.001), position: model.position,
                clips: [
                    TimelineClip(
                        id: model.clipID, range: 0...max(0, model.duration),
                        selection: model.ready ? model.start...model.end : nil, label: "",
                        waveform: model.waveform, detailWaveform: model.detailWaveform)
                ],
                playing: model.playing, zoom: $model.zoom, maximumZoom: model.maximumZoom,
                seek: model.seek, hover: { _ in }, select: { _ in },
                beginTrim: model.beginTrim, trim: model.trim, endTrim: model.endTrim,
                visibleRange: { range in Task { @MainActor in model.refineWaveform(range) } },
                viewportChanged: { width in Task { @MainActor in model.viewportWidth = width } }
            )
            .frame(height: MediaTimeline.height)
            .accessibilityLabel(Text("Waveform"))
            .overlay {
                if !model.ready, model.failure == nil { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            transport
            Divider()
            rangeEditor
            Divider()
            footer
        }
        .frame(minWidth: 720)
        .background(.background)
        .preferredColorScheme(.dark)
        .background(EditorKeyboardShortcuts(audio: model).frame(width: 0, height: 0))
        .task { await model.load() }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            TransportClock(position: model.position, duration: model.duration)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                Button {
                    model.seek(model.start)
                } label: {
                    Label("Go to In Point", systemImage: "backward.end.fill")
                }
                .help("Go to In Point")
                Button {
                    model.play()
                } label: {
                    Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28, height: 28)
                }
                .help(model.playing ? "Pause (Space)" : "Play Selection (Space)")
                Button {
                    model.seek(model.end)
                } label: {
                    Label("Go to Out Point", systemImage: "forward.end.fill")
                }
                .help("Go to Out Point")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.ready)
            TimelineZoomControls(zoom: $model.zoom, maximumZoom: model.maximumZoom)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var rangeEditor: some View {
        HStack(spacing: 24) {
            boundary(
                String(localized: "Start"), value: model.start, draft: $startDraft, symbol: "arrow.right.to.line",
                help: String(localized: "Set In Point at Playhead (I)")
            ) {
                model.changeRange(start: $0, end: model.end)
            } setToPlayhead: {
                model.setBoundary(start: true)
            }
            boundary(
                String(localized: "End"), value: model.end, draft: $endDraft, symbol: "arrow.left.to.line",
                help: String(localized: "Set Out Point at Playhead (O)")
            ) {
                model.changeRange(start: model.start, end: $0)
            } setToPlayhead: {
                model.setBoundary(start: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Length").font(.caption).foregroundStyle(.secondary)
                Text(Timecode.string(max(0, model.end - model.start), fractionDigits: 3))
                    .font(.body.monospacedDigit())
                    .frame(height: 22)
            }
            Spacer()
            if let failure = model.failure { ProblemLabel(text: failure) }
        }
        .disabled(!model.ready)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func boundary(
        _ title: String, value: Double, draft: Binding<String>, symbol: String, help: String,
        set: @escaping (Double) -> Void, setToPlayhead: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TimecodeField(title: title, value: value, draft: draft, commit: set).frame(width: 104)
                Button(action: setToPlayhead) {
                    Label(help, systemImage: symbol)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(help)
            }
        }
    }

    private var footer: some View {
        HStack {
            ControlGroup {
                Button {
                    model.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .help("Undo (⌘Z)")
                .disabled(!model.canUndo)
                Button {
                    model.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .help("Redo (⇧⌘Z)")
                .disabled(!model.canRedo)
            }
            .fixedSize()
            Spacer()
            Button(String(localized: "Cancel", comment: "Panel button"), action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Trim")) {
                if let start = TimecodeField.edited(startDraft, from: model.start) {
                    model.changeRange(start: start, end: model.end)
                }
                if let end = TimecodeField.edited(endDraft, from: model.end) {
                    model.changeRange(start: model.start, end: end)
                }
                do { try model.validate(); run(model.start, model.end) } catch {
                    model.failure = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave || !draftsAreValid)
        }
        .padding(16)
    }
}

/// Accepts `m:ss.sss`, `h:mm:ss.sss` or plain seconds.
struct TimecodeField: View {
    private static let fractionDigits = 3

    let title: String
    let value: Double
    @Binding var draft: String
    let commit: (Double) -> Void
    @FocusState private var focused: Bool

    /// `nil` while the draft still shows `value`.
    static func edited(_ draft: String, from value: Double) -> Double? {
        draft == Timecode.string(value, fractionDigits: fractionDigits) ? nil : parse(draft)
    }

    static func isInvalid(_ draft: String, from value: Double) -> Bool {
        draft != Timecode.string(value, fractionDigits: fractionDigits) && parse(draft) == nil
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let seconds = Double(parts[parts.count - 1]), seconds >= 0 else {
            return nil
        }
        guard parts.count == 1 || seconds < 60 else { return nil }
        var minutes = 0.0
        for (index, part) in parts.dropLast().enumerated() {
            guard let unit = Int(part), unit >= 0, index == 0 || unit < 60 else { return nil }
            minutes = minutes * 60 + Double(unit)
        }
        let total = minutes * 60 + seconds
        return total.isFinite ? total : nil
    }

    var body: some View {
        TextField(title, text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .overlay {
                if Self.isInvalid(draft, from: value) {
                    RoundedRectangle(cornerRadius: 5).stroke(.red, lineWidth: 1).allowsHitTesting(false)
                }
            }
            .onAppear { synchronize() }
            .onChange(of: value) { _, _ in synchronize() }
            .onChange(of: focused) { _, focused in if !focused { submit() } }
            .onSubmit { submit() }
    }

    private func submit() {
        guard let seconds = Self.edited(draft, from: value) else { return }
        commit(seconds)
        synchronize()
    }

    private func synchronize() {
        draft = Timecode.string(value, fractionDigits: Self.fractionDigits)
    }
}
