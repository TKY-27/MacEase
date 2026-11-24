import AVKit
import Engine
import SwiftUI
import os

enum PreviewMediaAsset {
    enum Playability {
        case playable(AVURLAsset)
        case unplayable
        case forbiddenReference
    }

    static var forbiddenReferenceMessage: String {
        String(localized: "This file references external media, so MacEase won't open it.")
    }

    // Blocks QuickTime reference movies reading other files.
    static func make(_ url: URL) -> AVURLAsset {
        AVURLAsset(
            url: url,
            options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    static func checkPlayability(_ url: URL) async throws -> Playability {
        let asset = make(url)
        do {
            let playable = try await withTaskCancellationHandler {
                try await asset.load(.isPlayable)
            } onCancel: {
                asset.cancelLoading()
            }
            return playable ? .playable(asset) : .unplayable
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isReferenceForbidden(error) { return .forbiddenReference }
            throw error
        }
    }

    static func isReferenceForbidden(_ error: (any Error)?) -> Bool {
        var current = error as NSError?
        while let candidate = current {
            if candidate.domain == AVFoundationErrorDomain,
                candidate.code == AVError.Code.referenceForbiddenByReferencePolicy.rawValue
            {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

@MainActor
@Observable
final class PreviewPlayback {
    enum Phase: Equatable {
        case loading, playing, convertible
        case converting(Double?)
        case message(String)
        case failed
    }

    private enum Source {
        case video(VideoEditorSource)
        case audio(AudioPreviewSource)

        func playbackURL(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            switch self {
            case .video(let source):
                try await source.playbackURL(sdr: false, normalized: source.details.hasAlpha, progress: progress)
            case .audio(let source): try await source.playbackURL()
            }
        }

        func close() async {
            switch self {
            case .video(let source): await source.close()
            case .audio(let source): await source.close()
            }
        }
    }

    private(set) var phase = Phase.loading
    private(set) var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var source: Source?
    private var conversion: Task<Void, Never>?
    private let logger = Logger(category: "finder-preview")

    func load(_ url: URL, audioOnly: Bool, detected: DetectedContent?, restricted: Bool, staging: StagingArea) async {
        let playability: PreviewMediaAsset.Playability
        do {
            playability = try await PreviewMediaAsset.checkPlayability(url)
        } catch is CancellationError {
            return
        } catch {
            logger.notice("AVFoundation cannot open the file: \(error.localizedDescription, privacy: .private)")
            playability = .unplayable
        }
        guard !Task.isCancelled else { return }
        if case .forbiddenReference = playability {
            phase = .message(PreviewMediaAsset.forbiddenReferenceMessage)
            return
        }
        let playableAsset: AVURLAsset? =
            if case .playable(let asset) = playability { asset } else { nil }
        guard let detected else {
            return if let playableAsset { play(playableAsset) } else { fail("no detected content") }
        }
        switch PreviewPlaybackDecision.evaluate(
            role: audioOnly ? .audio : .video, isPlayable: playableAsset != nil, detected: detected,
            restricted: restricted)
        {
        case .playable:
            if let playableAsset { play(playableAsset) } else { fail("playable asset missing") }
        case .convertible: await prepareConversion(url, audioOnly: audioOnly, staging: staging)
        case .refused(.restricted):
            phase = .message(
                String(
                    localized:
                        "This file is from the internet, so MacEase doesn't convert it. Open it in a media player."))
        case .refused(.contentMismatch), .refused(.emptyFile): fail("content does not match the file kind")
        }
    }

    // Surfaces unsupported codecs before offering conversion.
    private func prepareConversion(_ url: URL, audioOnly: Bool, staging: StagingArea) async {
        do {
            let opened: Source =
                audioOnly
                ? .audio(try await AudioPreviewSource.openForPreviewPlayback(url, staging: staging))
                : .video(try await VideoEditorSource.openForPreviewPlayback(url, staging: staging))
            guard !Task.isCancelled else { return await opened.close() }
            source = opened
            phase = .convertible
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Preview conversion unavailable: \(error.localizedDescription, privacy: .private)")
            phase = .message(
                UserMessages.describe(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent))
        }
    }

    func convert(_ url: URL) {
        guard let source, phase == .convertible else { return }
        phase = .converting(nil)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progressed(fraction) }
        }
        conversion = Task { [weak self] in
            do {
                let playback = try await source.playbackURL(progress: report)
                try Task.checkCancellation()
                self?.play(PreviewMediaAsset.make(playback))
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                logger.error("Preview conversion failed: \(error.localizedDescription, privacy: .private)")
                phase = .message(
                    UserMessages.describe(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent))
            }
        }
    }

    private func progressed(_ fraction: Double) {
        guard case .converting = phase else { return }
        phase = .converting(fraction)
    }

    private func play(_ asset: AVURLAsset) {
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            let reason = error?.localizedDescription ?? ""
            let forbidden = PreviewMediaAsset.isReferenceForbidden(error)
            Task { @MainActor in
                if forbidden {
                    self?.stopPlayer()
                    self?.phase = .message(PreviewMediaAsset.forbiddenReferenceMessage)
                } else {
                    self?.fail(reason)
                }
            }
        }
        player = AVPlayer(playerItem: item)
        phase = .playing
    }

    private func fail(_ reason: String) {
        stopPlayer()
        phase = .failed
        logger.error("Preview media failed: \(reason, privacy: .private)")
    }

    private func stopPlayer() {
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    // The staged copy goes with the selection.
    func stop() {
        conversion?.cancel()
        conversion = nil
        stopPlayer()
        guard let source else { return }
        self.source = nil
        Task { await source.close() }
    }
}

struct PreviewMediaViewer: View {
    let url: URL
    let audioOnly: Bool
    let detected: DetectedContent?
    let restricted: Bool
    let staging: StagingArea
    @State private var playback = PreviewPlayback()
    private static let audioControlsWidth: CGFloat = 420
    private static let audioIconSize: CGFloat = 128
    private static let progressWidth: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {}
            Group {
                switch playback.phase {
                case .loading: ProgressView().controlSize(.small)
                case .playing:
                    if audioOnly { audio } else { video }
                case .convertible: convertible
                case .converting(let fraction): converting(fraction)
                case .message(let message): PreviewFailure(message: Text(message))
                case .failed: PreviewFailure()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: showsVideo ? .underPageBackgroundColor : .windowBackgroundColor))
        }
        .task {
            await playback.load(url, audioOnly: audioOnly, detected: detected, restricted: restricted, staging: staging)
        }
        .onDisappear { playback.stop() }
    }

    private var showsVideo: Bool { !audioOnly && playback.phase == .playing }

    @ViewBuilder private var video: some View {
        if let player = playback.player { PreviewPlayer(player: player) }
    }

    private var convertible: some View {
        VStack(spacing: 12) {
            Text("This format can't be played directly.").font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Convert and Play") { playback.convert(url) }
        }
        .padding(PreviewLayout.margin)
    }

    private func converting(_ fraction: Double?) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: fraction).frame(maxWidth: Self.progressWidth)
            Text("Converting…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(PreviewLayout.margin)
        .accessibilityElement(children: .combine)
    }

    private var audio: some View {
        VStack(spacing: PreviewLayout.margin) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                .frame(width: Self.audioIconSize, height: Self.audioIconSize)
                .accessibilityHidden(true)
            if let player = playback.player {
                PreviewAudioControls(player: player).frame(maxWidth: Self.audioControlsWidth)
            }
        }
        .padding(PreviewLayout.margin)
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

// AVPlayerView draws a dark backdrop for audio.
private struct PreviewAudioControls: View {
    let player: AVPlayer
    @State private var playing = false
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var observer: Any?
    private static let updateInterval = CMTime(value: 1, timescale: 10)
    private static let hourSeconds = 3600.0
    private static let minimumDuration = 0.01
    private static let playButtonSize: CGFloat = 28
    private static let seekTimescale: CMTimeScale = 600

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3).foregroundStyle(.primary)
                    .frame(width: Self.playButtonSize, height: Self.playButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? Text("Pause") : Text("Play"))
            Text(verbatim: Self.format(position)).accessibilityHidden(true)
            Slider(value: $position, in: 0...max(duration, Self.minimumDuration)) { editing in
                scrubbing = editing
                if !editing { player.seek(to: CMTime(seconds: position, preferredTimescale: Self.seekTimescale)) }
            }
            .controlSize(.small)
            .accessibilityLabel(Text("Position"))
            .accessibilityValue(Text(verbatim: Self.format(position)))
            Text(verbatim: Self.format(duration)).accessibilityHidden(true)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .onAppear(perform: observe)
        .onDisappear(perform: stopObserving)
        .task { await loadDuration() }
    }

    private func toggle() {
        if playing {
            player.pause()
        } else {
            if duration > 0, position >= duration - Self.minimumDuration { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    private func observe() {
        observer = player.addPeriodicTimeObserver(forInterval: Self.updateInterval, queue: .main) { time in
            MainActor.assumeIsolated {
                playing = player.timeControlStatus != .paused
                if !scrubbing, time.seconds.isFinite { position = time.seconds }
            }
        }
    }

    private func stopObserving() {
        guard let observer else { return }
        player.removeTimeObserver(observer)
        self.observer = nil
    }

    private func loadDuration() async {
        guard let asset = player.currentItem?.asset else { return }
        do {
            let loaded = try await asset.load(.duration).seconds
            if loaded.isFinite { duration = loaded }
        } catch {
            Logger(category: "finder-preview").error(
                "Preview audio duration failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func format(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= hourSeconds ? .hourMinuteSecond : .minuteSecond))
    }
}
