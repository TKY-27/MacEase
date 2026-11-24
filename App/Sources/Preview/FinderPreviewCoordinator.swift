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

    struct TrackedWindow: Equatable {
        let id: CGWindowID
        let frame: CGRect
        let screen: CGRect
        let visible: Bool
    }

    private let settings: SettingsStore
    private let staging: StagingArea
    private let isTrusted: @MainActor () -> Bool
    private let finderIsFrontmostCheck: (@MainActor () -> Bool)?
    private let frontWindowMatchesCheck: (@MainActor () -> Bool)?
    let storageBar: FinderStorageBar
    private let reader: FinderSelectionReader
    private let logger = Logger(category: "finder-preview")
    private var tracker: FinderWindowTracker?
    private var trackedWindow: TrackedWindow?
    private var panel: FinderPreviewPanel?
    private(set) var state = FinderPreviewState()
    private var pollTimer: Timer?
    private var trustTimer: Timer?
    private var activationObserver: (any NSObjectProtocol)?
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
    private var storageBarAutomationDenied = false
    private var consecutiveSelectionFailures = 0
    private var observedDisabledKinds: Set<FinderPreviewFileType>
    private var observedTrustedFolders: [String]
    private(set) var retryAfter = Date.distantPast
    var enabledChanged: (() -> Void)?

    init(
        settings: SettingsStore, staging: StagingArea, storageBar: FinderStorageBar = FinderStorageBar(),
        reader: FinderSelectionReader = FinderSelectionReader(),
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        finderIsFrontmost: (@MainActor () -> Bool)? = nil,
        frontWindowMatches: (@MainActor () -> Bool)? = nil
    ) {
        self.settings = settings
        self.staging = staging
        self.storageBar = storageBar
        self.reader = reader
        self.isTrusted = isTrusted
        finderIsFrontmostCheck = finderIsFrontmost
        frontWindowMatchesCheck = frontWindowMatches
        observedDisabledKinds = settings.finderPreview.disabledKinds
        observedTrustedFolders = settings.finderPreview.trustedFolders
        super.init()
        observePreviewSettings()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applicationDidBecomeActive() }
        }
        observeEnabled()
        observeStorageBarEnabled()
        attach(prompting: false)
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        activationObserver.map(NotificationCenter.default.removeObserver)
        activationObserver = nil
        detach(immediately: true)
    }

    func followTrackedWindow(_ window: TrackedWindow?, trusted: Bool = true) {
        self.trusted = trusted
        trackedWindow = window
        followWindow()
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

    private func observeStorageBarEnabled() {
        withObservationTracking {
            _ = settings.finderStorageBarEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStorageBarEnabled()
                self?.storageBarEnabledDidChange()
            }
        }
    }

    private var tracksFinder: Bool { settings.finderPreviewEnabled || settings.finderStorageBarEnabled }

    private var isTracking: Bool { tracker != nil || trackedWindow != nil }

    private var previewDocked: Bool { panel?.isDocked == true && panel?.isVisible == true }

    private func observePreviewSettings() {
        withObservationTracking {
            _ = settings.finderPreview
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePreviewSettings()
                self?.previewSettingsDidChange()
            }
        }
    }

    private func previewSettingsDidChange() {
        let preview = settings.finderPreview
        let changed =
            preview.disabledKinds != observedDisabledKinds || preview.trustedFolders != observedTrustedFolders
        observedDisabledKinds = preview.disabledKinds
        observedTrustedFolders = preview.trustedFolders
        guard changed, state.selectedURL != nil else { return }
        select(state.selectedIndex)
    }

    private func enabledDidChange() {
        enabledChanged?()
        guard settings.finderPreviewEnabled else {
            guard tracksFinder else { return detach() }
            mayAskConsent = false
            consecutiveSelectionFailures = 0
            clearSelection()
            state.notice = nil
            dismissPanel()
            return updateStorageBar()
        }
        needsSlide = true
        mayAskConsent = true
        storageBarAutomationDenied = false
        consecutiveSelectionFailures = 0
        state.notice = nil
        retryAfter = .distantPast
        generation &+= 1
        guard isTracking else { return attach(prompting: true) }
        followWindow(forceSelectionRead: true)
    }

    private func storageBarEnabledDidChange() {
        guard settings.finderStorageBarEnabled else {
            storageBarAutomationDenied = false
            storageBar.stop()
            if !tracksFinder { detach() }
            return
        }
        guard isTracking else { return attach(prompting: false) }
        storageBar.start()
        retryAfter = .distantPast
        followWindow(forceSelectionRead: true)
    }

    private func attach(prompting: Bool) {
        guard tracksFinder, !isTracking else { return }
        trusted =
            prompting
            ? AXIsProcessTrustedWithOptions([Self.accessibilityPromptOption: true] as CFDictionary)
            : isTrusted()
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
        tracker.changed = { [weak self] in
            guard let self else { return }
            self.trackedWindow = self.tracker?.target.map {
                TrackedWindow(id: $0.windowID, frame: $0.frame, screen: $0.screen, visible: $0.visible)
            }
            self.followWindow()
        }
        tracker.focused = { [weak self] in self?.readSelection(immediate: true) }
        tracker.ended = { [weak self] in self?.finderEnded() }
        tracker.failed = { [weak self] in self?.trackingStopped() }
        if settings.finderStorageBarEnabled { storageBar.start() }
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

    private func detach(immediately: Bool = false) {
        stopTrustPolling()
        stopTracking()
        state.notice = nil
        mayAskConsent = false
        dismissPanel(immediately: immediately)
    }

    private func dismissPanel(immediately: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        if immediately {
            panel.contentView = nil
            panel.close()
        } else {
            panel.dismiss()
        }
    }

    private func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        tracker?.stop()
        tracker = nil
        trackedWindow = nil
        targetID = nil
        placement = nil
        consecutiveSelectionFailures = 0
        storageBarAutomationDenied = false
        clearSelection()
        storageBar.stop()
    }

    private func applicationDidBecomeActive() {
        guard storageBarAutomationDenied, !settings.finderPreviewEnabled,
            settings.finderStorageBarEnabled, storageBar.wantsSelection
        else { return }
        storageBarAutomationDenied = false
        retryAfter = .distantPast
        readSelection(immediate: true)
    }

    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: Self.trustInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isTrusted() else { return }
                self.attach(prompting: false)
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
        trusted = isTrusted()
        trackingFailed = trusted
        if !trusted { startTrustPolling() }
        updatePresence()
    }

    private func retry() {
        mayAskConsent = true
        storageBarAutomationDenied = false
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
            trackingFailed ? .unavailable : trackedWindow?.visible == true ? .visible : .absent
        switch FinderPreviewPresence(enabled: settings.finderPreviewEnabled, trusted: trusted, window: window) {
        case .hidden: hide()
        case .notice: showNotice(trusted ? .unavailable : .accessibility)
        case .docked: dock()
        }
        updateStorageBar()
    }

    private func updateStorageBar() {
        guard settings.finderStorageBarEnabled, let target = trackedWindow, target.visible else {
            return storageBar.follow(nil)
        }
        storageBar.follow(
            .init(id: target.id, frame: target.frame, preview: previewDocked ? placement : nil))
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
        guard let target = trackedWindow else { return }
        if !state.docked { state.notice = nil }
        state.docked = true
        let panel = preparedPanel(docked: true)
        let placement = FinderPreviewGeometry.placement(
            window: target.frame, screen: target.screen, width: panel.previewWidth)
        self.placement = placement
        state.dock = placement.dock
        panel.dock(placement, above: target.id, animate: needsSlide && !panel.isVisible)
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
        guard let panel, let placement, let target = trackedWindow else { return }
        panel.setPreviewWidth(
            FinderPreviewGeometry.resizedWidth(
                placement, pointerDelta: pointerDelta, window: target.frame, screen: target.screen))
    }

    private func followWindow(forceSelectionRead: Bool = false) {
        let windowID = trackedWindow?.id
        let changedWindow = windowID != nil && windowID != targetID
        if changedWindow {
            consecutiveSelectionFailures = 0
            clearSelection()
            targetID = windowID
            if state.notice != .automation { state.notice = nil }
        }
        let wasVisible = panel?.isVisible == true || storageBar.wantsSelection
        updatePresence()
        let automationBlocked =
            (previewDocked && state.notice == .automation) || (!previewDocked && storageBarAutomationDenied)
        if (changedWindow || !wasVisible || forceSelectionRead), automationBlocked,
            settings.finderStorageBarEnabled, storageBar.wantsSelection
        {
            storageBar.setView(.unknown)
            storageBar.model.update(selectionCount: nil, folder: nil)
        }
        if changedWindow || !wasVisible || forceSelectionRead { readSelection(immediate: true) }
    }

    func pollSelectionForTesting(immediate: Bool = false) {
        readSelection(immediate: immediate)
    }

    private func readSelection(immediate: Bool = false) {
        guard let target = trackedWindow, target.visible else { return }
        let previewActive = settings.finderPreviewEnabled && previewDocked
        let storageBarActive = settings.finderStorageBarEnabled && storageBar.wantsSelection
        guard previewActive || storageBarActive else { return }
        let finderFrontmost = finderIsFrontmostCheck?() ?? (tracker?.finderIsFrontmost == true)
        guard immediate || finderFrontmost else { return }
        if previewActive {
            guard state.notice != .automation, Date() >= retryAfter else { return }
        } else {
            guard !storageBarAutomationDenied, Date() >= retryAfter else { return }
        }
        let asking = previewActive && mayAskConsent
        let requestedGeneration = generation
        let requestedWindowID = targetID
        reader.read(
            asking: asking,
            isCurrent: { [weak self] in
                guard let self else { return false }
                let frontMatches = self.frontWindowMatchesCheck?() ?? (self.tracker?.frontWindowMatchesTarget() == true)
                guard generation == requestedGeneration, targetID == requestedWindowID, frontMatches else {
                    return false
                }
                if previewActive {
                    return settings.finderPreviewEnabled && previewDocked
                }
                return !settings.finderPreviewEnabled && settings.finderStorageBarEnabled && storageBar.wantsSelection
            }
        ) { [weak self] result in
            guard let self else { return }
            applySelectionResult(
                result, trackedWindowID: requestedWindowID,
                forPreview: previewActive && settings.finderPreviewEnabled)
        }
    }

    func applySelectionResult(
        _ result: Result<FinderSelectionReader.Selection, FinderSelectionReader.Failure>,
        trackedWindowID: CGWindowID?,
        forPreview: Bool = true
    ) {
        switch result {
        case .success(let selection):
            guard selection.windowID == trackedWindowID else {
                logger.error("Finder selection did not match the tracked window")
                selectionFailed(.unavailable, forPreview: forPreview)
                return
            }
            consecutiveSelectionFailures = 0
            storageBarAutomationDenied = false
            if settings.finderStorageBarEnabled {
                storageBar.setView(selection.view)
                storageBar.model.update(
                    selectionCount: selection.urls.count, folder: selection.folder ?? selection.urls.first)
            }
            guard forPreview else { return }
            state.notice = nil
            guard selection.urls != state.urls else { return }
            let previous = state.selectedURL
            state.urls = selection.urls
            select(previous.flatMap { selection.urls.firstIndex(of: $0) } ?? 0)
        case .failure(let failure):
            selectionFailed(failure, forPreview: forPreview)
        }
    }

    private func selectionFailed(_ failure: FinderSelectionReader.Failure, forPreview: Bool) {
        if failure == .automationDenied {
            consecutiveSelectionFailures = 0
            if forPreview {
                clearSelection()
                state.notice = .automation
                retryAfter = Date().addingTimeInterval(Self.failureBackoff)
            } else {
                storageBarAutomationDenied = true
            }
            if settings.finderStorageBarEnabled {
                storageBar.setView(.unknown)
                storageBar.model.update(selectionCount: nil, folder: nil)
            }
            return
        }
        consecutiveSelectionFailures += 1
        guard consecutiveSelectionFailures >= Self.transientFailureThreshold else { return }
        if forPreview {
            clearSelection()
            switch failure {
            case .automationDenied: state.notice = .automation
            case .timedOut: state.notice = .timedOut
            case .unavailable: state.notice = .unavailable
            }
        }
        retryAfter = Date().addingTimeInterval(Self.failureBackoff)
        if settings.finderStorageBarEnabled {
            storageBar.setView(.unknown)
            storageBar.model.update(selectionCount: nil, folder: nil)
        }
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
