import AppKit
import Engine
import FinderSync
import MenuCatalog
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let jobs: JobCenter
    private let settings: SettingsStore
    private let updates: UpdateChecker
    private let showProgress: () -> Void
    private let openSettings: () -> Void
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var needsAttention = false
    private static let animationInterval: TimeInterval = 0.4
    private static let idleImage = "StatusIdle"
    private static let busyImages = ["StatusBusy1", "StatusBusy2", "StatusBusy3"]
    private static let reducedMotionBusyImage = "StatusBusyStatic"
    private static let attentionImage = "StatusAttention"
    private static let idleLabel = "MacEase"
    private static var busyLabel: String {
        String(localized: "MacEase, processing", comment: "Menu bar icon VoiceOver label while busy")
    }
    private static var attentionLabel: String {
        String(localized: "MacEase, needs attention", comment: "Menu bar icon VoiceOver label after a problem")
    }

    init(
        jobs: JobCenter, settings: SettingsStore, updates: UpdateChecker, showProgress: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.jobs = jobs
        self.settings = settings
        self.updates = updates
        self.showProgress = showProgress
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        checkFinderExtension()
        track({ [jobs] in _ = jobs.isBusy }) { [weak self] in self?.updateImage() }
        track({ [jobs] in _ = jobs.completed }) { [weak self] in self?.batchCompleted() }
        track({ [settings] in _ = settings.onboardingCompleted }) { [weak self] in self?.checkFinderExtension() }
    }

    private func track(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking(read) { [weak self] in
            Task { @MainActor in
                onChange()
                self?.track(read, onChange: onChange)
            }
        }
    }

    private func batchCompleted() {
        needsAttention = jobs.completed.first?.hasFailures ?? false
        updateImage()
    }

    private func checkFinderExtension() {
        if settings.onboardingCompleted, !FIFinderSyncController.isExtensionEnabled { needsAttention = true }
        updateImage()
    }

    private func updateImage() {
        if jobs.isBusy, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimation(showing: Self.reducedMotionBusyImage, label: Self.busyLabel)
        } else if jobs.isBusy, animationTimer == nil {
            animationFrame = 0
            setImage(Self.busyImages[animationFrame], label: Self.busyLabel)
            animationTimer = Timer.scheduledTimer(withTimeInterval: Self.animationInterval, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.advanceAnimation() }
            }
        } else if !jobs.isBusy, needsAttention {
            stopAnimation(showing: Self.attentionImage, label: Self.attentionLabel)
        } else if !jobs.isBusy {
            stopAnimation(showing: Self.idleImage, label: Self.idleLabel)
        }
    }

    private func stopAnimation(showing name: String, label: String) {
        animationTimer?.invalidate()
        animationTimer = nil
        setImage(name, label: label)
    }

    private func advanceAnimation() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return stopAnimation(showing: Self.reducedMotionBusyImage, label: Self.busyLabel)
        }
        animationFrame = (animationFrame + 1) % Self.busyImages.count
        setImage(Self.busyImages[animationFrame], label: Self.busyLabel)
    }

    // The catalog marks these as template images.
    private func setImage(_ name: String, label: String) {
        let image = NSImage(named: name)
        image?.accessibilityDescription = label
        statusItem.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) {
        needsAttention = false
        updateImage()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if settings.onboardingCompleted, !FIFinderSyncController.isExtensionEnabled {
            menu.addItem(
                ClosureMenuItem(title: String(localized: "Turn On Finder Extension…", comment: "Menu bar item")) {
                    FIFinderSyncController.showExtensionManagementInterface()
                })
            menu.addItem(.separator())
        }
        if !jobs.active.isEmpty || !jobs.pausedExtractions.isEmpty {
            menu.addItem(
                ClosureMenuItem(title: String(localized: "Show Progress", comment: "Menu bar item")) {
                    [showProgress] in
                    showProgress()
                })
            menu.addItem(.separator())
            menu.addItem(
                NSMenuItem.sectionHeader(title: String(localized: "In Progress", comment: "Menu bar section title")))
            for batch in jobs.active {
                let menuItem = NSMenuItem()
                let row = ActiveBatchRow(jobs: jobs, batchID: batch.id)
                let host = NSHostingView(rootView: row)
                host.frame.size = host.fittingSize
                menuItem.view = host
                menu.addItem(menuItem)
            }
            menu.addItem(.separator())
        }
        if !jobs.completed.isEmpty {
            menu.addItem(
                NSMenuItem.sectionHeader(title: String(localized: "Results", comment: "Menu bar section title")))
            for batch in jobs.completed {
                let time = batch.date.formatted(date: .omitted, time: .shortened)
                let title = String(
                    localized: "\(batch.summary.title) · \(time)…", comment: "Completed batch result menu item")
                menu.addItem(
                    ClosureMenuItem(title: title) { [jobs] in jobs.showResult(batch) })
            }
            menu.addItem(.separator())
        }
        if !jobs.recent.isEmpty {
            menu.addItem(
                NSMenuItem.sectionHeader(title: String(localized: "Recent", comment: "Menu bar section title")))
            for record in jobs.recent {
                menu.addItem(recentItem(record))
            }
            menu.addItem(.separator())
        }
        if let release = updates.availableRelease {
            let title = String(localized: "MacEase \(release.version) Is Available…", comment: "Menu bar update item")
            menu.addItem(ClosureMenuItem(title: title, keyEquivalent: "") { NSWorkspace.shared.open(release.pageURL) })
        }
        menu.addItem(
            ClosureMenuItem(title: String(localized: "Settings…", comment: "Menu bar item"), keyEquivalent: ",") {
                [openSettings] in
                openSettings()
            })
        menu.addItem(
            ClosureMenuItem(title: String(localized: "Check for Updates", comment: "Menu bar item")) { [updates] in
                Task { await updates.check(force: true) }
            })
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(title: String(localized: "Quit MacEase", comment: "Menu bar item"), keyEquivalent: "q") {
                NSApp.terminate(nil)
            })
    }

    private func recentItem(_ record: BatchRecord) -> NSMenuItem {
        let time = record.date.formatted(date: .omitted, time: .shortened)
        let title = "\(MenuStrings.operationName(record.operation)) · \(time)"
        let recentMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if record.undone {
            let undone = NSMenuItem(
                title: String(localized: "Undone", comment: "Recent batch state"), action: nil, keyEquivalent: "")
            undone.isEnabled = false
            submenu.addItem(undone)
        } else if jobs.canUndo(record.id) {
            submenu.addItem(
                ClosureMenuItem(title: String(localized: "Undo", comment: "Menu bar recent batch action")) { [jobs] in
                    jobs.undo(record.id)
                })
        }
        submenu.addItem(
            ClosureMenuItem(title: String(localized: "Show in Finder", comment: "Menu bar recent batch action")) {
                [jobs] in
                jobs.showOutputs(of: record.id)
            })
        recentMenuItem.submenu = submenu
        return recentMenuItem
    }

}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}

private struct ActiveBatchRow: View {
    let jobs: JobCenter
    let batchID: UUID

    var body: some View {
        if let batch = jobs.active.first(where: { $0.id == batchID }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(MenuStrings.operationName(batch.operation)) (\(batch.itemCount))")
                        .font(.system(size: 13))
                    ProgressView(value: batch.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                }
                Button(
                    batch.operation == .archiveHatchExtract
                        ? String(localized: "Pause") : String(localized: "Cancel", comment: "Cancel a running batch")
                ) { jobs.cancel(batchID) }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}
