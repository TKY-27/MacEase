import AppKit
import Engine
import FoundationModels
import MenuCatalog
import Observation
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let updateCheckInterval: TimeInterval = 60 * 60

    private let configuration = HostConfiguration.current
    private let logger = Logger(category: "app")
    private let settings = SettingsStore()
    private let folders = FolderAccessStore()
    private let updates = UpdateChecker()
    private lazy var notifier = BatchNotifier(settings: settings)
    private var jobs: JobCenter?
    private var panels: PanelCoordinator?
    private var organization: OrganizationController?
    private lazy var recipeStore = RecipeStore(supportDirectory: configuration.supportDirectory)
    private var recipes: [Recipe] = Recipe.builtIns
    private var recipeObserver: NSObjectProtocol?
    private var activity: ActivityWindow?
    private var router: RequestRouter?
    private var finderService: FinderService?
    private var statusItem: StatusItemController?
    private var menuFile: MenuFile?
    private var javaAvailable = false
    private var capabilityCheckInProgress = false
    private var launchFinished = false
    private var terminationPending = false
    private var pendingURLs: [URL] = []
    private var updateTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsWindow: SingleWindowPresenter?
    private var welcomeWindow: SingleWindowPresenter?
    private var launchedAsLoginItem = false
    private var menuWriteScheduled = false
    private var menuInputs: [OperationID]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine: JobEngine
        do {
            engine = try JobEngine(
                supportDirectory: configuration.supportDirectory,
                concurrency: settings.settings.effectiveConcurrency
            )
        } catch {
            let failure = error as NSError
            logger.fault(
                "Support folder unavailable (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
            NSApp.terminate(nil)
            return
        }
        engine.staging.removeStale()
        let jobs = JobCenter(engine: engine, settings: settings, notifier: notifier)
        self.jobs = jobs
        let organization = OrganizationController(
            jobs: jobs, store: settings, supportDirectory: configuration.supportDirectory)
        self.organization = organization
        let panels = PanelCoordinator(jobs: jobs, store: settings, organization: organization, recipes: recipeStore)
        self.panels = panels
        jobs.presentPanel = { [weak panels] in panels?.present($0, inputs: $1) }
        jobs.presentReport = { [weak panels] in panels?.presentReport($0, operation: $1) }
        jobs.askAgain = { [weak panels] in panels?.askAgain($0, files: $1, reason: $2) ?? false }
        jobs.presentFailure = { [weak panels] in panels?.showFailure($0, message: $1) }
        let activity = ActivityWindow(jobs: jobs, settings: settings)
        self.activity = activity
        jobs.onStart = { [weak activity] in activity?.started($0) }
        jobs.showsFinished = { [weak activity] in activity?.finished($0, outcome: $1) ?? false }
        jobs.onScanEnd = { [weak activity] in activity?.scanEnded($0) }
        router = RequestRouter(
            configuration: configuration, jobs: jobs, notifier: notifier,
            menuFile: { [weak self] in self?.menuFile },
            openApp: { [weak self] in self?.openApp() })
        notifier.onUndo = { [weak jobs] in jobs?.undo($0) }
        notifier.onShow = { [weak jobs] in jobs?.showOutputs(of: $0) }
        makeWindows(jobs: jobs)
        statusItem = StatusItemController(
            jobs: jobs, settings: settings, updates: updates, showProgress: { [weak activity] in activity?.show() }
        ) { [weak self] in self?.showSettings() }
        NSApp.mainMenu = MainMenu.make { [weak self] in self?.showSettings() }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        recipeObserver = NotificationCenter.default.addObserver(
            forName: RecipeStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshRecipes() }
        }
        folders.onChange = { [weak self] in self?.refreshMenuFile() }
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(folderVolumesChanged(_:)), name: name, object: nil)
        }
        updates.onNewRelease = { [notifier] release in
            notifier.notify(
                title: String(localized: "MacEase \(release.version) is available", comment: "Update notification"),
                body: String(localized: "Open the menu bar menu to see the release.", comment: "Update notification")
            )
        }
        refreshMenuFile()
        let service = FinderService(catalog: { [weak self] in self?.menuFile }, jobs: jobs)
        finderService = service
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()
        Task { await finishLaunching(engine: engine, jobs: jobs) }
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false
        if !settings.onboardingCompleted || (isDefaultLaunch && !launchedAsLoginItem) { openApp() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let launch = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem =
            launch?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openApp()
        return false
    }

    private func openApp() {
        if settings.onboardingCompleted {
            showSettings()
        } else {
            welcomeWindow?.show()
        }
    }

    private func showSettings() {
        settingsWindow?.show()
        if launchFinished { Task { await refreshCapabilities() } }
    }

    private func makeWindows(jobs: JobCenter) {
        settingsWindow = SingleWindowPresenter { [unowned self] in
            SettingsWindow.make(
                store: settings, folders: folders, notifier: notifier, jobs: jobs, organization: organization,
                recipes: recipeStore,
                supportDirectory: configuration.supportDirectory,
                showWelcome: { [weak self] in self?.welcomeWindow?.show() },
                rotateToken: { [weak self] in try self?.rotateToken() }
            )
        }
        welcomeWindow = SingleWindowPresenter { [unowned self] in
            let view = WelcomeView(notifier: notifier, folders: folders, isFirstRun: !settings.onboardingCompleted) {
                [weak self] in
                self?.settings.onboardingCompleted = true
                self?.welcomeWindow?.close()
            }
            let content = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: content)
            window.styleMask = [.titled, .closable]
            window.setContentSize(content.view.fittingSize)
            window.title = String(localized: "Welcome to MacEase", comment: "Welcome window title")
            return window
        }
    }

    private func rotateToken() throws {
        try TokenStore.rotate()
        try writeMenuFile()
        Task { await refreshCapabilities() }
    }

    private func finishLaunching(engine: JobEngine, jobs: JobCenter) async {
        observeModelAvailability()
        await refreshCapabilities()
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
        await refreshRecipes()
        await organization?.start()
        await updates.check()
        updateTimer = Timer.scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [updates] _ in
            Task { await updates.check() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshCapabilities()
                await self?.organization?.reconcileAvailableRoots()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard launchFinished else { return }
        Task { await refreshCapabilities() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let jobs else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            do {
                organization?.stop()
                await panels?.closeFeatureWindows()
                try await jobs.prepareForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false
                await organization?.start()
                logger.error("Termination history flush failed: \(error.localizedDescription, privacy: .private)")
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "MacEase could not save undo history.", comment: "Explains why quitting was cancelled")
                alert.informativeText = String(
                    localized: "Quit was cancelled. Check disk space and support folder access, then try again.",
                    comment: "Helps recover from history save failure")
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let recipeObserver { NotificationCenter.default.removeObserver(recipeObserver) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !terminationPending else { return }
        guard launchFinished else {
            pendingURLs += urls
            return
        }
        urls.forEach { router?.route($0) }
    }

    private func settingsChanged() {
        // Parent checkboxes change dozens of entries.
        if !menuWriteScheduled {
            menuWriteScheduled = true
            Task { @MainActor in
                await refreshCapabilities()
            }
        }
        let width = settings.settings.effectiveConcurrency
        if let engine = jobs?.engine { Task { await engine.setConcurrency(width) } }
        Task { await organization?.reconcileAvailableRoots() }
    }

    private func refreshCapabilities() async {
        guard !capabilityCheckInProgress else { return }
        capabilityCheckInProgress = true
        defer { capabilityCheckInProgress = false }
        javaAvailable = await MenuFileWriter.javaRuntimeIsInstalled()
        if menuWriteScheduled || currentMenuInputs != menuInputs {
            menuWriteScheduled = false
            refreshMenuFile()
        }
    }

    private func observeModelAvailability() {
        withObservationTracking {
            _ = SystemLanguageModel.default.availability
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModelAvailability()
                await self?.refreshCapabilities()
            }
        }
    }

    private func refreshMenuFile() {
        do {
            try writeMenuFile()
        } catch {
            let failure = error as NSError
            logger.error(
                "Menu file write failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
        }
    }

    private func writeMenuFile() throws {
        let inputs = currentMenuInputs
        menuFile = try MenuFileWriter(configuration: configuration).write(
            visibleOperations: inputs, hiddenEntries: settings.hiddenEntries, settings: settings.planning,
            monitoredPaths: folders.monitoredPaths, recipes: recipes
        )
        menuInputs = inputs
    }

    private func refreshRecipes() async {
        do {
            recipes = try await recipeStore.recipes()
            refreshMenuFile()
        } catch {
            recipes = []
            refreshMenuFile()
            logger.error("Recipe library unavailable: \(error.localizedDescription, privacy: .private)")
        }
    }

    @objc private func folderVolumesChanged(_ notification: Notification) {
        folders.refreshLocations()
        Task { await organization?.reconcileAvailableRoots() }
    }

    private var currentMenuInputs: [OperationID] {
        let aiAvailable =
            settings.settings.intelligence.aiEnabled
            && SystemLanguageModel.default.availability == .available
        return OperationID.allCases.filter { operation in
            switch operation.requirement {
            case .appleIntelligence: return aiAvailable
            case .java: return javaAvailable
            case nil: return true
            }
        }
    }
}
