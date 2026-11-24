import Engine
import SwiftUI
import os

enum FrameNote: Equatable {
    case saved(URL)
    case failed(String)
}

extension MediaEditorModel {
    var canInsertFreezeFrame: Bool {
        guard !editingLocked, !splitting, let timeline, !values.segments.isEmpty else { return false }
        return !timeline.segment(at: position).isFreeze
    }

    /// Splits at the playhead; one Undo step.
    func insertFreezeFrame() {
        guard canInsertFreezeFrame, let timeline else { return }
        let segment = timeline.segment(at: position)
        guard let videoSource = source(for: segment) else { return }
        pause()
        let requestedPosition = position
        let generation = revision
        let seconds = timeline.sourceTime(at: position)
        let sourceDuration =
            values.sources.indices.contains(segment.sourceIndex)
            ? values.sources[segment.sourceIndex].duration : duration
        splitTask?.cancel()
        splitting = true
        splitTask = Task {
            defer { splitting = false }
            do {
                let next = try await videoSource.adjacentFrameTime(to: seconds, forward: true)
                let frameEnd = min(segment.end, next > seconds ? next : sourceDuration)
                let frameStart = max(
                    segment.start, try await videoSource.adjacentFrameTime(to: frameEnd, forward: false))
                try Task.checkCancellation()
                guard !closed, revision == generation, position == requestedPosition, frameStart < frameEnd,
                    let index = values.segments.firstIndex(where: { $0.id == segment.id }),
                    let freezeStart = timeline.outputTime(for: frameStart, segmentID: segment.id)
                else { return }
                let freeze = VideoSegment(
                    start: frameStart, end: frameEnd, volume: 0, adjustments: segment.adjustments,
                    sourceIndex: segment.sourceIndex, freezeDuration: Self.defaultFreezeSeconds)
                change {
                    var insertion = index
                    if frameStart > segment.start {
                        var right = segment
                        right.id = UUID()
                        right.start = frameStart
                        right.fadeIn = 0
                        $0.segments[index].end = frameStart
                        $0.segments[index].fadeOut = 0
                        $0.segments.insert(right, at: index + 1)
                        insertion = index + 1
                    }
                    $0.segments.insert(freeze, at: insertion)
                    $0.selectedID = freeze.id
                }
                position = freezeStart
                requestSeek()
            } catch is CancellationError { return } catch {
                if !closed, revision == generation, position == requestedPosition { report(error) }
            }
        }
    }

    static let defaultFreezeSeconds = 2.0

    var reverseUnavailableReason: String? {
        guard let segment = selectedSegment, !segment.isReversed else { return nil }
        if segment.isFreeze { return String(localized: "A freeze frame can’t be reversed.") }
        guard segment.end - segment.start <= VideoSegmentReverser.maximumSegmentSeconds else {
            let limit = Timecode.string(VideoSegmentReverser.maximumSegmentSeconds, fractionDigits: 0)
            return String(localized: "Reverse works on segments up to \(limit) long. Split this segment first.")
        }
        return nil
    }

    var canToggleReverse: Bool {
        selectedSegment != nil && reverseUnavailableReason == nil && !editingLocked && !splitting && !trimming
            && videoSource != nil
    }

    /// Reversing a reversed segment restores it.
    func toggleReverse() {
        guard canToggleReverse, let segment = selectedSegment else { return }
        reverseFailure = nil
        guard !segment.isReversed else {
            do {
                apply(try VideoSegmentReverser.unreverse(segmentID: segment.id, in: values.video, staging: staging))
            } catch {
                reverseFailure = UserMessages.describe(
                    EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
            }
            return
        }
        guard let videoSource else { return }
        pause()
        let edit = values.video
        reverseProgress = 0
        let reported = OSAllocatedUnfairLock(initialState: 0.0)
        reverseTask = Task {
            do {
                let reversed = try await videoSource.reverse(segmentID: segment.id, in: edit, omissions: consents) {
                    fraction in
                    // Per-frame callbacks would flood the main actor.
                    let advanced = reported.withLock { last in
                        guard fraction - last >= Self.reverseProgressStep else { return false }
                        last = fraction
                        return true
                    }
                    if advanced { Task { @MainActor in self.reportReverseProgress(fraction) } }
                }
                try await openStagedSources(reversed.sources ?? [])
                try Task.checkCancellation()
                reverseProgress = nil
                reverseTask = nil
                guard !closed, values.video == edit else { return }
                apply(reversed)
            } catch {
                reverseProgress = nil
                reverseTask = nil
                guard !closed, !(error is CancellationError) else { return }
                reverseFailure = UserMessages.describe(
                    EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
            }
        }
    }

    func cancelReverse() { reverseTask?.cancel() }

    private nonisolated static let reverseProgressStep = 0.005

    private func reportReverseProgress(_ fraction: Double) {
        guard let current = reverseProgress else { return }
        reverseProgress = max(current, fraction)
    }

    private func apply(_ edit: VideoEdit) {
        change {
            $0.sources = edit.sources ?? []
            $0.segments = edit.segments ?? []
            $0.overlays = edit.overlays
        }
    }

    /// Snapping, thumbnails and waveforms need staged sources.
    private func openStagedSources(_ sources: [VideoEditSource]) async throws {
        for source in sources where videoSources[source.url] == nil {
            let opened = try await VideoEditorSource.open(source.url, staging: staging)
            let details = await opened.details
            guard !closed else {
                await opened.close()
                throw CancellationError()
            }
            videoSources[source.url] = opened
            videoDetails[source.url] = details
        }
    }

    var canSaveFrame: Bool {
        isVideo && ready && !closed && !editingLocked && frameBatchID == nil && failure == nil
            && invalidFields.isEmpty && timeline != nil && !values.segments.isEmpty
    }

    /// Exports the edited frame without blocking editing.
    func saveFrame(run: (Batch, Engine.Settings) -> Task<BatchOutcome?, Never>) async {
        guard canSaveFrame else { return }
        let file = initialURLs[0].lastPathComponent
        frameNote = nil
        do {
            try validateForSave()
        } catch {
            frameNote = .failed(UserMessages.describe(EngineError.wrapping(error, path: url.path), file: file))
            return
        }
        pause()
        let batch = MediaEditing.frame(
            url: initialURLs[0], edit: values.video, outputSeconds: position, settings: settings, omissions: consents)
        frameBatchID = batch.id
        let task = run(batch, settings)
        frameTask = task
        let outcome = await task.value
        frameTask = nil
        frameBatchID = nil
        guard let outcome, !outcome.wasCancelled, let result = outcome.outcomes.first else { return }
        switch result {
        case .succeeded(let outputs, _): frameNote = outputs.first.map(FrameNote.saved)
        case .skipped(let reason): frameNote = .failed(UserMessages.describe(reason, file: file))
        case .failed(let error): frameNote = .failed(UserMessages.describeResult(error, file: file))
        }
    }

}
