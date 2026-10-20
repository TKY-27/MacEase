import AVFoundation
import AVKit
import Engine
import SwiftUI
import os

enum LoadedMedia {
    case player(AVPlayer, duration: Double)
    case frames(MediaPreview, [CGImage])
    case audio(duration: Double)

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
        case .player(_, let duration), .audio(let duration): duration
        case .frames(let preview, _): preview.durationSeconds
        }
    }

    static func load(_ url: URL, isVideo: Bool) async throws -> LoadedMedia {
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
        if isVideo {
            let preview = try await MediaPreview(videoAt: url)
            let times = (0..<stripCount).map {
                preview.durationSeconds * (Double($0) + slotMiddle) / Double(stripCount)
            }
            return .frames(preview, try await preview.frames(at: times, width: stripFrameWidth))
        }
        let duration = try await offMain { try AudioInput(url: url).duration }
        guard let duration else { throw EngineError.decodeFailed("unknown duration") }
        return .audio(duration: duration)
    }
}

private struct MediaLoader<Content: View>: View {
    let url: URL
    let isVideo: Bool
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
                media = try await LoadedMedia.load(url, isVideo: isVideo)
            } catch {
                failure = UserMessages.describe(
                    EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
            }
        }
    }
}

struct TrimPanel: View {
    let url: URL
    let isVideo: Bool
    /// Seconds to preselect, such as LINE's limit.
    let prefill: ClosedRange<Double>?
    @State var mode: TrimMode
    let close: () -> Void
    let run: (_ start: Double, _ end: Double, TrimMode) -> Void

    var body: some View {
        MediaLoader(url: url, isVideo: isVideo, close: close) { media in
            switch media {
            case .player(let player, let duration):
                VStack(spacing: 0) {
                    if isVideo { modePicker.padding() }
                    TrimmingPlayer(player: player, prefill: prefill) { range in
                        guard let range else { return close() }
                        run(range.lowerBound, min(range.upperBound, duration), mode)
                    }
                    .frame(height: isVideo ? MediaLayout.videoHeight : MediaLayout.audioHeight)
                }
                .frame(width: PanelLayout.wideWidth)
            default:
                NumericTrim(media: media, prefill: prefill, isVideo: isVideo, mode: $mode, cancel: close, run: run)
            }
        }
    }

    private var modePicker: some View {
        Picker("Cut", selection: $mode) {
            ForEach(TrimMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

enum MediaLayout {
    static let videoHeight: CGFloat = 340
    static let audioHeight: CGFloat = 96
    static let stripHeight: CGFloat = 40
    static let previewHeight: CGFloat = 240
    static let playheadWidth: CGFloat = 2
}

/// For media AVKit cannot play.
private struct NumericTrim: View {
    let media: LoadedMedia
    let prefill: ClosedRange<Double>?
    let isVideo: Bool
    @Binding var mode: TrimMode
    let cancel: () -> Void
    let run: (_ start: Double, _ end: Double, TrimMode) -> Void

    @State private var start = 0.0
    @State private var end = 0.0

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Trim", comment: "Trim panel action"),
            canRun: 0 <= start && start < end && end <= media.duration, width: PanelLayout.wideWidth, cancel: cancel
        ) {
            run(start, end, mode)
        } content: {
            if case .frames(_, let frames) = media {
                FrameStrip(frames: frames, duration: media.duration, highlight: start...max(start, end))
            }
            SecondsField(title: String(localized: "Start (seconds)", comment: "Trim field"), value: $start)
            SecondsField(title: String(localized: "End (seconds)", comment: "Trim field"), value: $end)
            LabeledContent("Duration") {
                Text(Duration.seconds(media.duration), format: .time(pattern: .hourMinuteSecond))
            }
            if isVideo {
                Picker("Cut", selection: $mode) {
                    ForEach(TrimMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .onAppear {
            start = prefill?.lowerBound ?? 0
            end = min(prefill?.upperBound ?? media.duration, media.duration)
        }
    }
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

/// AVKit's trimming bar; `nil` means cancelled.
private struct TrimmingPlayer: NSViewRepresentable {
    let player: AVPlayer
    let prefill: ClosedRange<Double>?
    let finish: (ClosedRange<Double>?) -> Void

    func makeNSView(context: Context) -> TrimmingPlayerView {
        let view = TrimmingPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.prefill = prefill
        view.finish = finish
        return view
    }

    func updateNSView(_ view: TrimmingPlayerView, context: Context) {
        view.finish = finish
    }

    /// Closing mid-trim must stop playback.
    static func dismantleNSView(_ view: TrimmingPlayerView, coordinator: ()) {
        view.finish = nil
        view.player?.pause()
    }
}

private final class TrimmingPlayerView: AVPlayerView {
    var finish: ((ClosedRange<Double>?) -> Void)?
    var prefill: ClosedRange<Double>?
    private var hasBegun = false

    private static let timescale: CMTimeScale = 600

    /// Trimming needs a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasBegun else { return }
        hasBegun = true
        Task { @MainActor in
            // AVKit disables Trim for ranges set beforehand.
            if let prefill, let playerItem = player?.currentItem {
                Task { @MainActor in
                    playerItem.reversePlaybackEndTime = CMTime(
                        seconds: prefill.lowerBound, preferredTimescale: Self.timescale)
                    playerItem.forwardPlaybackEndTime = CMTime(
                        seconds: prefill.upperBound, preferredTimescale: Self.timescale)
                }
            }
            let result = await beginTrimming()
            player?.pause()
            guard result == .okButton, let playerItem = player?.currentItem else { return finish?(nil) ?? () }
            let start = playerItem.reversePlaybackEndTime.isNumeric ? playerItem.reversePlaybackEndTime.seconds : 0
            let end =
                playerItem.forwardPlaybackEndTime.isNumeric
                ? playerItem.forwardPlaybackEndTime.seconds : playerItem.duration.seconds
            finish?(start...max(start, end))
        }
    }
}

struct FramePickerPanel: View {
    let url: URL
    let close: () -> Void
    let run: (_ seconds: Double) -> Void

    var body: some View {
        MediaLoader(url: url, isVideo: true, close: close) { media in
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

private struct PlainPlayer: NSViewRepresentable {
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
