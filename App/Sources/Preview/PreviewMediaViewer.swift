import AVKit
import SwiftUI
import os

@MainActor
@Observable
private final class PreviewPlayback {
    var player: AVPlayer?
    var failed = false
    private var statusObservation: NSKeyValueObservation?

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
            let item = AVPlayerItem(asset: asset)
            statusObservation = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let reason = item.error?.localizedDescription ?? ""
                Task { @MainActor in self?.fail(reason) }
            }
            player = AVPlayer(playerItem: item)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    private func fail(_ reason: String) {
        failed = true
        stop()
        Logger(category: "finder-preview").error("Preview media failed: \(reason, privacy: .private)")
    }

    func stop() {
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

struct PreviewMediaViewer: View {
    let url: URL
    let audioOnly: Bool
    @State private var playback = PreviewPlayback()
    private static let audioControlsHeight: CGFloat = 48
    private static let audioIconSize: CGFloat = 128

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {}
            Group {
                if playback.failed {
                    PreviewFailure()
                } else if audioOnly {
                    audio
                } else if let player = playback.player {
                    PreviewPlayer(player: player)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: audioOnly ? .windowBackgroundColor : .underPageBackgroundColor))
        }
        .task { await playback.load(url) }
        .onDisappear { playback.stop() }
    }

    private var audio: some View {
        VStack(spacing: PreviewLayout.margin) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                .frame(width: Self.audioIconSize, height: Self.audioIconSize)
                .accessibilityHidden(true)
            Group {
                if let player = playback.player {
                    PreviewPlayer(player: player)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: Self.audioControlsHeight)
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
