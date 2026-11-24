import AppKit
import Engine
import XCTest
import os

@testable import MacEase

@MainActor
final class MenuBarSettingsTests: XCTestCase {
    private static let waitLimit: Duration = .seconds(5)
    private static let pollInterval: Duration = .milliseconds(10)

    private func makeDefaults() throws -> UserDefaults {
        let suite = "MacEaseMenuBarSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MenuBarSettingsTests-\(UUID())")
        addTeardownBlock {
            do { try FileManager.default.removeItem(at: directory) } catch {
                XCTFail("Fixture cleanup failed: \(error)")
            }
        }
        return directory
    }

    private func makeController(settings: SettingsStore, jobs: JobCenter, defaults: UserDefaults)
        -> StatusItemController
    {
        let controller = StatusItemController(
            jobs: jobs, settings: settings, updates: UpdateChecker(settings: settings, defaults: defaults),
            showProgress: {}, openUpdate: {}, openSettings: {})
        addTeardownBlock { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        return controller
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + Self.waitLimit
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time") }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func updateChecker(automatic: Bool, defaults: UserDefaults) -> UpdateChecker {
        let settings = SettingsStore(defaults: defaults)
        settings.checksForUpdatesAutomatically = automatic
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewerReleaseStub.self]
        return UpdateChecker(settings: settings, defaults: defaults, session: URLSession(configuration: configuration))
    }

    func testOldSettingsLoadWithMenuBarAndUpdateChecksOn() throws {
        let defaults = try makeDefaults()
        defaults.set(try JSONEncoder().encode(Engine.Settings()), forKey: Engine.Settings.defaultsKey)
        defaults.set(false, forKey: "notificationsEnabled")
        defaults.set(true, forKey: "onboardingCompleted")

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.checksForUpdatesAutomatically)
        XCTAssertTrue(store.showsStatusItem)
        XCTAssertTrue(store.showsRecentOperations)
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertTrue(store.onboardingCompleted)

        store.checksForUpdatesAutomatically = false
        store.showsStatusItem = false
        store.showsRecentOperations = false
        let relaunched = SettingsStore(defaults: defaults)
        XCTAssertFalse(relaunched.checksForUpdatesAutomatically)
        XCTAssertFalse(relaunched.showsStatusItem)
        XCTAssertFalse(relaunched.showsRecentOperations)

        relaunched.resetAll()
        let reset = SettingsStore(defaults: defaults)
        XCTAssertTrue(reset.checksForUpdatesAutomatically)
        XCTAssertTrue(reset.showsStatusItem)
        XCTAssertTrue(reset.showsRecentOperations)
    }

    func testAutomaticUpdateCheckIsSkippedWhenTurnedOff() async throws {
        let defaults = try makeDefaults()
        let checker = updateChecker(automatic: false, defaults: defaults)
        await checker.check()
        XCTAssertNil(checker.availableRelease)
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheck"))
    }

    func testManualUpdateCheckRunsWhenAutomaticChecksAreOff() async throws {
        let checker = updateChecker(automatic: false, defaults: try makeDefaults())
        await checker.check(force: true)
        XCTAssertEqual(checker.availableRelease?.version, NewerReleaseStub.version)
    }

    func testAutomaticUpdateCheckRunsWhenTurnedOn() async throws {
        let checker = updateChecker(automatic: true, defaults: try makeDefaults())
        await checker.check()
        XCTAssertEqual(checker.availableRelease?.version, NewerReleaseStub.version)
    }

    func testStatusItemFollowsShowInMenuBar() async throws {
        let defaults = try makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        let engine = try JobEngine(supportDirectory: makeDirectory(), concurrency: 1)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: BatchNotifier(settings: settings))
        let controller = makeController(settings: settings, jobs: jobs, defaults: defaults)
        XCTAssertTrue(controller.statusItem.isVisible)

        settings.showsStatusItem = false
        try await waitUntil { !controller.statusItem.isVisible }
        settings.showsStatusItem = true
        try await waitUntil { controller.statusItem.isVisible }

        settings.showsStatusItem = false
        let relaunched = makeController(settings: SettingsStore(defaults: defaults), jobs: jobs, defaults: defaults)
        XCTAssertFalse(relaunched.statusItem.isVisible)
    }

    func testHidingRecentKeepsInProgressAndResults() async throws {
        let defaults = try makeDefaults()
        let directory = makeDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: directory, concurrency: 1)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: BatchNotifier(settings: settings))
        let controller = makeController(settings: settings, jobs: jobs, defaults: defaults)
        _ = await engine.saveReport("report", to: directory.appending(path: "report.txt"), operation: .folderAnalyze)
        let input = directory.appending(path: "input.txt")
        try Data("fixture".utf8).write(to: input)
        let skip = WorkItem(inputs: [input]) { _ in .skipped(.alreadyDone) }
        _ = await jobs.run(batch: Batch(operation: .imageConvert, items: [skip])).value
        await jobs.refreshRecent()
        let released = OSAllocatedUnfairLock(initialState: false)
        let held = WorkItem(inputs: [input]) { _ in
            while !released.withLock({ $0 }) { try await Task.sleep(for: heldItemPoll) }
            return .skipped(.alreadyDone)
        }
        let running = jobs.run(batch: Batch(operation: .imageConvert, items: [held]))
        try await waitUntil { !jobs.active.isEmpty }

        let recent = String(localized: "Recent")
        let sections = [String(localized: "In Progress"), String(localized: "Results")]
        XCTAssertTrue(menuTitles(controller).contains(recent))
        settings.showsRecentOperations = false
        let titles = menuTitles(controller)
        XCTAssertFalse(titles.contains(recent))
        XCTAssertTrue(sections.allSatisfy(titles.contains), "\(titles)")

        released.withLock { $0 = true }
        _ = await running.value
    }

    func testFinderPreviewItemReflectsAndTogglesThePreview() throws {
        let defaults = try makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        let engine = try JobEngine(supportDirectory: makeDirectory(), concurrency: 1)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: BatchNotifier(settings: settings))
        let controller = makeController(settings: settings, jobs: jobs, defaults: defaults)

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let index = menu.indexOfItem(withTitle: String(localized: "Finder Preview"))
        XCTAssertNotEqual(index, -1)
        XCTAssertEqual(menu.item(at: index)?.state, .off)
        menu.performActionForItem(at: index)
        XCTAssertTrue(SettingsStore(defaults: defaults).finderPreviewEnabled)

        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.item(withTitle: String(localized: "Finder Preview"))?.state, .on)
    }

    private func menuTitles(_ controller: StatusItemController) -> [String] {
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }
}

private let heldItemPoll: Duration = .milliseconds(10)

/// Answers every request with a newer release.
private final class NewerReleaseStub: URLProtocol {
    static let version: String = {
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let major = running.flatMap(SemanticVersion.init)?.components.first else {
            preconditionFailure("The app version must be semantic")
        }
        return "\(major + 1).0.0"
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"tag_name":"v\#(Self.version)"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
