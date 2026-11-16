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
    private var generation: UInt64 = 0
    private var targetID: CGWindowID?
    private var needsSlide = true
    private var retryAfter = Date.distantPast
    private var observingTermination = false

    init(panels: PanelCoordinator) { self.panels = panels }

    func toggle() {
        if panel != nil, tracker == nil || tracker?.frontWindowMatchesTarget() == true {
            close()
        } else {
            close()
            open()
        }
    }

    func close() {
        generation &+= 1
        pollTimer?.invalidate()
        pollTimer = nil
        metadataTask?.cancel()
        metadataTask = nil
        tracker?.stop()
        tracker = nil
        targetID = nil
        panel?.delegate = nil
        panel?.contentViewController = nil
        panel?.contentView = nil
        panel?.close()
        panel = nil
        state = FinderPreviewState()
        if observingTermination {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            observingTermination = false
        }
    }

    func windowWillClose(_ notification: Notification) { close() }

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
        let panel = FinderPreviewPanel(docked: trusted)
        self.panel = panel
        panel.delegate = self
        panel.resizePreview = { [weak self] in self?.followWindow() }
        installContent()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        observingTermination = true
        guard trusted else {
            panel.center()
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
            panel.styleMask = [.titled, .closable]
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readSelection() }
        }
        readSelection(immediate: true)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.bundleIdentifier == "com.apple.finder"
        else { return }
        close()
    }

    private func trackingFailed() {
        generation &+= 1
        metadataTask?.cancel()
        clearSelection()
        state.notice = AXIsProcessTrusted() ? .unavailable : .accessibility
        tracker?.stop()
        tracker = nil
        pollTimer?.invalidate()
        pollTimer = nil
        state.docked = false
        panel?.styleMask = [.titled, .closable]
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func followWindow() {
        guard let panel, let target = tracker?.target else {
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
        state.dock = placement.dock
        panel.dock(placement, above: target.windowID, animate: needsSlide)
        needsSlide = false
        if changedWindow || !wasVisible { readSelection(immediate: true) }
    }

    private func readSelection(immediate: Bool = false) {
        guard let panel, panel.isVisible, let tracker, let target = tracker.target, target.visible,
            (immediate || tracker.finderIsFrontmost), Date() >= retryAfter, state.notice != .automation,
            tracker.frontWindowMatchesTarget()
        else { return }
        let requestedGeneration = generation
        reader.read { [weak self] result in
            guard let self, generation == requestedGeneration, self.panel?.isVisible == true,
                self.tracker?.frontWindowMatchesTarget() == true
            else { return }
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
        state.isLoading = false
        state.isFolder = false
        state.folderSummary = nil
        state.fileFailure = nil
        installContent()
    }

    private func select(_ index: Int) {
        generation &+= 1
        metadataTask?.cancel()
        state.selectedIndex = index
        state.isFolder = false
        state.folderSummary = nil
        state.fileFailure = nil
        state.isLoading = state.selectedURL != nil
        installContent()
        guard let url = state.selectedURL else { return }
        let requestedGeneration = generation
        metadataTask = Task { [weak self] in
            let inspection = Task.detached(priority: .utility) { try PreviewFileDetails.read(url) }
            do {
                let details = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
                guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
                state.isLoading = false
                state.isFolder = details.isFolder
                state.folderSummary = details.summary
                installContent()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
                logger.error("Preview file inspection failed: \(error.localizedDescription, privacy: .private)")
                state.isLoading = false
                state.fileFailure = String(localized: "This file could not be read.")
            }
        }
    }

    private func installContent() {
        let canEdit =
            !state.isFolder
            && state.selectedURL.map {
                let kind = FileKind(fileURL: $0)
                return kind == .image || kind == .video
            } == true
        let content = FinderPreviewView(
            state: state, close: { [weak self] in self?.close() },
            retry: { [weak self] in
                self?.close(); self?.open()
            },
            select: { [weak self] in self?.select($0) },
            open: { [weak self] in self?.openFile($0) },
            edit: { [weak self] in self?.editFile($0) }, canEdit: canEdit,
            resize: { [weak self] delta in
                guard let self, let panel else { return }
                let adjustment = state.dock == .left ? delta : -delta
                panel.setPreviewWidth(panel.previewWidth + adjustment)
            })
        if let hosting = panel?.contentViewController as? NSHostingController<FinderPreviewView> {
            hosting.rootView = content
        } else {
            panel?.contentViewController = NSHostingController(rootView: content)
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

private struct PreviewFileDetails: Sendable {
    let isFolder: Bool
    let summary: String?
    private static let entryLimit = 100_000
    private static let timeLimit: TimeInterval = 2

    static func read(_ url: URL) throws -> Self {
        let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey])
        guard attributes.isDirectory == true else {
            guard attributes.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            return Self(isFolder: false, summary: nil)
        }
        if attributes.isPackage == true { return Self(isFolder: false, summary: nil) }
        var enumerationFailure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                errorHandler: { _, error in
                    enumerationFailure = error; return false
                })
        else { throw CocoaError(.fileReadUnknown) }
        let deadline = Date().addingTimeInterval(timeLimit)
        var count = 0
        var scanned = 0
        var bytes: Int64 = 0
        while let child = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            scanned += 1
            guard scanned <= entryLimit, Date() < deadline else { throw CocoaError(.fileReadTooLarge) }
            if enumerator.level == 1 { count += 1 }
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, let size = values.fileSize { bytes += Int64(size) }
        }
        if let enumerationFailure { throw enumerationFailure }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return Self(isFolder: true, summary: String(localized: "\(count) items · \(size)"))
    }
}
