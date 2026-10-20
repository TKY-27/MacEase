import AppKit
import Engine
import MenuCatalog
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let updateCheckInterval: TimeInterval = 60 * 60

    private let configuration = HostConfiguration.current
    private let logger = Logger(category: "app")
    private let settings = SettingsStore()
    private let updates = UpdateChecker()
    private lazy var notifier = BatchNotifier(settings: settings)
    private var jobs: JobCenter?
    private var panels: PanelCoordinator?
    private var router: RequestRouter?
    private var statusItem: StatusItemController?
    private var menuFile: MenuFile?
    private var javaAvailable = false
    private var launchFinished = false
    private var pendingURLs: [URL] = []
    private var updateTimer: Timer?
    private var settingsWindow: SingleWindowPresenter?
    private var onboardingWindow: SingleWindowPresenter?
    private var menuInputs: MenuInputs?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine: JobEngine
        do {
            engine = try JobEngine(
                supportDirectory: configuration.supportDirectory,
                concurrency: settings.settings.effectiveConcurrency
            )
        } catch {
            logger.fault("Support folder unavailable: \(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
            return
        }
        engine.staging.removeStale()
        let jobs = JobCenter(engine: engine, settings: settings, notifier: notifier)
        self.jobs = jobs
        let panels = PanelCoordinator(jobs: jobs, store: settings, supportDirectory: configuration.supportDirectory)
        self.panels = panels
        jobs.presentPanel = { [weak panels] in panels?.present($0, inputs: $1) }
        jobs.presentReport = { [weak panels] in panels?.presentReport($0, operation: $1) }
        jobs.askAgain = { [weak panels] in panels?.askAgain($0, files: $1, reason: $2) ?? false }
        router = RequestRouter(configuration: configuration, jobs: jobs, notifier: notifier) { [weak self] in
            self?.menuFile
        }
        notifier.onUndo = { [weak jobs] in jobs?.undo($0) }
        notifier.onShow = { [weak jobs] in jobs?.showOutputs(of: $0) }
        makeWindows(jobs: jobs)
        statusItem = StatusItemController(jobs: jobs, updates: updates) { [weak self] in self?.settingsWindow?.show() }
        NSApp.mainMenu = MainMenu.make { [weak self] in self?.settingsWindow?.show() }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        updates.onNewRelease = { [notifier] release in
            notifier.notify(
                title: String(localized: "MacEase \(release.version) is available", comment: "Update notification"),
                body: String(localized: "Open the menu bar menu to see the release.", comment: "Update notification")
            )
        }
        Task { await finishLaunching(engine: engine, jobs: jobs) }
        if !settings.onboardingCompleted { onboardingWindow?.show() }
    }

    private func makeWindows(jobs: JobCenter) {
        settingsWindow = SingleWindowPresenter { [unowned self] in
            SettingsWindow.make(
                store: settings, notifier: notifier, jobs: jobs, supportDirectory: configuration.supportDirectory,
                showOnboarding: { [weak self] in self?.onboardingWindow?.show() },
                rotateToken: { [weak self] in try self?.rotateToken() }
            )
        }
        onboardingWindow = SingleWindowPresenter { [unowned self] in
            let view = OnboardingView(notifier: notifier, isFirstRun: !settings.onboardingCompleted) {
                [weak self] in
                self?.settings.onboardingCompleted = true
                self?.onboardingWindow?.close()
            }
            let content = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: content)
            window.styleMask = [.titled, .closable]
            window.setContentSize(content.view.fittingSize)
            window.title = String(localized: "Welcome to MacEase", comment: "Onboarding window title")
            return window
        }
    }

    private func rotateToken() throws {
        try TokenStore.rotate()
        try writeMenuFile()
    }

    private func finishLaunching(engine: JobEngine, jobs: JobCenter) async {
        javaAvailable = await MenuFileWriter.javaRuntimeIsInstalled()
        refreshMenuFile()
        launchFinished = true
        let queued = pendingURLs
        pendingURLs = []
        queued.forEach { router?.route($0) }
        if let setAside = await engine.history.setAsideFile {
            notifier.notify(
                title: String(localized: "History was reset", comment: "Notification after unreadable history"),
                body: String(localized: "The old history was kept as \(setAside.lastPathComponent).")
            )
        }
        await jobs.refreshRecent()
        await updates.check()
        updateTimer = Timer.scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [updates] _ in
            Task { await updates.check() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launchFinished else {
            pendingURLs += urls
            return
        }
        urls.forEach { router?.route($0) }
    }

    /// Slider drags fire many changes per second.
    private func settingsChanged() {
        if currentMenuInputs != menuInputs { refreshMenuFile() }
        let width = settings.settings.effectiveConcurrency
        if let engine = jobs?.engine { Task { await engine.setConcurrency(width) } }
    }

    private func refreshMenuFile() {
        do {
            try writeMenuFile()
        } catch {
            logger.error("Menu file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeMenuFile() throws {
        let inputs = currentMenuInputs
        menuFile = try MenuFileWriter(configuration: configuration).write(
            hiddenOperations: inputs.hiddenOperations,
            aiEnabled: inputs.aiEnabled,
            javaAvailable: javaAvailable
        )
        menuInputs = inputs
    }

    private var currentMenuInputs: MenuInputs {
        MenuInputs(hiddenOperations: settings.hiddenOperations, aiEnabled: settings.settings.intelligence.aiEnabled)
    }

    private struct MenuInputs: Equatable {
        let hiddenOperations: Set<OperationID>
        let aiEnabled: Bool
    }
}
