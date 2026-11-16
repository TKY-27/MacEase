import AppKit
import SwiftUI

@MainActor
final class FinderPreviewPanel: NSPanel {
    private static let widthKey = "finderPreviewWidth"
    private static let slideDistance: CGFloat = 20
    private static let slideDuration: TimeInterval = 0.16
    private let defaults: UserDefaults
    private(set) var previewWidth: CGFloat
    var resizePreview: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(docked: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.widthKey)
        previewWidth = saved.isFinite && saved > 0 ? saved : FinderPreviewGeometry.defaultWidth
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: previewWidth, height: 480),
            styleMask: docked ? [.borderless, .nonactivatingPanel] : [.titled, .closable],
            backing: .buffered, defer: false)
        title = String(localized: "Finder Preview")
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
    }

    func setPreviewWidth(_ width: CGFloat) {
        previewWidth = width
        resizePreview?()
        defaults.set(previewWidth, forKey: Self.widthKey)
    }

    func dock(_ placement: FinderPreviewGeometry.Placement, above windowID: CGWindowID, animate: Bool) {
        previewWidth = placement.frame.width
        let shouldAnimate = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            let offset = placement.dock == .left ? Self.slideDistance : -Self.slideDistance
            setFrame(placement.frame.offsetBy(dx: offset, dy: 0), display: false)
        } else {
            setFrame(placement.frame, display: true)
        }
        order(.above, relativeTo: Int(windowID))
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.slideDuration
                animator().setFrame(placement.frame, display: true)
            }
        }
    }
}

struct PreviewResizeEdge: NSViewRepresentable {
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView(resize: resize) }
    func updateNSView(_ nsView: ResizeView, context: Context) { nsView.resize = resize }

    @MainActor
    final class ResizeView: NSView {
        var resize: (CGFloat) -> Void
        private var previousX: CGFloat = 0

        init(resize: @escaping (CGFloat) -> Void) {
            self.resize = resize
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) { previousX = NSEvent.mouseLocation.x }
        override func mouseDragged(with event: NSEvent) {
            let x = NSEvent.mouseLocation.x
            resize(x - previousX)
            previousX = x
        }
    }
}
