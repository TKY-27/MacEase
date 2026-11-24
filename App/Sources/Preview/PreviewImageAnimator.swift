import CoreGraphics
import Observation
import os

@MainActor
@Observable
final class PreviewImageAnimator {
    private(set) var frame: CGImage
    private(set) var isPlaying = false
    private(set) var position = PreviewImageTiming.Position(index: 0, completedPlays: 0)
    private let source: PreviewImageSource
    private let timing: PreviewImageTiming
    private var playback: Task<Void, Never>?
    private var windowVisible = true
    private var resumeWhenVisible = false

    init(source: PreviewImageSource, first: CGImage, timing: PreviewImageTiming) {
        self.source = source
        self.timing = timing
        frame = first
    }

    // Restarts once the loop count is spent.
    func play() {
        guard !isPlaying else { return }
        guard windowVisible else {
            resumeWhenVisible = true
            return
        }
        resumeWhenVisible = false
        let restarts = timing.step(after: position) == nil
        isPlaying = true
        playback = Task { [weak self] in await self?.run(restarting: restarts) }
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func pause() {
        resumeWhenVisible = false
        stopPlayback()
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        if visible {
            if resumeWhenVisible { play() }
        } else if isPlaying {
            resumeWhenVisible = true
            stopPlayback()
        }
    }

    private func stopPlayback() {
        playback?.cancel()
        playback = nil
        isPlaying = false
    }

    private func run(restarting: Bool) async {
        defer {
            if !Task.isCancelled {
                isPlaying = false
                resumeWhenVisible = false
            }
        }
        do {
            if restarting {
                let first = try await source.frame(0)
                try Task.checkCancellation()
                frame = first
                position = PreviewImageTiming.Position(index: 0, completedPlays: 0)
            }
            while let next = timing.step(after: position) {
                async let decoded = source.frame(next.index)
                let delaySeconds = PreviewImageSource.clampedDelaySeconds(timing.delays[position.index])
                try await Task.sleep(for: .seconds(delaySeconds))
                let image = try await decoded
                try Task.checkCancellation()
                frame = image
                position = next
            }
        } catch is CancellationError {
        } catch {
            Logger(category: "finder-preview").error(
                "Preview animation stopped: \(error.localizedDescription, privacy: .private)")
        }
    }
}
