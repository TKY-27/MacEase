import AppKit
import ApplicationServices
import Engine
import MenuCatalog
import SwiftUI
import os

@MainActor
final class FinderPreviewCoordinator: NSObject, NSWindowDelegate {
    private let panels: PanelCoordinator
    private let reader = FinderSelectionReader()
    private let logger = Logger(category: "finder-preview")
    private var tracker: FinderWindowTracker?
    private var panel: FinderPreviewPanel?
    private var state = FinderPreviewState()
    private var pollTimer: Timer?
    private var metadataTask: Task<Void, Never>?
    private var generation: UInt64 = 0 {
        didSet { state.generation = generation }
    }
    private var targetID: CGWindowID?
    private var placement: FinderPreviewGeometry.Placement?
    private var needsSlide = true
    private var retryAfter = Date.distantPast
    private var observingTermination = false
    var visibilityChanged: (() -> Void)?

    init(panels: PanelCoordinator) {
        self.panels = panels
    }

    var isOpen: Bool { panel != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil
        panel.dismiss()
        stop()
    }

    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        stop()
    }

    private func stop() {
        generation &+= 1
        pollTimer?.invalidate()
        pollTimer = nil
        metadataTask?.cancel()
        metadataTask = nil
        tracker?.stop()
        tracker = nil
        targetID = nil
        placement = nil
        panel = nil
        state = FinderPreviewState()
        if observingTermination {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            observingTermination = false
        }
        visibilityChanged?()
    }

    // Value of kAXTrustedCheckOptionPrompt, which isn't Sendable.
    private static let accessibilityPromptOption = "AXTrustedCheckOptionPrompt"

    private func open() {
        needsSlide = true
        retryAfter = .distantPast
        let trusted = AXIsProcessTrustedWithOptions([Self.accessibilityPromptOption: true] as CFDictionary)
        state.docked = trusted
        if !trusted {
            logger.notice("Finder Preview requires Accessibility permission")
            state.notice = .accessibility
        }
        let content = NSHostingView(rootView: makeView())
        content.sizingOptions = []
        let panel = FinderPreviewPanel(content: content, docked: trusted)
        self.panel = panel
        panel.delegate = self
        panel.resizePreview = { [weak self] in self?.followWindow() }
        panel.closeRequested = { [weak self] in self?.close() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        observingTermination = true
        visibilityChanged?()
        guard trusted else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let tracker = FinderWindowTracker()
        self.tracker = tracker
        tracker.changed = { [weak self] in self?.followWindow() }
        tracker.focused = { [weak self] in self?.readSelection(immediate: true) }
        tracker.ended = { [weak self] in self?.close() }
        tracker.failed = { [weak self] in self?.trackingFailed() }
        do {
            try tracker.start()
        } catch {
            logger.error("Finder preview could not dock: \(error.localizedDescription, privacy: .private)")
            tracker.stop()
            self.tracker = nil
            state.notice = .unavailable
            state.docked = false
            panel.undock()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readSelection() }
        }
        readSelection(immediate: true)
    }

    private func makeView() -> FinderPreviewView {
        FinderPreviewView(
            state: state, close: { [weak self] in self?.close() },
            retry: { [weak self] in
                self?.close()
                self?.open()
            },
            select: { [weak self] in self?.select($0) },
            open: { [weak self] in self?.openFile($0) },
            edit: { [weak self] in self?.editFile($0) },
            resize: { [weak self] in self?.resize(by: $0) })
    }

    private func resize(by pointerDelta: CGFloat) {
        guard let panel, let placement, let target = tracker?.target else { return }
        panel.setPreviewWidth(
            FinderPreviewGeometry.resizedWidth(
                placement, pointerDelta: pointerDelta, window: target.frame, screen: target.screen))
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.bundleIdentifier == "com.apple.finder"
        else { return }
        close()
    }

    private func trackingFailed() {
        tracker?.stop()
        tracker = nil
        pollTimer?.invalidate()
        pollTimer = nil
        generation &+= 1
        metadataTask?.cancel()
        clearSelection()
        state.notice = AXIsProcessTrusted() ? .unavailable : .accessibility
        state.docked = false
        placement = nil
        panel?.undock()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func followWindow() {
        guard let panel, let target = tracker?.target else {
            generation &+= 1
            metadataTask?.cancel()
            clearSelection()
            panel?.orderOut(nil)
            return
        }
        let changedWindow = targetID != target.windowID
        if changedWindow {
            generation &+= 1
            metadataTask?.cancel()
            targetID = target.windowID
            clearSelection()
            if state.notice != .automation { state.notice = nil }
        }
        guard target.visible else {
            if panel.isVisible {
                generation &+= 1
                metadataTask?.cancel()
                clearSelection()
                panel.orderOut(nil)
            }
            return
        }
        let wasVisible = panel.isVisible
        let placement = FinderPreviewGeometry.placement(
            window: target.frame, screen: target.screen, width: panel.previewWidth)
        self.placement = placement
        state.dock = placement.dock
        panel.dock(placement, above: target.windowID, animate: needsSlide)
        needsSlide = false
        if changedWindow || !wasVisible { readSelection(immediate: true) }
    }

    private func readSelection(immediate: Bool = false) {
        guard let panel, panel.isVisible, let tracker, let target = tracker.target, target.visible,
            (immediate || tracker.finderIsFrontmost), Date() >= retryAfter, state.notice != .automation
        else { return }
        let requestedGeneration = generation
        reader.read(isCurrent: { [weak self] in
            guard let self else { return false }
            return generation == requestedGeneration && self.panel?.isVisible == true
                && self.tracker?.frontWindowMatchesTarget() == true
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let selection):
                guard selection.windowID == targetID else {
                    logger.error("Finder selection did not match the tracked window")
                    selectionFailed(.unavailable)
                    return
                }
                state.notice = nil
                guard selection.urls != state.urls else { return }
                let previous = state.selectedURL
                state.urls = selection.urls
                select(previous.flatMap { selection.urls.firstIndex(of: $0) } ?? 0)
            case .failure(let failure): selectionFailed(failure)
            }
        }
    }

    private func selectionFailed(_ failure: FinderSelectionReader.Failure) {
        generation &+= 1
        metadataTask?.cancel()
        clearSelection()
        switch failure {
        case .automationDenied: state.notice = .automation
        case .timedOut: state.notice = .timedOut
        case .unavailable: state.notice = .unavailable
        }
        retryAfter = Date().addingTimeInterval(2)
    }

    private func clearSelection() {
        state.urls = []
        state.selectedIndex = 0
        state.details = nil
        state.fileFailure = nil
    }

    private func select(_ index: Int) {
        generation &+= 1
        metadataTask?.cancel()
        state.selectedIndex = index
        state.details = nil
        state.fileFailure = nil
        guard let url = state.selectedURL else { return }
        let requestedGeneration = generation
        metadataTask = Task { [weak self] in
            let inspection = Task.detached(priority: .utility) { try await PreviewFileDetails.read(url) }
            do {
                let details = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
                guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
                state.details = details
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
                logger.error("Preview file inspection failed: \(error.localizedDescription, privacy: .private)")
                state.fileFailure = String(localized: "This file could not be read.")
            }
        }
    }

    private func openFile(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            logger.error("No application opened the preview file")
            state.fileFailure = String(localized: "This file could not be opened.")
        }
    }

    private func editFile(_ url: URL) {
        let operation: OperationID = FileKind(fileURL: url) == .video ? .videoEdit : .imageEdit
        panels.present(MenuEntry(op: operation, preset: nil, path: []), inputs: [url])
    }
}
