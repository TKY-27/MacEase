import AppKit
import Observation
import SwiftUI

@MainActor
final class FinderStorageBar {
    struct Window: Equatable {
        let id: CGWindowID
        let frame: CGRect
        let preview: FinderPreviewGeometry.Placement?
    }

    // Finder's own figure refreshes about this slowly.
    private static let refreshInterval: TimeInterval = 5

    let model: FinderStorageBarModel
    private let readsStatusBar: @MainActor () -> Bool
    private var panel: FinderStorageBarPanel?
    private var window: Window?
    private var windowID: CGWindowID?
    private var refreshTimer: Timer?
    private var activationObserver: (any NSObjectProtocol)?
    private(set) var statusBarShown = false

    var isVisible: Bool { panel?.isVisible == true }
    // Visible once the first figures arrive.
    var wantsSelection: Bool { window != nil && statusBarShown }

    init(
        model: FinderStorageBarModel = FinderStorageBarModel(),
        readsStatusBar: @escaping @MainActor () -> Bool = FinderStorageBarGeometry.finderShowsStatusBar
    ) {
        self.model = model
        self.readsStatusBar = readsStatusBar
        observeVolume()
    }

    func start() {
        guard refreshTimer == nil else { return }
        statusBarShown = readsStatusBar()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        activationObserver.map(NotificationCenter.default.removeObserver)
        activationObserver = nil
        window = nil
        windowID = nil
        model.reset()
        panel?.orderOut(nil)
    }

    /// Nil hides the strip.
    func follow(_ window: Window?) {
        if let window, window.id != windowID {
            windowID = window.id
            model.forgetLocation()
        }
        self.window = window
        place()
    }

    private func refresh() {
        let shown = readsStatusBar()
        if shown != statusBarShown {
            statusBarShown = shown
            place()
        }
        model.refreshVolume()
    }

    private func observeVolume() {
        withObservationTracking {
            _ = model.volume
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeVolume()
                self?.place()
            }
        }
    }

    private func place() {
        guard let window, model.volume != nil,
            let placement = FinderStorageBarGeometry.placement(
                window: window.frame, preview: window.preview, statusBarShown: statusBarShown)
        else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.place(placement, above: window.id)
    }

    private func makePanel() -> FinderStorageBarPanel {
        let content = NSHostingView(rootView: FinderStorageBarView(model: model))
        content.sizingOptions = []
        let panel = FinderStorageBarPanel(content: content)
        self.panel = panel
        return panel
    }
}

@MainActor
final class FinderStorageBarPanel: NSPanel {
    private let container = NSView()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(content: NSView) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = String(localized: "Storage")
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Display only; clicks reach Finder's own bar.
        ignoresMouseEvents = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = FinderPreviewPanel.finderCornerRadius
        container.layer?.masksToBounds = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
    }

    private(set) var placement: FinderStorageBarGeometry.Placement?

    func place(_ placement: FinderStorageBarGeometry.Placement, above windowID: CGWindowID) {
        if placement != self.placement {
            self.placement = placement
            var corners: CACornerMask = []
            if placement.roundsLeadingCorner { corners.insert(.layerMinXMinYCorner) }
            if placement.roundsTrailingCorner { corners.insert(.layerMaxXMinYCorner) }
            container.layer?.maskedCorners = corners
            setFrame(placement.frame, display: true)
        }
        order(.above, relativeTo: Int(windowID))
    }
}
