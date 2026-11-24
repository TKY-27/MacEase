import SwiftUI

enum PhotoZoomState: Equatable {
    case fit
    case magnification(Double)
    case factor(Double)
}

/// Percentages are screen pixels per image pixel.
enum PhotoZoomStep: Hashable, CaseIterable {
    case fit, actual, double, quadruple

    var magnification: Double? {
        switch self {
        case .fit: nil
        case .actual: 1
        case .double: 2
        case .quadruple: 4
        }
    }

    var title: String {
        magnification.map(PhotoZoomStep.percent) ?? String(localized: "Fit")
    }

    static func percent(_ magnification: Double) -> String {
        magnification.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension MediaEditorModel {
    /// Real screen pixels per image pixel.
    var photoMagnification: Double? {
        switch photoZoom {
        case .fit: photoFitScale
        case .magnification(let level): level
        case .factor(let factor): photoFitScale.map { $0 * factor }
        }
    }

    var photoZoomBounds: ClosedRange<Double> {
        guard let fit = photoFitScale else { return Self.photoZoomRange }
        let largestStep = PhotoZoomStep.quadruple.magnification ?? Self.photoZoomRange.upperBound
        return min(Self.photoZoomRange.lowerBound, 1 / fit)...max(Self.photoZoomRange.upperBound, largestStep / fit)
    }

    func clampedPhotoZoom(_ value: Double) -> Double {
        guard value.isFinite else { return zoom }
        return min(photoZoomBounds.upperBound, max(photoZoomBounds.lowerBound, value))
    }

    func clampedPhotoMagnification(_ level: Double, fit: Double) -> Double {
        let largestStep = PhotoZoomStep.quadruple.magnification ?? Self.photoZoomRange.upperBound
        let lower = min(fit * Self.photoZoomRange.lowerBound, 1)
        let upper = max(fit * Self.photoZoomRange.upperBound, largestStep)
        return min(upper, max(lower, level))
    }

    func livePhotoZoom(pinch: Double) -> Double {
        clampedPhotoZoom(zoom * pinch)
    }

    func livePhotoMagnification(pinch: Double) -> Double? {
        photoFitScale.map { $0 * livePhotoZoom(pinch: pinch) }
    }

    var photoZoomStep: PhotoZoomStep? {
        if case .fit = photoZoom { return .fit }
        guard let magnification = photoMagnification else { return nil }
        return PhotoZoomStep.allCases.first { step in
            step.magnification.map { abs($0 - magnification) <= $0 * Self.photoZoomStepTolerance } ?? false
        }
    }

    func setPhotoZoomStep(_ step: PhotoZoomStep) {
        guard !editingLocked else { return }
        guard let magnification = step.magnification else {
            photoZoom = .fit
            return
        }
        guard let fit = photoFitScale else { return }
        photoZoom = .magnification(clampedPhotoMagnification(magnification, fit: fit))
    }

    /// Pixels the preview needs at this zoom.
    var photoRenderDimension: Int {
        let longEdge = max(previewSize.width, previewSize.height)
        let needed = max(Self.photoRenderBase * zoom, (photoMagnification ?? 0) * longEdge)
        return Int(min(Self.maximumPhotoRenderDimension, needed))
    }

    private static let photoZoomStepTolerance = 0.005
    private static let photoRenderBase = 1600.0
    private static let maximumPhotoRenderDimension = 4096.0
}

/// Fit, fixed percentages and the live level.
struct PhotoZoomControl: View {
    @Bindable var model: MediaEditorModel
    let pinch: Double

    private var liveMagnification: Double? { model.livePhotoMagnification(pinch: pinch) }
    /// Cropping always shows the whole picture.
    private var cropping: Bool { model.category == .crop }
    private var shownStep: PhotoZoomStep? { cropping ? .fit : pinch == 1 ? model.photoZoomStep : nil }
    private var showsLevel: Bool { !cropping && shownStep.map { $0 == .fit } ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Picker(
                "Zoom",
                selection: Binding(
                    get: { shownStep },
                    set: { step in
                        if let step { model.setPhotoZoomStep(step) }
                    })
            ) {
                ForEach(PhotoZoomStep.allCases, id: \.self) { step in
                    Text(step.title).tag(Optional(step))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            levelText
        }
        .disabled(cropping || model.photoFitScale == nil)
        .help(cropping ? "Zoom is unavailable while cropping" : "Preview Zoom (⌘+ ⌘− ⌘0, or pinch)")
    }

    /// Reserved width keeps the picker still.
    private var levelText: some View {
        ZStack(alignment: .leading) {
            Text(verbatim: PhotoZoomStep.percent(Self.widestLevel)).hidden()
            if showsLevel, let liveMagnification {
                Text(PhotoZoomStep.percent(liveMagnification))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zoom Level"))
        .accessibilityValue(Text(liveMagnification.map(PhotoZoomStep.percent) ?? ""))
        .accessibilityHidden(!showsLevel || liveMagnification == nil)
    }

    private static let widestLevel = 88.88
}
