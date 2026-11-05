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
    @State private var model: AudioTrimModel
    let cancel: () -> Void
    let run: (Double, Double) -> Void

    init(
        url: URL, staging: StagingArea, prefill: ClosedRange<Double>?, cancel: @escaping () -> Void,
        run: @escaping (Double, Double) -> Void
    ) {
        _model = State(initialValue: AudioTrimModel(url: url, staging: staging, prefill: prefill))
        self.cancel = cancel; self.run = run
    }

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Trim"), canRun: model.canSave,
            width: PanelLayout.wideWidth, cancel: cancel
        ) {
            do { try model.validate(); run(model.start, model.end) } catch {
                model.failure = error.localizedDescription
            }
        } content: {
            HStack(spacing: 12) {
                Button {
                    model.play()
                } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                }.disabled(!model.ready).help(model.playing ? "Pause" : "Play")
                Text(model.position, format: .number.precision(.fractionLength(3))).monospacedDigit()
                Spacer(minLength: 6)
                TimelineZoomControls(zoom: $model.zoom, maximumZoom: model.maximumZoom)
            }.buttonStyle(.borderless)
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
            ).frame(height: 106)
            SecondsField(
                title: String(localized: "Start (seconds)"),
                value: Binding(
                    get: { model.start }, set: { model.changeRange(start: $0, end: model.end) }))
            SecondsField(
                title: String(localized: "End (seconds)"),
                value: Binding(
                    get: { model.end }, set: { model.changeRange(start: model.start, end: $0) }))
            HStack {
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Redo") { model.redo() }.disabled(!model.canRedo)
                Divider().frame(height: 14)
                Button("Set In") { model.setBoundary(start: true) }.disabled(!model.ready)
                    .help("Set In Point at Playhead (I)")
                Button("Set Out") { model.setBoundary(start: false) }.disabled(!model.ready)
                    .help("Set Out Point at Playhead (O)")
                Spacer()
                if !model.ready { ProgressView().controlSize(.small) }
                if let failure = model.failure { Text(failure).foregroundStyle(.red) }
            }
        }
        .background(EditorKeyboardShortcuts(audio: model).frame(width: 0, height: 0))
        .task { await model.load() }
        .onDisappear { Task { await model.close() } }
    }
}
