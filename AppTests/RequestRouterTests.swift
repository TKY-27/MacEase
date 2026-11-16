import AppKit
import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class RequestRouterTests: XCTestCase {
    func testUpdateRouteAuthenticatesAndReusesUpdateWindowWithoutJobs() async throws {
        let suite = "MacEaseUpdateRouteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) } catch {
                XCTFail("Fixture cleanup failed: \(error)")
            }
        }
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let updates = UpdateChecker(settings: settings, defaults: defaults)
        let current = try XCTUnwrap(SemanticVersion(updates.currentVersion))
        let available = "\(current.components[0] + 1).0.0"
        updates.applyLatestRelease(available, checkedAt: Date())
        let engine = try JobEngine(supportDirectory: directory, concurrency: 1)
        let notifier = BatchNotifier(settings: settings)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: notifier)
        let token = String(repeating: "a", count: 64)
        let catalog = MenuFile(
            token: token, hostAvailable: true, entries: [], kinds: [:],
            updateTitle: "Update Available (v\(available))")
        var published: MenuFile? = catalog
        var openedWindows: [NSWindow] = []
        let presenter = SingleWindowPresenter {
            let window = UpdateWindow.make(updates: updates, close: {})
            openedWindows.append(window)
            return window
        }
        defer { presenter.close() }
        var appOpenCount = 0
        let router = RequestRouter(
            configuration: HostConfiguration(urlScheme: "macease-test", supportDirectory: directory),
            jobs: jobs, notifier: notifier, menuFile: { published },
            openApp: { appOpenCount += 1 }, openUpdate: { presenter.show() },
            openPreview: { XCTFail("Unexpected preview route") })
        for address in [
            "macease-test://update",
            "macease-test://update?t",
            "macease-test://update?t=",
            "macease-test://update?t=\(String(repeating: "b", count: 64))",
            "macease-test://update?t=\(token)&t=\(token)",
            "macease-test://update?t=\(token)&t",
            "other://update?t=\(token)",
            "macease-test://unknown?t=\(token)",
        ] {
            router.route(try XCTUnwrap(URL(string: address)))
            XCTAssertTrue(openedWindows.isEmpty)
        }
        let request = try XCTUnwrap(URL(string: "macease-test://update?t=\(token)"))
        published = nil
        router.route(request)
        XCTAssertTrue(openedWindows.isEmpty)
        published = MenuFile(token: token, hostAvailable: false, entries: [], kinds: [:], updateTitle: "Update")
        router.route(request)
        XCTAssertTrue(openedWindows.isEmpty)
        published = catalog
        router.route(request)
        let window = try XCTUnwrap(openedWindows.first)
        XCTAssertEqual(window.title, String(localized: "MacEase Update"))
        XCTAssertTrue(window.isVisible)
        router.route(request)
        XCTAssertEqual(openedWindows.count, 1)
        XCTAssertEqual(appOpenCount, 0)
        XCTAssertTrue(jobs.active.isEmpty)
        let records = await engine.history.records
        XCTAssertTrue(records.isEmpty)
    }
    func testPreviewRouteRequiresExactlyOneCurrentTokenAndAvailableHost() async throws {
        let suite = "MacEasePreviewRouteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) } catch {
                XCTFail("Fixture cleanup failed: \(error)")
            }
        }
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: directory, concurrency: 1)
        let notifier = BatchNotifier(settings: settings)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: notifier)
        let token = String(repeating: "a", count: 64)
        let catalog = MenuFile(
            token: token, hostAvailable: true, entries: [], kinds: [:], previewTitle: "Finder Preview")
        var published: MenuFile? = catalog
        var opened = 0
        let router = RequestRouter(
            configuration: HostConfiguration(urlScheme: "macease-test", supportDirectory: directory),
            jobs: jobs, notifier: notifier, menuFile: { published },
            openApp: { XCTFail("Unexpected app route") }, openUpdate: { XCTFail("Unexpected update route") },
            openPreview: { opened += 1 })
        for address in [
            "macease-test://preview", "macease-test://preview?t", "macease-test://preview?t=",
            "macease-test://preview?t=\(String(repeating: "b", count: 64))",
            "macease-test://preview?t=\(token)&t=\(token)",
            "macease-test://preview?t=\(token)&t", "other://preview?t=\(token)",
        ] {
            router.route(try XCTUnwrap(URL(string: address)))
            XCTAssertEqual(opened, 0, address)
        }
        let request = try XCTUnwrap(URL(string: "macease-test://preview?t=\(token)"))
        published = nil
        router.route(request)
        published = MenuFile(token: token, hostAvailable: false, entries: [], kinds: [:])
        router.route(request)
        XCTAssertEqual(opened, 0)
        published = catalog
        router.route(request)
        router.route(request)
        XCTAssertEqual(opened, 2)
        published = MenuFile(token: String(repeating: "c", count: 64), hostAvailable: true, entries: [], kinds: [:])
        router.route(request)
        XCTAssertEqual(opened, 2)
        XCTAssertTrue(jobs.active.isEmpty)
        let records = await engine.history.records
        XCTAssertTrue(records.isEmpty)
    }

}
