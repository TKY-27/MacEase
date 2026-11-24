import Engine
import SwiftUI
import os

enum FrameNote: Equatable {
    case saved(URL)
    case failed(String)
}

extension MediaEditorModel {
    func frameRange(at seconds: Double, segment: VideoSegment, source: VideoEditorSource) async throws
        -> ClosedRange<Double>
    {
        let next = try await nextFrameTimeOrEnd(after: seconds, sourceIndex: segment.sourceIndex, source: source)
        let end = min(segment.end, next)
        let start = max(segment.start, try await source.adjacentFrameTime(to: end, forward: false))
        return start...end
    }

    var canInsertFreezeFrame: Bool {
        guard !editingLocked, !splitting, !trimming, !hasPendingBoundaryInput, let timeline, !values.segments.isEmpty
        else { return false }
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
        splitTask?.cancel()
        splitting = true
        splitTask = Task {
            defer { splitting = false }
            do {
                let frame = try await frameRange(at: seconds, segment: segment, source: videoSource)
                let frameEnd = frame.upperBound
                let frameStart = frame.lowerBound
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

    var reversedBinding: Binding<Bool> {
        Binding(get: { self.selectedSegment?.isReversed == true }, set: { _ in self.toggleReverse() })
    }

    var canToggleReverse: Bool {
        selectedSegment != nil && reverseUnavailableReason == nil && !editingLocked && !splitting && !trimming
            && videoSource != nil && !importing && musicTask == nil && !hasPendingBoundaryInput
            && overlayBoundaryTask == nil
    }

    /// Reversing a reversed segment restores it.
    func toggleReverse() {
        guard canToggleReverse, let segment = selectedSegment else { return }
        reverseFailure = nil
        let sourceURL = values.sources[segment.sourceIndex].url
        guard !segment.isReversed else {
            do {
                apply(try VideoSegmentReverser.unreverse(segmentID: segment.id, in: values.video, staging: staging))
            } catch {
                reverseFailure = UserMessages.describe(
                    EngineError.wrapping(error, path: sourceURL.path), file: sourceName(segment))
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
                try await completeReverse(reversed, replacing: edit, segmentID: segment.id)
                reverseTask = nil
            } catch {
                reverseProgress = nil
                reverseTask = nil
                guard !closed, !(error is CancellationError) else { return }
                reverseFailure = UserMessages.describe(
                    EngineError.wrapping(error, path: sourceURL.path), file: sourceName(segment))
            }
        }
    }

    func completeReverse(_ reversed: VideoEdit, replacing previous: VideoEdit, segmentID: UUID) async throws {
        guard let segment = reversed.segments?.first(where: { $0.id == segmentID }),
            let sources = reversed.sources, sources.indices.contains(segment.sourceIndex), let videoSource
        else { throw EngineError.invalidInput(.emptyInput) }
        let stagedURL = sources[segment.sourceIndex].url
        do {
            try Task.checkCancellation()
            try await openStagedSources(sources)
            try Task.checkCancellation()
            guard !closed, values.video == previous else { throw CancellationError() }
            reverseProgress = nil
            apply(reversed)
        } catch {
            if let opened = videoSources.removeValue(forKey: stagedURL) { await opened.close() }
            videoDetails[stagedURL] = nil
            await videoSource.discardReversedSource(at: stagedURL)
            throw error
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
        isVideo && ready && !closed && !editingLocked && frameBatchID == nil && (failure == nil || musicChanged)
            && invalidFields.isEmpty && timeline != nil && !values.segments.isEmpty
            && !splitting && !trimming && !hasPendingBoundaryInput && overlayBoundaryTask == nil
    }

    /// Exports the edited frame without blocking editing.
    func saveFrame(run: (Batch, Engine.Settings) -> Task<BatchOutcome?, Never>) async {
        guard canSaveFrame else { return }
        let file = initialURLs[0].lastPathComponent
        frameNote = nil
        do {
            try validateForSave(includingAudio: false)
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
