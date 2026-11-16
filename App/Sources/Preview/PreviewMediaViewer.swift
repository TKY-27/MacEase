import AVKit
import Engine
import Observation
import SwiftUI
import os

@MainActor
@Observable
private final class PreviewPlayback {
    var player: AVPlayer?
    var waveform: AudioWaveformSnapshot?
    var failed = false
    var waveformFailed = false
    var speed: Float = 1 {
        didSet {
            player?.defaultRate = speed
            if let player, player.rate != 0 { player.rate = speed }
        }
    }
    var current = 0.0
    var loopStart: Double?
    var loopEnd: Double?
    var canStepForward = false
    var canStepBackward = false
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var loopTask: Task<Void, Never>?
    private var loopRevision = 0

    func load(_ url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let playable = try await withTaskCancellationHandler {
                try await asset.load(.isPlayable)
            } onCancel: {
                asset.cancelLoading()
            }
            guard playable else { throw CocoaError(.fileReadUnsupportedScheme) }
            try Task.checkCancellation()
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.defaultRate = speed
            self.player = player
            periodicObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            Logger(category: "finder-preview").error(
                "Preview media failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func loadWaveform(_ url: URL) async {
        do {
            let snapshot = try await AudioWaveform.load(url: url, bins: 1024)
            try Task.checkCancellation()
            waveform = snapshot
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            waveformFailed = true
            Logger(category: "finder-preview").error(
                "Preview waveform failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func step(_ count: Int) {
        loopTask?.cancel()
        player?.pause()
        player?.currentItem?.step(byCount: count)
    }

    func setStart() {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return }
        clearLoop()
        loopStart = seconds
    }

    func setEnd() {
        guard let player, let loopStart, let seconds = player.currentItem?.currentTime().seconds,
            seconds.isFinite, seconds > loopStart
        else { return }
        removeBoundary()
        loopEnd = seconds
        let revision = loopRevision
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            Task { @MainActor in
                guard let self, revision == self.loopRevision else { return }
                self.repeatLoop(resume: true)
            }
        }
        repeatLoop(resume: player.rate != 0)
    }

    func clearLoop() {
        removeBoundary()
        loopStart = nil
        loopEnd = nil
    }

    private func removeBoundary() {
        loopRevision += 1
        loopTask?.cancel()
        loopTask = nil
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    private func repeatLoop(resume: Bool) {
        guard let player, let loopStart, loopEnd != nil else { return }
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            let completed = await player.seek(
                to: CMTime(seconds: loopStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard completed, !Task.isCancelled, let self, self.player === player else { return }
            if resume { player.playImmediately(atRate: speed) }
        }
    }

    private func refresh() {
        guard let player, let clip = player.currentItem else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { current = seconds }
        canStepForward = clip.canStepForward
        canStepBackward = clip.canStepBackward
        if clip.status == .failed {
            failed = true
            stop()
        }
    }

    func stop() {
        clearLoop()
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        waveform = nil
    }
}

struct PreviewMediaViewer: View {
    let url: URL
    let audioOnly: Bool
    @State private var playback = PreviewPlayback()
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 0) {
            if playback.failed {
                PreviewFailure()
            } else if let player = playback.player {
                PreviewPlayer(player: player)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if audioOnly {
                if let waveform = playback.waveform {
                    Canvas { context, size in
                        var path = Path()
                        let middle = size.height / 2
                        for (index, amplitude) in waveform.peaks.enumerated() {
                            let x = CGFloat(index) / CGFloat(max(1, waveform.peaks.count - 1)) * size.width
                            let height = CGFloat(min(1, amplitude)) * middle
                            path.move(to: CGPoint(x: x, y: middle - height))
                            path.addLine(to: CGPoint(x: x, y: middle + height))
                        }
                        context.stroke(path, with: .color(.secondary), lineWidth: 1)
                    }
                    .frame(height: 64).padding(.horizontal, 8).accessibilityLabel(Text("Waveform"))
                } else if playback.waveformFailed {
                    Text("Waveform unavailable").font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
            Divider()
            controls
        }
        .task { await playback.load(url) }
        .task { if audioOnly { await playback.loadWaveform(url) } }
        .onDisappear { playback.stop() }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Playback Speed", selection: $playback.speed) {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Text(verbatim: "\(speed.formatted())×").tag(speed)
                    }
                }
                .labelsHidden().accessibilityLabel(Text("Playback Speed"))
                if !audioOnly {
                    Button {
                        playback.step(-1)
                    } label: {
                        Image(systemName: "backward.frame")
                    }
                    .disabled(!playback.canStepBackward).accessibilityLabel(Text("Previous Frame"))
                    Button {
                        playback.step(1)
                    } label: {
                        Image(systemName: "forward.frame")
                    }
                    .disabled(!playback.canStepForward).accessibilityLabel(Text("Next Frame"))
                }
            }
            HStack {
                Button("Set A") { playback.setStart() }
                Button("Set B") { playback.setEnd() }
                    .disabled(playback.loopStart == nil || playback.current <= (playback.loopStart ?? 0))
                Button("Clear Loop") { playback.clearLoop() }.disabled(playback.loopStart == nil)
                Spacer(minLength: 0)
            }
            if let start = playback.loopStart {
                Text(
                    "A: \(start.formatted(.number.precision(.fractionLength(2)))) s · B: \(playback.loopEnd.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—") s"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(playback.player == nil)
        .controlSize(.small).padding(8)
    }
}

private struct PreviewPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
