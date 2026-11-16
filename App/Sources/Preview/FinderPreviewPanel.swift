import AppKit
import SwiftUI

@MainActor
final class FinderPreviewPanel: NSPanel {
    private static let widthKey = "finderPreviewWidth"
    private static let slideDistance: CGFloat = 20
    private static let slideDuration: TimeInterval = 0.16
    private static let dismissDuration: TimeInterval = 0.12
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    // Measured from Finder windows on macOS 27.
    private static let finderCornerRadius: CGFloat = 16
    private static let undockedSize = NSSize(width: FinderPreviewGeometry.defaultWidth, height: 600)
    private static let minimumSize = NSSize(width: FinderPreviewGeometry.minimumWidth, height: 420)
    private static let escape = "\u{1B}"
    private let defaults: UserDefaults
    private let container = NSView()
    private(set) var previewWidth: CGFloat
    private var dock = FinderPreviewGeometry.Dock.right
    var resizePreview: (() -> Void)?
    var closeRequested: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(content: NSView, docked: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.widthKey)
        previewWidth = saved.isFinite && saved > 0 ? saved : FinderPreviewGeometry.defaultWidth
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.undockedSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = String(localized: "Finder Preview")
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = false
        animationBehavior = .none
        contentMinSize = Self.minimumSize
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
        if docked {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
        } else {
            undock()
        }
    }

    func undock() {
        styleMask = [.titled, .closable, .resizable]
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        container.layer?.cornerRadius = 0
        container.layer?.masksToBounds = false
        alphaValue = 1
        setContentSize(Self.undockedSize)
        center()
    }

    func setPreviewWidth(_ width: CGFloat) {
        previewWidth = width
        resizePreview?()
        defaults.set(previewWidth, forKey: Self.widthKey)
    }

    func dock(_ placement: FinderPreviewGeometry.Placement, above windowID: CGWindowID, animate: Bool) {
        previewWidth = placement.frame.width
        if placement.dock != dock || container.layer?.masksToBounds != true { roundOuterCorners(placement.dock) }
        guard animate else {
            setFrame(placement.frame, display: true)
            order(.above, relativeTo: Int(windowID))
            invalidateShadow()
            return
        }
        let slides = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = 0
        setFrame(slides ? placement.frame.offsetBy(dx: slideOffset, dy: 0) : placement.frame, display: true)
        order(.above, relativeTo: Int(windowID))
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = Self.easeOut
            animator().setFrame(placement.frame, display: true)
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else {
            close()
            return
        }
        let slides = styleMask.contains(.borderless) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = slides ? frame.offsetBy(dx: slideOffset, dy: 0) : frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissDuration
            context.timingFunction = Self.easeOut
            animator().setFrame(target, display: true)
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                self.contentView = nil
                self.close()
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers
        if modifiers.isEmpty, key == Self.escape, let editor = firstResponder as? NSTextView,
            editor.hasMarkedText()
        {
            return super.performKeyEquivalent(with: event)
        }
        let closes = (modifiers.isEmpty && key == Self.escape) || (modifiers == .command && key == "w")
        guard closes, let closeRequested else { return super.performKeyEquivalent(with: event) }
        closeRequested()
        return true
    }

    // Starts beside Finder, then slides outward.
    private var slideOffset: CGFloat { dock == .right ? -Self.slideDistance : Self.slideDistance }

    private func roundOuterCorners(_ dock: FinderPreviewGeometry.Dock) {
        self.dock = dock
        guard let layer = container.layer else { return }
        layer.cornerRadius = Self.finderCornerRadius
        layer.masksToBounds = true
        switch dock {
        case .right: layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .left: layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .inset:
            layer.maskedCorners = [
                .layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner,
            ]
        }
    }
}

struct PreviewResizeEdge: NSViewRepresentable {
    let leading: Bool
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView(leading: leading, resize: resize) }

    func updateNSView(_ nsView: ResizeView, context: Context) {
        nsView.resize = resize
        nsView.leading = leading
    }

    @MainActor
    final class ResizeView: NSView {
        private static let gripSize = NSSize(width: 3, height: 36)
        private static let gripInset: CGFloat = 3
        var resize: (CGFloat) -> Void
        var leading: Bool {
            didSet { needsDisplay = true }
        }
        private var previousX: CGFloat = 0
        private var highlighted = false {
            didSet { needsDisplay = true }
        }

        init(leading: Bool, resize: @escaping (CGFloat) -> Void) {
            self.leading = leading
            self.resize = resize
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        private var cursor: NSCursor {
            NSCursor.frameResize(position: leading ? .left : .right, directions: .all)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // Finder usually stays the active application.
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            highlighted = true
            cursor.set()
        }

        override func mouseMoved(with event: NSEvent) { cursor.set() }

        override func mouseExited(with event: NSEvent) {
            highlighted = false
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) { previousX = NSEvent.mouseLocation.x }

        override func mouseDragged(with event: NSEvent) {
            let x = NSEvent.mouseLocation.x
            resize(x - previousX)
            previousX = x
            cursor.set()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard highlighted else { return }
            let size = Self.gripSize
            let x = leading ? Self.gripInset : bounds.width - Self.gripInset - size.width
            let grip = NSRect(x: x, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: grip, xRadius: size.width / 2, yRadius: size.width / 2).fill()
        }
    }
}
