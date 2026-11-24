import Engine
import SwiftUI

struct EditorSilenceAnalysis {
    let stamp: MediaSourceStamp
    let levels: AudioLevels
}

extension MediaEditorModel {
    /// Sources whose audible segments can be cut.
    var silenceSources: [URL] {
        let indices = Set(
            values.segments.filter { !$0.isFreeze && $0.volume > 0 && sourceHasAudio($0.sourceIndex) }
                .map(\.sourceIndex))
        return indices.sorted().map { values.sources[$0].url }
    }

    var silenceUnavailableReason: String? {
        silenceSources.isEmpty ? String(localized: "There’s no audible sound to analyze in this video.") : nil
    }

    var canAnalyzeSilence: Bool {
        !editingLocked && silenceTask == nil && !silenceSources.isEmpty
            && silenceSources.contains { silenceLevels[$0] == nil }
    }

    /// File identity bounds cached analysis.
    func analyzeSilence() {
        guard !editingLocked, silenceTask == nil else { return }
        let sources = values.sources.filter { silenceSources.contains($0.url) }
        silenceFailure = nil
        do {
            for source in sources {
                try source.stamp.validate(source.url)
                if silenceLevels[source.url]?.stamp != source.stamp { silenceLevels[source.url] = nil }
            }
        } catch {
            silenceFailure = describeSilence(error)
            return
        }
        let missing = sources.filter { silenceLevels[$0.url] == nil }
        guard !missing.isEmpty else { return }
        silenceTask = Task {
            defer { silenceTask = nil }
            for source in missing {
                do {
                    try source.stamp.validate(source.url)
                    let levels = try await AudioWaveform.levels(videoAt: source.url)
                    try Task.checkCancellation()
                    try source.stamp.validate(source.url)
                    guard !editingLocked, values.sources.contains(source) else { return }
                    silenceLevels[source.url] = EditorSilenceAnalysis(stamp: source.stamp, levels: levels)
                } catch is CancellationError {
                    return
                } catch {
                    guard !closed else { return }
                    silenceFailure = UserMessages.describe(
                        EngineError.wrapping(error, path: source.url.path), file: source.url.lastPathComponent)
                    return
                }
            }
        }
    }

    func cancelSilenceAnalysis() { silenceTask?.cancel() }

    /// Removed output ranges; `nil` before analysis.
    func silencePreview(_ rule: SilenceRule) throws -> [ClosedRange<Double>]? {
        guard let silences = try silences(rule), let timeline else { return nil }
        var removed: [ClosedRange<Double>] = []
        for segment in values.segments {
            guard let start = timeline.outputTime(for: segment.start, segmentID: segment.id) else { continue }
            var cursor = segment.start
            let pieces = try kept(segment, silences: silences)
            for piece in pieces + [VideoSegment(start: segment.end, end: segment.end)] {
                if piece.start > cursor {
                    let lower = start + (cursor - segment.start) / segment.speed
                    removed.append(lower...(start + (piece.start - segment.start) / segment.speed))
                }
                cursor = max(cursor, piece.end)
            }
        }
        return removed
    }

    /// Errors appear in the popover instead.
    var silenceHatching: [ClosedRange<Double>] {
        guard showsSilencePreview, let preview = try? silencePreview(silenceRule) else { return [] }
        return preview
    }

    var canApplySilence: Bool {
        guard !editingLocked, silenceTask == nil,
            let preview = try? silencePreview(silenceRule), !preview.isEmpty
        else { return false }
        return !silenceLeavesNothing(preview)
    }

    func silenceLeavesNothing(_ preview: [ClosedRange<Double>]?) -> Bool {
        guard let preview, !preview.isEmpty else { return false }
        let removed = preview.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return removed >= outputDuration - Self.silenceDurationTolerance
    }

    private static let silenceDurationTolerance = 1e-6

    func removeSilence(_ rule: SilenceRule) {
        guard !editingLocked else { return }
        silenceFailure = nil
        do {
            guard let silences = try silences(rule) else { return }
            let segments = try SilenceRemoval.segments(
                values.segments, silences: silences, minimumKept: minimumKeptSeconds)
            change {
                $0.segments = segments
                $0.selectedID = segments.first?.id
            }
            showsSilencePreview = false
        } catch {
            silenceFailure = describeSilence(error)
        }
    }

    func describeSilence(_ error: Error) -> String {
        if case EngineError.invalidInput(.emptyInput) = error {
            return String(localized: "Nothing would be left. Choose a lower threshold or a longer pause.")
        }
        return UserMessages.describe(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
    }

    private var minimumKeptSeconds: Double { frameDuration * 2 }

    private func silences(_ rule: SilenceRule) throws -> [Int: [Range<Double>]]? {
        var silences: [Int: [Range<Double>]] = [:]
        for index in values.sources.indices where sourceHasAudio(index) {
            let source = values.sources[index]
            try source.stamp.validate(source.url)
            guard let cached = silenceLevels[source.url], cached.stamp == source.stamp else {
                if silenceSources.contains(values.sources[index].url) { return nil }
                continue
            }
            silences[index] = try cached.levels.silentRanges(rule)
        }
        return silences
    }

    private func kept(_ segment: VideoSegment, silences: [Int: [Range<Double>]]) throws -> [VideoSegment] {
        do {
            return try SilenceRemoval.segments([segment], silences: silences, minimumKept: minimumKeptSeconds)
        } catch EngineError.invalidInput(.emptyInput) {
            return []
        }
    }
}

/// Tunes and applies silence removal.
struct EditorSilencePopover: View {
    @Bindable var model: MediaEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove Silence").font(.headline)
            if let reason = model.silenceUnavailableReason {
                Label(reason, systemImage: "speaker.slash").foregroundStyle(.secondary)
            } else if model.silenceTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing sound…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: model.cancelSilenceAnalysis)
                }
                .accessibilityElement(children: .contain)
            } else {
                if model.canAnalyzeSilence { Button("Analyze", action: model.analyzeSilence) }
                controls
            }
            if let failure = model.silenceFailure { ProblemLabel(text: failure) }
        }
        .frame(width: 320, alignment: .leading)
        .padding(16)
        .onAppear(perform: model.analyzeSilence)
        .onDisappear(perform: model.cancelSilenceAnalysis)
    }

    @ViewBuilder private var controls: some View {
        let result = Result { try model.silencePreview(model.silenceRule) }
        let preview = try? result.get()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Silent below")
                Spacer()
                Text(decibels(model.silenceRule.threshold)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: rounded(\.threshold, step: Self.thresholdStep), in: SilenceRule.thresholdRange) {
                Text("Silent below")
            }
            .labelsHidden()
            .accessibilityValue(Text(decibels(model.silenceRule.threshold)))
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pauses longer than")
                Spacer()
                Text(seconds(model.silenceRule.minimumDuration)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(
                value: rounded(\.minimumDuration, step: Self.durationStep), in: SilenceRule.minimumDurationRange
            ) {
                Text("Pauses longer than")
            }
            .labelsHidden()
            .accessibilityValue(Text(seconds(model.silenceRule.minimumDuration)))
        }
        Text("Each cut keeps a short margin of sound so speech isn’t clipped.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Divider()
        HStack {
            if let preview {
                Text(summary(preview)).monospacedDigit()
            }
            Spacer()
            Button("Apply") {
                model.removeSilence(model.silenceRule)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApplySilence)
        }
        if case .failure(let error) = result {
            ProblemLabel(text: model.describeSilence(error))
        } else if model.silenceLeavesNothing(preview) {
            ProblemLabel(text: String(localized: "Nothing would be left. Choose a lower threshold or a longer pause."))
        }
    }

    /// Steps without tick marks.
    private func rounded(_ keyPath: WritableKeyPath<SilenceRule, Double>, step: Double) -> Binding<Double> {
        Binding(
            get: { model.silenceRule[keyPath: keyPath] },
            set: { model.silenceRule[keyPath: keyPath] = ($0 / step).rounded() * step })
    }

    private func summary(_ preview: [ClosedRange<Double>]) -> String {
        guard !preview.isEmpty else { return String(localized: "No pauses found") }
        let removed = preview.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return String(localized: "Removes \(preview.count) pauses (\(Timecode.string(removed, fractionDigits: 1)))")
    }

    private func decibels(_ value: Double) -> String {
        String(localized: "\(value.formatted(.number.precision(.fractionLength(0)))) dB")
    }

    private func seconds(_ value: Double) -> String {
        String(localized: "\(value.formatted(.number.precision(.fractionLength(2)))) sec")
    }

    private static let durationStep = 0.05
    private static let thresholdStep = 1.0
}
