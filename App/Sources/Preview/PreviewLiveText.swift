import AppKit
import Observation
import VisionKit
import os

@MainActor
@Observable
final class PreviewLiveText {
    // Skips analysis while arrowing through files.
    static let settleDelay = Duration.milliseconds(350)
    // Text is unreadable after a 4,096-pixel decode.
    static let maximumPixels = 100_000_000.0
    static let minimumEdge = 32.0

    private(set) var analysis: ImageAnalysis?
    private var work: Task<Void, Never>?

    static func isWorthAnalyzing(pixelSize: CGSize, animated: Bool) -> Bool {
        !animated && min(pixelSize.width, pixelSize.height) >= minimumEdge
            && pixelSize.width * pixelSize.height <= maximumPixels && ImageAnalyzer.isSupported
    }

    func analyze(_ image: CGImage) {
        cancel()
        work = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.settleDelay)
                let analysis = try await ImageAnalyzer().analyze(
                    image, orientation: .up, configuration: ImageAnalyzer.Configuration(.text))
                try Task.checkCancellation()
                self?.analysis = analysis
            } catch is CancellationError {
            } catch {
                Logger(category: "finder-preview").notice(
                    "Live Text analysis failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        analysis = nil
    }
}

// Finder keeps focus until text selection.
@MainActor
final class PreviewLiveTextOverlay: NSObject, ImageAnalysisOverlayViewDelegate {
    let view = ImageAnalysisOverlayView()
    private weak var content: NSView?

    init(content: NSView) {
        self.content = content
        super.init()
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

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        guard overlayView.hasActiveTextSelection, let window = overlayView.window, !window.isKeyWindow else { return }
        window.makeKey()
        window.makeFirstResponder(overlayView)
    }
}
