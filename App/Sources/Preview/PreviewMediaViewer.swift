import AVKit
import Engine
import SwiftUI
import os

@MainActor
@Observable
private final class PreviewPlayback {
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
        let playable: Bool
        do {
            playable = try await Self.isPlayable(url)
        } catch is CancellationError {
            return
        } catch {
            logger.notice("AVFoundation cannot open the file: \(error.localizedDescription, privacy: .private)")
            playable = false
        }
        guard !Task.isCancelled else { return }
        guard let detected else { return playable ? play(url) : fail("no detected content") }
        switch PreviewPlaybackDecision.evaluate(
            role: audioOnly ? .audio : .video, isPlayable: playable, detected: detected, restricted: restricted)
        {
        case .playable: play(url)
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
                ? .audio(try await AudioPreviewSource.open(url, staging: staging))
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
                self?.play(playback)
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

    private func play(_ url: URL) {
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? ""
            Task { @MainActor in self?.fail(reason) }
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

    private static func isPlayable(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try await asset.load(.isPlayable)
        } onCancel: {
            asset.cancelLoading()
        }
    }
}

struct PreviewMediaViewer: View {
    let url: URL
    let audioOnly: Bool
    let detected: DetectedContent?
    let restricted: Bool
    let staging: StagingArea
    @State private var playback = PreviewPlayback()
    private static let audioControlsHeight: CGFloat = 48
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
                PreviewPlayer(player: player).frame(height: Self.audioControlsHeight)
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
