import AVFoundation
import AVKit
import Engine
import SwiftUI
import os

enum LoadedMedia {
    case player(AVPlayer, duration: Double)
    case frames(MediaPreview, [CGImage])

    private static let stripCount = 20
    private static let slotMiddle = 0.5
    /// Twice the drawn width for Retina screens.
    private static let stripFrameWidth = 64
    private static let statusPollInterval = Duration.milliseconds(50)
    /// AVKit FLAC trimming stalled the main queue.
    private static let playerExtensions: Set<String> = [
        "mp4", "mov", "m4v", "m4a", "aac", "mp3", "wav", "aif", "aiff", "caf",
    ]

    var duration: Double {
        switch self {
        case .player(_, let duration): duration
        case .frames(let preview, _): preview.durationSeconds
        }
    }

    static func load(_ url: URL) async throws -> LoadedMedia {
        try OperationPlanner.validateInput(url)
        if playerExtensions.contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            if playable {
                let playerItem = AVPlayerItem(asset: asset)
                // Items load only once attached.
                let player = AVPlayer(playerItem: playerItem)
                // The KVO publisher never delivered readiness.
                while playerItem.status == .unknown { try await Task.sleep(for: statusPollInterval) }
                if playerItem.status == .readyToPlay { return .player(player, duration: duration.seconds) }
            }
        }
        let preview = try await MediaPreview(videoAt: url)
        let times = (0..<stripCount).map {
            preview.durationSeconds * (Double($0) + slotMiddle) / Double(stripCount)
        }
        return .frames(preview, try await preview.frames(at: times, width: stripFrameWidth))
    }
}

struct MediaLoader<Content: View>: View {
    let url: URL
    let close: () -> Void
    @ViewBuilder let content: (LoadedMedia) -> Content

    @State private var media: LoadedMedia?
    @State private var failure: String?

    var body: some View {
        Group {
            if let media {
                content(media)
            } else if let failure {
                PanelFailure(message: failure, close: close)
            } else {
                ProgressView()
                    .padding()
                    .frame(width: PanelLayout.width)
            }
        }
        .task {
            do {
                media = try await LoadedMedia.load(url)
            } catch {
                failure = UserMessages.describe(
                    EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
            }
        }
    }
}

enum MediaLayout {
    static let videoHeight: CGFloat = 340
    static let stripHeight: CGFloat = 40
    static let previewHeight: CGFloat = 240
    static let playheadWidth: CGFloat = 2
}

struct SecondsField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
        }
    }
}

struct FrameStrip: View {
    let frames: [CGImage]
    let duration: Double
    var highlight: ClosedRange<Double>?
    var playhead: Double?

    var body: some View {
        // Frames must never widen the panel.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: MediaLayout.stripHeight)
            .overlay {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { index in
                        Image(decorative: frames[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: MediaLayout.stripHeight)
                            .clipped()
                    }
                }
            }
            .clipped()
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    if let highlight, duration > 0 {
                        Rectangle()
                            .strokeBorder(.tint, lineWidth: MediaLayout.playheadWidth)
                            .frame(width: width * (highlight.upperBound - highlight.lowerBound) / duration)
                            .offset(x: width * highlight.lowerBound / duration)
                    }
                    if let playhead, duration > 0 {
                        Rectangle()
                            .fill(.tint)
                            .frame(width: MediaLayout.playheadWidth)
                            .offset(x: width * min(playhead / duration, 1))
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

struct FramePickerPanel: View {
    let url: URL
    let close: () -> Void
    let run: (_ seconds: Double) -> Void

    var body: some View {
        MediaLoader(url: url, close: close) { media in
            switch media {
            case .player(let player, _):
                PanelForm(
                    actionTitle: String(localized: "Use This Frame", comment: "Frame picker action"),
                    width: PanelLayout.wideWidth, cancel: close
                ) {
                    run(player.currentTime().seconds)
                } content: {
                    PlainPlayer(player: player)
                        .frame(height: MediaLayout.videoHeight)
                }
            default:
                StripFramePicker(media: media, cancel: close, run: run)
            }
        }
    }
}

struct PlainPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct StripFramePicker: View {
    let media: LoadedMedia
    let cancel: () -> Void
    let run: (_ seconds: Double) -> Void

    @State private var seconds = 0.0
    @State private var still: CGImage?
    @State private var stillFailed = false

    private static let previewWidth = 960

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Use This Frame", comment: "Frame picker action"),
            canRun: (0...media.duration).contains(seconds), width: PanelLayout.wideWidth, cancel: cancel
        ) {
            run(seconds)
        } content: {
            Group {
                if let still {
                    Image(decorative: still, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if stillFailed {
                    Text("No preview available.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: MediaLayout.previewHeight)
            if case .frames(_, let frames) = media {
                FrameStrip(frames: frames, duration: media.duration, playhead: seconds)
            }
            Slider(value: $seconds, in: 0...max(media.duration, 0)) { Text("Position") }
            SecondsField(title: String(localized: "Time (seconds)", comment: "Frame picker field"), value: $seconds)
        }
        .task(id: seconds) {
            guard case .frames(let preview, _) = media else { return }
            do {
                still = try await preview.frames(at: [seconds], width: Self.previewWidth).first
                stillFailed = false
            } catch is CancellationError {
                return
            } catch {
                let failure = error as NSError
                Logger(category: "panels").error(
                    "Frame preview failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                )
                still = nil
                stillFailed = true
            }
        }
    }
}
