import Engine
import Foundation

/// Tooltips and VoiceOver hints for disabled controls.
extension MediaEditorModel {
    /// Busy states show their own progress.
    private var editPending: Bool {
        splitting || trimming || hasPendingBoundaryInput || overlayBoundaryTask != nil
    }

    func splitUnavailableReason(for id: UUID) -> String? {
        guard !editingLocked, !editPending, !canSplitSegment(id),
            let segment = values.segments.first(where: { $0.id == id })
        else { return nil }
        if segment.isFreeze { return String(localized: "A freeze frame can’t be split.") }
        return String(localized: "Place the playhead inside this segment to split it.")
    }

    var splitUnavailableReason: String? { values.selectedID.flatMap(splitUnavailableReason(for:)) }

    func freezeFrameUnavailableReason(for id: UUID?) -> String? {
        guard !editingLocked, !editPending, let timeline, !values.segments.isEmpty else { return nil }
        let current = timeline.segment(at: position)
        if current.isFreeze { return String(localized: "The playhead is already on a freeze frame.") }
        if let id, current.id != id { return String(localized: "Place the playhead inside this segment first.") }
        return nil
    }

    func trimUnavailableReason(for id: UUID) -> String? {
        values.segments.first { $0.id == id }?.isFreeze == true
            ? String(localized: "A freeze frame can’t be trimmed.") : nil
    }

    var saveFrameUnavailableReason: String? {
        guard isVideo, !editingLocked, frameBatchID == nil else { return nil }
        if invalidFields.contains(where: { $0 != Self.overlayTextField }) {
            return String(localized: "Enter a valid number first.")
        }
        if invalidFields.contains(Self.overlayTextField) {
            return String(localized: "Enter valid markup text first.")
        }
        if editPending { return String(localized: "Wait for the current edit to finish.") }
        return nil
    }

    var previewMuteUnavailableReason: String? {
        hasAudio ? nil : String(localized: "This video has no sound.")
    }

    var segmentVolumeUnavailableReason: String? {
        guard let segment = selectedSegment, !segment.isFreeze, !selectedHasAudio else { return nil }
        return String(localized: "This segment’s video has no sound.")
    }

    func applyToAllUnavailableReason(styleOnly: Bool) -> String? {
        guard !editingLocked, values.segments.count > 1, hasSelection, !canApplyToAllSegments(styleOnly: styleOnly)
        else { return nil }
        return styleOnly
            ? String(localized: "Every segment already has this style.")
            : String(localized: "Every segment already has these adjustments.")
    }

    var swapCropSidesUnavailableReason: String? {
        cropAspect == 0 || cropAspect == 1
            ? String(localized: "Choose a ratio other than Freeform or 1:1.") : nil
    }

    var addOverlayUnavailableReason: String? {
        markupOverlays.count >= EditOverlay.maximumCount
            ? String(localized: "Up to \(EditOverlay.maximumCount) items.") : nil
    }

    var overlayBoundaryUnavailableReason: String? {
        guard !editingLocked, selectedTimedOverlay != nil, timeline != nil, !canSetOverlayBoundary else { return nil }
        return String(localized: "Move the playhead into this video to set the range from it.")
    }
}
