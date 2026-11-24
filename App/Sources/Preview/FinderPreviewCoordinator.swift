import AppKit
import ApplicationServices
import Engine
import SwiftUI
import os

enum FinderPreviewPresence: Equatable {
    case hidden, notice, docked

    enum Window {
        case absent, visible, unavailable
    }

    init(enabled: Bool, trusted: Bool, window: Window) {
        switch (enabled, trusted, window) {
        case (false, _, _), (true, true, .absent): self = .hidden
        case (true, false, _), (true, true, .unavailable): self = .notice
        case (true, true, .visible): self = .docked
        }
    }
}

@MainActor
final class FinderPreviewCoordinator: NSObject, NSWindowDelegate {
    private static let finderIdentifier = "com.apple.finder"
    // Value of kAXTrustedCheckOptionPrompt, which isn't Sendable.
    private static let accessibilityPromptOption = "AXTrustedCheckOptionPrompt"
    private static let selectionInterval: TimeInterval = 0.25
    private static let trustInterval: TimeInterval = 1
    private static let failureBackoff: TimeInterval = 2
    // Surface transient failures after three polls.
    static let transientFailureThreshold = 3

    private let settings: SettingsStore
    private let staging: StagingArea
    private let reader = FinderSelectionReader()
    private let logger = Logger(category: "finder-preview")
    private var tracker: FinderWindowTracker?
    private var panel: FinderPreviewPanel?
    private(set) var state = FinderPreviewState()
    private var pollTimer: Timer?
    private var trustTimer: Timer?
    private var kindTask: Task<Void, Never>?
    private var generation: UInt64 = 0 {
        didSet { state.generation = generation }
    }
    private var targetID: CGWindowID?
    private var placement: FinderPreviewGeometry.Placement?
    private var trusted = false
    private var trackingFailed = false
    private var needsSlide = false
    // Consent prompts follow only a user action.
    private var mayAskConsent = false
    private var consecutiveSelectionFailures = 0
    private(set) var retryAfter = Date.distantPast
    var enabledChanged: (() -> Void)?

    init(settings: SettingsStore, staging: StagingArea) {
        self.settings = settings
        self.staging = staging
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        observeEnabled()
        attach(prompting: false)
    }

    func toggle() {
        settings.finderPreviewEnabled.toggle()
    }

    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        panel = nil
        settings.finderPreviewEnabled = false
    }

    private func observeEnabled() {
        withObservationTracking {
            _ = settings.finderPreviewEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeEnabled()
                self?.enabledDidChange()
            }
        }
    }

    private func enabledDidChange() {
        enabledChanged?()
        guard settings.finderPreviewEnabled else { return detach() }
        guard tracker == nil else { return }
        needsSlide = true
        mayAskConsent = true
        attach(prompting: true)
    }

    private func attach(prompting: Bool) {
        guard settings.finderPreviewEnabled, tracker == nil else { return }
        trusted =
            prompting
            ? AXIsProcessTrustedWithOptions([Self.accessibilityPromptOption: true] as CFDictionary)
            : AXIsProcessTrusted()
        trackingFailed = false
        guard trusted else {
            logger.notice("Finder Preview requires Accessibility permission")
            startTrustPolling()
            return updatePresence()
        }
        stopTrustPolling()
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderIdentifier).isEmpty else {
            return updatePresence()
        }
        let tracker = FinderWindowTracker()
        self.tracker = tracker
        tracker.changed = { [weak self] in self?.followWindow() }
        tracker.focused = { [weak self] in self?.readSelection(immediate: true) }
        tracker.ended = { [weak self] in self?.finderEnded() }
        tracker.failed = { [weak self] in self?.trackingStopped() }
        do {
            try tracker.start()
        } catch {
            logger.error("Finder preview could not dock: \(error.localizedDescription, privacy: .private)")
            return trackingStopped()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.selectionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readSelection() }
        }
    }

    private func detach() {
        stopTrustPolling()
        stopTracking()
        state.notice = nil
        mayAskConsent = false
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.dismiss()
    }

    private func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        tracker?.stop()
        tracker = nil
        targetID = nil
        placement = nil
        consecutiveSelectionFailures = 0
        clearSelection()
    }

    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: Self.trustInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard AXIsProcessTrusted() else { return }
                self?.attach(prompting: false)
            }
        }
    }

    private func stopTrustPolling() {
        trustTimer?.invalidate()
        trustTimer = nil
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.bundleIdentifier == Self.finderIdentifier
        else { return }
        attach(prompting: false)
    }

    private func finderEnded() {
        stopTracking()
        updatePresence()
    }

    private func trackingStopped() {
        stopTracking()
        trusted = AXIsProcessTrusted()
        trackingFailed = trusted
        if !trusted { startTrustPolling() }
        updatePresence()
    }

    private func retry() {
        mayAskConsent = true
        guard state.docked else {
            stopTracking()
            return attach(prompting: false)
        }
        state.notice = nil
        consecutiveSelectionFailures = 0
        retryAfter = .distantPast
        readSelection(immediate: true)
    }

    private func updatePresence() {
        let window: FinderPreviewPresence.Window =
            trackingFailed ? .unavailable : tracker?.target?.visible == true ? .visible : .absent
        switch FinderPreviewPresence(enabled: settings.finderPreviewEnabled, trusted: trusted, window: window) {
        case .hidden: hide()
        case .notice: showNotice(trusted ? .unavailable : .accessibility)
        case .docked: dock()
        }
    }

    private func hide() {
        consecutiveSelectionFailures = 0
        clearSelection()
        placement = nil
        guard let panel else { return }
        if panel.isDocked {
            panel.orderOut(nil)
        } else {
            self.panel = nil
            panel.delegate = nil
            panel.close()
        }
    }

    private func showNotice(_ notice: FinderPreviewState.Notice) {
        consecutiveSelectionFailures = 0
        clearSelection()
        placement = nil
        state.notice = notice
        state.docked = false
        let panel = preparedPanel(docked: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func dock() {
        guard let target = tracker?.target else { return }
        if !state.docked { state.notice = nil }
        state.docked = true
        let panel = preparedPanel(docked: true)
        let placement = FinderPreviewGeometry.placement(
            window: target.frame, screen: target.screen, width: panel.previewWidth)
        self.placement = placement
        state.dock = placement.dock
        panel.dock(placement, above: target.windowID, animate: needsSlide && !panel.isVisible)
        needsSlide = false
    }

    private func preparedPanel(docked: Bool) -> FinderPreviewPanel {
        if let panel, panel.isDocked == docked { return panel }
        if let panel {
            panel.delegate = nil
            panel.close()
        }
        let content = NSHostingView(rootView: makeView())
        content.sizingOptions = []
        let panel = FinderPreviewPanel(content: content, docked: docked)
        panel.delegate = self
        panel.resizePreview = { [weak self] in self?.followWindow() }
        panel.closeRequested = { [weak self] in self?.settings.finderPreviewEnabled = false }
        self.panel = panel
        return panel
    }

    private func makeView() -> FinderPreviewView {
        FinderPreviewView(
            state: state, settings: settings, staging: staging,
            close: { [weak self] in self?.settings.finderPreviewEnabled = false },
            retry: { [weak self] in self?.retry() },
            select: { [weak self] in self?.select($0) },
            resize: { [weak self] in self?.resize(by: $0) })
    }

    private func resize(by pointerDelta: CGFloat) {
        guard let panel, let placement, let target = tracker?.target else { return }
        panel.setPreviewWidth(
            FinderPreviewGeometry.resizedWidth(
                placement, pointerDelta: pointerDelta, window: target.frame, screen: target.screen))
    }

    private func followWindow() {
        let windowID = tracker?.target?.windowID
        let changedWindow = windowID != nil && windowID != targetID
        if changedWindow {
            consecutiveSelectionFailures = 0
            clearSelection()
            targetID = windowID
            if state.notice != .automation { state.notice = nil }
        }
        let wasVisible = panel?.isVisible == true
        updatePresence()
        if changedWindow || !wasVisible { readSelection(immediate: true) }
    }

    private func readSelection(immediate: Bool = false) {
        guard let panel, panel.isDocked, panel.isVisible, let tracker, let target = tracker.target, target.visible,
            immediate || tracker.finderIsFrontmost, Date() >= retryAfter, state.notice != .automation
        else { return }
        let requestedGeneration = generation
        reader.read(
            asking: mayAskConsent,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return generation == requestedGeneration && self.panel?.isVisible == true
                    && self.tracker?.frontWindowMatchesTarget() == true
            }
        ) { [weak self] result in
            guard let self else { return }
            applySelectionResult(result, trackedWindowID: targetID)
        }
    }

    func applySelectionResult(
        _ result: Result<FinderSelectionReader.Selection, FinderSelectionReader.Failure>,
        trackedWindowID: CGWindowID?
    ) {
        switch result {
        case .success(let selection):
            guard selection.windowID == trackedWindowID else {
                logger.error("Finder selection did not match the tracked window")
                selectionFailed(.unavailable)
                return
            }
            consecutiveSelectionFailures = 0
            state.notice = nil
            guard selection.urls != state.urls else { return }
            let previous = state.selectedURL
            state.urls = selection.urls
            select(previous.flatMap { selection.urls.firstIndex(of: $0) } ?? 0)
        case .failure(let failure):
            selectionFailed(failure)
        }
    }

    private func selectionFailed(_ failure: FinderSelectionReader.Failure) {
        if failure == .automationDenied {
            consecutiveSelectionFailures = 0
            clearSelection()
            state.notice = .automation
            retryAfter = Date().addingTimeInterval(Self.failureBackoff)
            return
        }
        consecutiveSelectionFailures += 1
        guard consecutiveSelectionFailures >= Self.transientFailureThreshold else { return }
        clearSelection()
        switch failure {
        case .automationDenied: state.notice = .automation
        case .timedOut: state.notice = .timedOut
        case .unavailable: state.notice = .unavailable
        }
        retryAfter = Date().addingTimeInterval(Self.failureBackoff)
    }

    private func clearSelection() {
        generation &+= 1
        kindTask?.cancel()
        kindTask = nil
        state.urls = []
        state.selectedIndex = 0
        state.kind = nil
        state.trust = nil
        state.detected = nil
        state.fileFailure = nil
    }

    private func select(_ index: Int) {
        generation &+= 1
        kindTask?.cancel()
        state.selectedIndex = index
        state.kind = nil
        state.trust = nil
        state.detected = nil
        state.fileFailure = nil
        guard let url = state.selectedURL else { return }
        let requestedGeneration = generation
        let disabledKinds = settings.finderPreview.disabledKinds
        let trustedFolders = settings.finderPreview.trustedFolders
        kindTask = Task { [weak self] in
            do {
                let (kind, trust, detected) = try await offMain {
                    try Task.checkCancellation()
                    let (kind, detected) = try PreviewKind.inspectContent(url, disabled: disabledKinds)
                    try Task.checkCancellation()
                    return (kind, PreviewTrust.evaluate(url, trustedFolders: trustedFolders), detected)
                }
                guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
                state.trust = trust
                state.detected = detected
                state.kind = kind
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
                logger.error("Preview file inspection failed: \(error.localizedDescription, privacy: .private)")
                state.fileFailure = String(localized: "This file could not be read.")
            }
        }
    }
}
