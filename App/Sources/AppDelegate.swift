import AppKit
import Engine
import MenuCatalog
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
    private var router: RequestRouter?
    private var statusItem: StatusItemController?
    private var menuFile: MenuFile?
    private var javaAvailable = false
    private var launchFinished = false
    private var pendingURLs: [URL] = []
    private var updateTimer: Timer?

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
        router = RequestRouter(configuration: configuration, jobs: jobs, notifier: notifier) { [weak self] in
            self?.menuFile
        }
        notifier.onUndo = { [weak jobs] in jobs?.undo($0) }
        notifier.onShow = { [weak jobs] in jobs?.showOutputs(of: $0) }
        statusItem = StatusItemController(jobs: jobs, updates: updates) {}
        settings.onChange = { [weak self] in self?.settingsChanged() }
        updates.onNewRelease = { [notifier] release in
            notifier.notify(
                title: String(localized: "MacEase \(release.version) is available", comment: "Update notification"),
                body: String(localized: "Open the menu bar menu to see the release.", comment: "Update notification")
            )
        }
        Task { await finishLaunching(engine: engine, jobs: jobs) }
    }

    private func finishLaunching(engine: JobEngine, jobs: JobCenter) async {
        javaAvailable = await MenuFileWriter.javaRuntimeIsInstalled()
        writeMenuFile()
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

    private func settingsChanged() {
        writeMenuFile()
        let width = settings.settings.effectiveConcurrency
        if let engine = jobs?.engine { Task { await engine.setConcurrency(width) } }
    }

    private func writeMenuFile() {
        do {
            menuFile = try MenuFileWriter(configuration: configuration).write(
                hiddenOperations: settings.hiddenOperations,
                aiEnabled: settings.settings.intelligence.aiEnabled,
                javaAvailable: javaAvailable
            )
        } catch {
            logger.error("Menu file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
