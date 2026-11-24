import Engine
import SwiftUI

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

    var silenceAnalyzed: Bool { silenceSources.allSatisfy { silenceLevels[$0] != nil } }

    /// Levels stay cached per source.
    func analyzeSilence() {
        guard silenceTask == nil, !closed else { return }
        let missing = silenceSources.filter { silenceLevels[$0] == nil }
        guard !missing.isEmpty else { return }
        silenceFailure = nil
        silenceTask = Task {
            defer { silenceTask = nil }
            for url in missing {
                do {
                    let levels = try await AudioWaveform.levels(videoAt: url)
                    try Task.checkCancellation()
                    guard !closed else { return }
                    silenceLevels[url] = levels
                } catch is CancellationError {
                    return
                } catch {
                    silenceFailure = UserMessages.describe(
                        EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
                    return
                }
            }
        }
    }

    func cancelSilenceAnalysis() { silenceTask?.cancel() }

    /// Output ranges the rule would remove; `nil` before analysis.
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

    func removeSilence(_ rule: SilenceRule) {
        do {
            guard let silences = try silences(rule) else { return }
            let segments = try SilenceRemoval.segments(
                values.segments, silences: silences, minimumKept: minimumKeptSeconds)
            change {
                $0.segments = segments
                $0.selectedID = segments.first?.id
            }
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
            guard let levels = silenceLevels[values.sources[index].url] else {
                if silenceSources.contains(values.sources[index].url) { return nil }
                continue
            }
            silences[index] = try levels.silentRanges(rule)
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
                if model.silenceFailure == nil { model.showsSilencePreview = false }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(preview?.isEmpty != false || leavesNothing(preview))
        }
        if case .failure(let error) = result {
            ProblemLabel(text: model.describeSilence(error))
        } else if leavesNothing(preview) {
            ProblemLabel(text: String(localized: "Nothing would be left. Choose a lower threshold or a longer pause."))
        }
    }

    /// Steps without tick marks.
    private func rounded(_ keyPath: WritableKeyPath<SilenceRule, Double>, step: Double) -> Binding<Double> {
        Binding(
            get: { model.silenceRule[keyPath: keyPath] },
            set: { model.silenceRule[keyPath: keyPath] = ($0 / step).rounded() * step })
    }

    private func leavesNothing(_ preview: [ClosedRange<Double>]?) -> Bool {
        guard let preview, !preview.isEmpty else { return false }
        let removed = preview.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return removed >= model.outputDuration - Self.durationTolerance
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
    private static let durationTolerance = 1e-6
}
