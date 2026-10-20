import AppKit
import Engine
import MenuCatalog
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let jobs: JobCenter
    private let updates: UpdateChecker
    private let openSettings: () -> Void
    private var animationTimer: Timer?
    private var animationFrame = 0
    private static let animationInterval: TimeInterval = 0.4
    private static let idleSymbol = "wand.and.sparkles"
    private static let busySymbols = ["wand.and.sparkles", "wand.and.sparkles.inverse"]

    init(jobs: JobCenter, updates: UpdateChecker, openSettings: @escaping () -> Void) {
        self.jobs = jobs
        self.updates = updates
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setSymbol(Self.idleSymbol)
        observeActivity()
    }

    private func observeActivity() {
        withObservationTracking {
            _ = jobs.isBusy
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateAnimation()
                self?.observeActivity()
            }
        }
    }

    private func updateAnimation() {
        if jobs.isBusy, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: Self.animationInterval, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.advanceAnimation() }
            }
        } else if !jobs.isBusy {
            animationTimer?.invalidate()
            animationTimer = nil
            setSymbol(Self.idleSymbol)
        }
    }

    private func advanceAnimation() {
        animationFrame = (animationFrame + 1) % Self.busySymbols.count
        setSymbol(Self.busySymbols[animationFrame])
    }

    private func setSymbol(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MacEase")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !jobs.active.isEmpty {
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
        let title = "\(MenuStrings.operation(record.operation)) · \(time)"
        let recentMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if record.undone {
            let undone = NSMenuItem(
                title: String(localized: "Undone", comment: "Recent batch state"), action: nil, keyEquivalent: "")
            undone.isEnabled = false
            submenu.addItem(undone)
        } else {
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
                    Text(verbatim: "\(MenuStrings.operation(batch.operation)) (\(batch.itemCount))")
                        .font(.system(size: 13))
                    ProgressView(value: batch.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                }
                Button(String(localized: "Cancel", comment: "Cancel a running batch")) { jobs.cancel(batchID) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}
