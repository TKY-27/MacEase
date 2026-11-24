import AppKit
import Observation
import VisionKit
import os

@MainActor
@Observable
final class PreviewLiveText {
    enum Phase: Equatable {
        case idle, waiting, analyzing, finished
    }

    // Skips analysis while arrowing through files.
    static let settleDelay = Duration.milliseconds(350)
    // Text is unreadable after a 4,096-pixel decode.
    static let maximumPixels = 100_000_000.0
    static let minimumEdge = 32.0

    private(set) var analysis: ImageAnalysis?
    private(set) var phase = Phase.idle
    private var work: Task<Void, Never>?

    static func isWorthAnalyzing(pixelSize: CGSize, animated: Bool) -> Bool {
        !animated && min(pixelSize.width, pixelSize.height) >= minimumEdge
            && pixelSize.width * pixelSize.height <= maximumPixels && ImageAnalyzer.isSupported
    }

    func analyze(_ image: CGImage) {
        cancel()
        phase = .waiting
        work = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.settleDelay)
                try Task.checkCancellation()
                self?.phase = .analyzing
                let analysis = try await ImageAnalyzer().analyze(
                    image, orientation: .up, configuration: ImageAnalyzer.Configuration(.text))
                try Task.checkCancellation()
                self?.analysis = analysis.hasResults(for: .text) ? analysis : nil
                self?.phase = .finished
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .finished
                Logger(category: "finder-preview").notice(
                    "Live Text analysis failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        analysis = nil
        phase = .idle
    }
}

// Finder keeps focus until text selection.
@MainActor
final class PreviewLiveTextOverlay: NSObject, ImageAnalysisOverlayViewDelegate {
    let view = ImageAnalysisOverlayView()
    private weak var content: PreviewImageLayerView?

    init(content: PreviewImageLayerView) {
        self.content = content
        super.init()
        content.liveText = view
        view.delegate = self
        view.preferredInteractionTypes = [.textSelection, .dataDetectors]
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }

    // The Live Text button is permanent chrome.
    func show(_ analysis: ImageAnalysis?) {
        guard view.analysis !== analysis else { return }
        view.analysis = analysis
        view.setSupplementaryInterfaceHidden(true, animated: false)
    }

    func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? { content }

    // The overlay refuses first responder; the image answers Copy.
    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        guard overlayView.hasActiveTextSelection, let window = overlayView.window else { return }
        if !window.isKeyWindow { window.makeKey() }
        window.makeFirstResponder(content)
    }
}
