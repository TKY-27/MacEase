import AppKit
import Engine
import Observation
import SwiftUI

@MainActor
@Observable
final class OrganizationController {
    struct RecentMove: Identifiable {
        let id: String
        let batch: BatchRecord
        let move: OrganizationMoveRecord
    }

    private(set) var registrations: [OrganizationRegistration] = []
    var selectedRoot: UUID?
    var proposals: [OrganizationProposal] = []
    var policy = OrganizationPolicy()
    var categoriesText = OrganizationPolicy().categories.joined(separator: "\n")
    var search = ""
    var showingRecent = false
    private(set) var recent: [RecentMove] = []
    private(set) var hasPreview = false
    private(set) var isScanning = false
    private(set) var isApplying = false
    private(set) var status = ""
    private(set) var canSave = true
    var failure: String?
    @ObservationIgnored private let jobs: JobCenter
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let persistence: OrganizationStore
    @ObservationIgnored private let classifier = OrganizationClassifier()
    @ObservationIgnored private var watchers: [UUID: OrganizationWatcher] = [:]
    @ObservationIgnored private var checks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var trackers: [UUID: OrganizationStability] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var window: NSWindowController?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var batchTasks: [UUID: Task<BatchOutcome?, Never>] = [:]
    @ObservationIgnored private var processingRoots: Set<UUID> = []
    @ObservationIgnored private var changedCategories: Set<URL> = []
    @ObservationIgnored private var held: [UUID: [OrganizationProposal]] = [:]
    @ObservationIgnored private var dirtyRoots: Set<UUID> = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(jobs: JobCenter, store: SettingsStore, supportDirectory: URL) {
        self.jobs = jobs
        settings = store
        persistence = OrganizationStore(supportDirectory: supportDirectory)
    }

    var selected: OrganizationRegistration? { registrations.first { $0.id == selectedRoot } }
    var readyCount: Int { proposals.filter { $0.category != nil }.count }
    var filteredRecent: [RecentMove] {
        recent.filter {
            search.isEmpty || ($0.move.from.path + "\n" + $0.move.to.path).localizedCaseInsensitiveContains(search)
        }
    }

    func start() async {
        if let loading {
            await loading.value
            if stopped { stopped = false; await reconcileAvailableRoots() }
            return
        }
        stopped = false
        let task = Task {
            do {
                registrations = try await persistence.load()
                for index in registrations.indices {
                    do { _ = try registrations[index].resolve() } catch {
                        status = String(localized: "A watched folder is unavailable: \(registrations[index].path)")
                    }
                }
                await persist()
                for registration in registrations where registration.automatic && !registration.paused {
                    watch(registration.id)
                }
                await refreshRecent()
            } catch {
                canSave = false
                failure = String(
                    localized: "Saved organization policies could not be read: \(error.localizedDescription)")
            }
        }
        loading = task
        await task.value
    }

    func stop() {
        stopped = true
        scanTask?.cancel()
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        for task in batchTasks.values { task.cancel() }
        for check in checks.values { check.cancel() }
        checks = [:]
    }

    func reconcileAvailableRoots() async {
        guard !stopped else { return }
        guard settings.planning.intelligence.aiEnabled else {
            scanTask?.cancel()
            for watcher in watchers.values { watcher.stop() }
            watchers = [:]
            for check in checks.values { check.cancel() }
            checks = [:]
            for task in batchTasks.values { task.cancel() }
            status = String(localized: "Automatic organization is paused while Apple Intelligence is disabled")
            return
        }
        for index in registrations.indices {
            do {
                _ = try registrations[index].resolve()
                if registrations[index].automatic && !registrations[index].paused { watch(registrations[index].id) }
            } catch {
                watchers.removeValue(forKey: registrations[index].id)?.stop()
                checks.removeValue(forKey: registrations[index].id)?.cancel()
                status = String(localized: "A watched folder is unavailable: \(registrations[index].path)")
            }
        }
        await persist()
    }

    func open(roots: [URL] = []) {
        if window == nil {
            let host = NSHostingController(rootView: OrganizationView(controller: self))
            let panel = NSWindow(contentViewController: host)
            panel.title = String(localized: "Organize Files")
            panel.setContentSize(NSSize(width: 1_040, height: 680))
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            panel.center()
            window = NSWindowController(window: panel)
        }
        window?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await start()
            for root in roots { await add(root) }
            if let first = roots.first,
                let registration = registrations.first(where: {
                    $0.rootIdentity?.matches(first, directory: true) == true
                })
            {
                select(registration.id)
            } else if selectedRoot == nil, let first = registrations.first {
                select(first.id)
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder")
        guard panel.runModal() == .OK else { return }
        let roots = panel.urls
        Task { for root in roots { await add(root) } }
    }

    private func add(_ selectedRootURL: URL) async {
        guard canSave else { return }
        let root: URL
        do { root = try OrganizationSafety.normalizedRoot(selectedRootURL) } catch {
            failure = error.localizedDescription; return
        }
        if let existing = registrations.first(where: { $0.path == root.path }) { select(existing.id); return }
        do {
            let registration = try OrganizationRegistration(root: root, policy: OrganizationPolicy())
            registrations.append(registration)
            select(registration.id)
            await persist()
            if let suggestion = suggestCategories(saveInitialPolicy: true) { await suggestion.value }
        } catch { failure = error.localizedDescription }
    }

    func select(_ id: UUID) {
        guard !isScanning, !isApplying, let registration = registrations.first(where: { $0.id == id }) else { return }
        selectedRoot = id
        policy = registration.policy
        categoriesText = policy.categories.joined(separator: "\n")
        proposals = held[id] ?? []
        hasPreview = !proposals.isEmpty
        changedCategories = []
        showingRecent = false
    }

    func preview() {
        guard let id = selectedRoot, !isScanning, !isApplying, canSave else { return }
        guard !processingRoots.contains(id) else {
            status = String(localized: "Wait for this folder's current organization to finish")
            return
        }
        scanTask = Task {
            isScanning = true
            hasPreview = false
            defer { isScanning = false }
            do {
                guard settings.planning.intelligence.aiEnabled else {
                    throw EngineError.missingCapability(.appleIntelligence)
                }
                if let index = registrations.firstIndex(where: { $0.id == id }), registrations[index].automatic {
                    registrations[index].paused = true
                    watchers.removeValue(forKey: id)?.stop()
                    checks.removeValue(forKey: id)?.cancel()
                    batchTasks[id]?.cancel()
                }
                try await savePolicy(id)
                guard let registration = registrations.first(where: { $0.id == id }) else { return }
                let root = URL(fileURLWithPath: registration.path)
                let candidates = try await Task.detached { try OrganizationSafety.candidates(in: root) }.value
                proposals = []
                for (index, candidate) in candidates.enumerated() {
                    try Task.checkCancellation()
                    status = String(localized: "Reading \(index + 1) of \(candidates.count)")
                    proposals.append(
                        try await classifier.propose(
                            candidate, policy: registration.policy,
                            corrections: registration.corrections,
                            languageCode: settings.language == .system
                                ? Bundle.main.preferredLocalizations.first ?? "en" : settings.language.rawValue)
                    )
                }
                hasPreview = true
                status = String(localized: "\(readyCount) ready; \(proposals.count - readyCount) held for review")
            } catch is CancellationError { status = String(localized: "Stopped") } catch {
                failure = error.localizedDescription
            }
        }
    }

    @discardableResult
    func suggestCategories(saveInitialPolicy: Bool = false) -> Task<Void, Never>? {
        guard let registration = selected, !isScanning, !isApplying,
            settings.planning.intelligence.aiEnabled
        else { return nil }
        let task = Task {
            isScanning = true
            hasPreview = false
            defer { isScanning = false }
            do {
                let language =
                    settings.language == .system
                    ? Bundle.main.preferredLocalizations.first ?? "en" : settings.language.rawValue
                policy.categories = try await classifier.suggestedCategories(
                    in: URL(fileURLWithPath: registration.path),
                    instructions: policy.instructions, languageCode: language)
                try Task.checkCancellation()
                categoriesText = policy.categories.joined(separator: "\n")
                proposals = []
                if saveInitialPolicy, let index = registrations.firstIndex(where: { $0.id == registration.id }),
                    !registrations[index].automatic
                {
                    registrations[index].policy = policy
                    try await persistence.save(registrations)
                }
                status = String(localized: "Review the suggested categories, then preview the file moves")
            } catch is CancellationError { status = String(localized: "Stopped") } catch {
                status = String(localized: "Category suggestions are unavailable; edit the policy before previewing")
            }
        }
        scanTask = task
        return task
    }

    func cancelPreview() { scanTask?.cancel() }

    private func savePolicy(_ id: UUID) async throws {
        policy.categories = categoriesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        try policy.validate()
        categoriesText = policy.categories.joined(separator: "\n")
        guard let index = registrations.firstIndex(where: { $0.id == id }) else { return }
        if registrations[index].rootIdentity == nil {
            let root = try OrganizationSafety.normalizedRoot(URL(fileURLWithPath: registrations[index].path))
            registrations[index].rootIdentity = try OrganizationIdentity(of: root, directory: true)
            registrations[index].path = root.path
        }
        if registrations[index].policy != policy {
            registrations[index].policy = policy
            registrations[index].automatic = false
            watchers.removeValue(forKey: id)?.stop()
            checks.removeValue(forKey: id)?.cancel()
            trackers[id] = nil
        }
        try await persistence.save(registrations)
    }

    func setCategory(_ category: String?, for source: URL) {
        guard let index = proposals.firstIndex(where: { $0.source == source }) else { return }
        proposals[index].category = category
        changedCategories.insert(source)
    }

    func setName(_ name: String, for source: URL) {
        guard let index = proposals.firstIndex(where: { $0.source == source }) else { return }
        proposals[index].name = name
    }

    func apply(enableAutomatic: Bool) {
        guard let id = selectedRoot, hasPreview, !isApplying, !isScanning, canSave else { return }
        Task {
            isApplying = true
            defer { isApplying = false }
            do {
                guard let index = registrations.firstIndex(where: { $0.id == id }) else { return }
                guard registrations[index].policy == policy,
                    registrations[index].policy.categories.joined(separator: "\n") == categoriesText
                else {
                    throw EngineError.invalidInput(.malformed("Preview the changed policy before applying it"))
                }
                let root = URL(fileURLWithPath: registrations[index].path)
                let plans = try proposals.compactMap { try $0.movePlan(root: root) }
                for proposal in proposals where changedCategories.contains(proposal.source) {
                    if let category = proposal.category, !proposal.fingerprint.isEmpty {
                        registrations[index].corrections.append(
                            OrganizationCorrection(
                                fingerprint: proposal.fingerprint,
                                evidence: proposal.evidence, category: category))
                    }
                }
                watchers.removeValue(forKey: id)?.stop()
                checks.removeValue(forKey: id)?.cancel()
                registrations[index].automatic = enableAutomatic
                registrations[index].paused = false
                try await persistence.save(registrations)
                await run(plans, rootID: id)
                proposals = proposals.filter { proposal in
                    proposal.category == nil || FileManager.default.fileExists(atPath: proposal.source.path)
                }
                if enableAutomatic { watch(id) }
            } catch { failure = error.localizedDescription }
        }
    }

    func togglePause(_ id: UUID) {
        guard let index = registrations.firstIndex(where: { $0.id == id }) else { return }
        registrations[index].paused.toggle()
        if registrations[index].paused { batchTasks[id]?.cancel() }
        watchers.removeValue(forKey: id)?.stop()
        checks.removeValue(forKey: id)?.cancel()
        Task {
            await persist();
            if registrations.contains(where: { $0.id == id && !$0.paused && $0.automatic }) { watch(id) }
        }
    }

    func remove(_ id: UUID) {
        guard !processingRoots.contains(id) else { return }
        watchers.removeValue(forKey: id)?.stop()
        checks.removeValue(forKey: id)?.cancel()
        trackers[id] = nil
        registrations.removeAll { $0.id == id }
        if selectedRoot == id { selectedRoot = nil; proposals = [] }
        Task { await persist() }
    }

    private func persist() async {
        guard canSave else { return }
        do { try await persistence.save(registrations) } catch {
            failure = String(localized: "Organization settings could not be saved: \(error.localizedDescription)")
        }
    }

    private func watch(_ id: UUID) {
        guard !stopped, settings.planning.intelligence.aiEnabled,
            let registration = registrations.first(where: { $0.id == id && $0.automatic && !$0.paused })
        else { return }
        do {
            guard registration.rootIdentity?.matches(URL(fileURLWithPath: registration.path), directory: true) == true
            else {
                throw EngineError.invalidInput(.malformed("The watched folder was replaced"))
            }
            if watchers[id] == nil {
                watchers[id] = try OrganizationWatcher(root: URL(fileURLWithPath: registration.path)) { [weak self] in
                    self?.schedule(id, after: 0)
                }
            }
            schedule(id, after: 0)
        } catch { failure = String(localized: "The folder cannot be watched: \(error.localizedDescription)") }
    }

    private func schedule(_ id: UUID, after delay: TimeInterval) {
        if processingRoots.contains(id) { dirtyRoots.insert(id); return }
        checks[id]?.cancel()
        checks[id] = Task {
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                await reconcile(id)
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }

    private func reconcile(_ id: UUID) async {
        guard !stopped, settings.planning.intelligence.aiEnabled, !processingRoots.contains(id),
            let registration = registrations.first(where: { $0.id == id && $0.automatic && !$0.paused })
        else { return }
        processingRoots.insert(id)
        defer {
            processingRoots.remove(id)
            if dirtyRoots.remove(id) != nil { schedule(id, after: 0) }
        }
        do {
            let root = URL(fileURLWithPath: registration.path)
            guard registration.rootIdentity?.matches(root, directory: true) == true else {
                throw EngineError.invalidInput(.malformed("The watched folder was replaced"))
            }
            let candidates = try await Task.detached { try OrganizationSafety.candidates(in: root) }.value
            var tracker = trackers[id] ?? OrganizationStability()
            let undoSuppressions = await jobs.engine.history.organizationSuppressions
            let inspection = try tracker.inspect(
                candidates, now: Date(), delay: registration.policy.stabilityDelay,
                suppressions: registration.suppressions + undoSuppressions)
            trackers[id] = tracker
            var plans: [OrganizationMovePlan] = []
            for candidate in inspection.ready {
                try Task.checkCancellation()
                let proposal = try await classifier.propose(
                    candidate, policy: registration.policy,
                    corrections: registration.corrections,
                    languageCode: settings.language == .system
                        ? Bundle.main.preferredLocalizations.first ?? "en" : settings.language.rawValue)
                if let plan = try proposal.movePlan(root: root) {
                    plans.append(plan)
                } else {
                    held[id, default: []].removeAll { $0.source == candidate }
                    held[id, default: []].append(proposal)
                    status = String(localized: "Files are held for review in \(registration.path)")
                    if selectedRoot == id, !isScanning {
                        proposals.removeAll { $0.source == candidate }; proposals.append(proposal)
                    }
                }
            }
            guard !stopped, settings.planning.intelligence.aiEnabled,
                registrations.contains(where: { $0.id == id && !$0.paused && $0.automatic })
            else { return }
            if !plans.isEmpty { await run(plans, rootID: id) }
            if let deadline = inspection.nextCheck {
                processingRoots.remove(id)
                schedule(id, after: max(0, deadline.timeIntervalSinceNow))
                processingRoots.insert(id)
            }
        } catch is CancellationError {} catch {
            failure = String(localized: "Automatic organization is held: \(error.localizedDescription)")
        }
    }

    private func run(_ plans: [OrganizationMovePlan], rootID: UUID) async {
        let batch = Batch(
            operation: .folderOrganize,
            items: plans.map { plan in
                WorkItem(inputs: [plan.source]) { context in
                    context.progress(1); return .organize(plan)
                }
            })
        guard !batch.items.isEmpty else { return }
        let task = jobs.run(batch: batch)
        batchTasks[rootID] = task
        let outcome = await task.value
        batchTasks[rootID] = nil
        if let outcome, outcome.historyFailed { failure = String(localized: "Organization history could not be saved") }
        await refreshRecent()
    }

    func refreshRecent() async {
        recent = await jobs.engine.history.records.reversed().flatMap { batch in
            batch.items.enumerated().compactMap { index, record -> RecentMove? in
                guard case .organized(let move) = record else { return nil }
                return RecentMove(id: "\(batch.id)-\(index)", batch: batch, move: move)
            }
        }
    }

    func undo(_ batch: BatchRecord) {
        Task {
            do {
                for record in batch.items {
                    guard case .organized(let move) = record,
                        let index = registrations.firstIndex(where: { $0.path == move.root.path })
                    else { continue }
                    registrations[index].suppressions.append(
                        OrganizationSuppression(path: move.from.path, stamp: move.stamp))
                }
                try await persistence.save(registrations)
                let outcomes = try await jobs.engine.undo(batch.id)
                if outcomes.contains(where: { $0 != .restored }) {
                    status = String(localized: "Some files could not be restored; review Activity")
                }
                await jobs.refreshRecent()
                await refreshRecent()
            } catch { failure = error.localizedDescription }
        }
    }

    func correct(_ recent: RecentMove, category: String) {
        guard category != recent.move.category, settings.planning.intelligence.aiEnabled,
            let index = registrations.firstIndex(where: { $0.path == recent.move.root.path }),
            registrations[index].policy.acceptsCategory(category)
        else { return }
        let registration = registrations[index]
        Task {
            do {
                let proposal = try await classifier.propose(
                    recent.move.to, policy: registration.policy,
                    corrections: registration.corrections,
                    languageCode: settings.language == .system
                        ? Bundle.main.preferredLocalizations.first ?? "en" : settings.language.rawValue)
                guard proposal.stamp == recent.move.stamp else {
                    throw EngineError.invalidInput(.malformed("The file changed"))
                }
                guard let current = registrations.firstIndex(where: { $0.id == registration.id }) else { return }
                registrations[current].corrections.append(
                    OrganizationCorrection(
                        fingerprint: proposal.fingerprint,
                        evidence: proposal.evidence, category: category))
                try await persistence.save(registrations)
                let plan = try OrganizationMovePlan(
                    root: recent.move.root, source: recent.move.to, category: category,
                    isCorrection: true)
                await run([plan], rootID: registration.id)
            } catch { failure = error.localizedDescription }
        }
    }
}
