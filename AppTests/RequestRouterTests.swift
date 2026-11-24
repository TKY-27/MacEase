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
            commands: [
                MenuCommandItem(
                    group: MenuGroupID(.update), title: "Update Available (v\(available))", placement: .primary)
            ])
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
            openPreview: { XCTFail("Unexpected preview route") },
            finderCommand: { _ in XCTFail("Unexpected Finder command") })
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
        published = MenuFile(
            token: token, hostAvailable: false, entries: [], kinds: [:],
            commands: [MenuCommandItem(group: MenuGroupID(.update), title: "Update", placement: .primary)])
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
            token: token, hostAvailable: true, entries: [], kinds: [:],
            commands: [MenuCommandItem(group: MenuGroupID(.preview), title: "Finder Preview", placement: .primary)])
        var published: MenuFile? = catalog
        var opened = 0
        let router = RequestRouter(
            configuration: HostConfiguration(urlScheme: "macease-test", supportDirectory: directory),
            jobs: jobs, notifier: notifier, menuFile: { published },
            openApp: { XCTFail("Unexpected app route") }, openUpdate: { XCTFail("Unexpected update route") },
            openPreview: { opened += 1 }, finderCommand: { _ in XCTFail("Unexpected Finder command") })
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

extension RequestRouterTests {
    func testFinderCommandsAuthenticateCurrentCatalogAndExactLeafBeforeDispatch() async throws {
        let suite = "MacEaseFinderRouting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
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
        let rows = [HostCommand.newFile, .cut, .moveHere, .copyPath, .openTerminal].map { command in
            MenuCommandItem(
                group: MenuGroupID(command), title: command.rawValue, placement: .primary,
                leaves: command == .newFile
                    ? [MenuCommandLeaf(preset: "txt", title: "Text")]
                    : command == .copyPath ? [MenuCommandLeaf(preset: "posix", title: "Copy Path")] : nil)
        }
        let catalog = MenuFile(token: token, hostAvailable: true, entries: [], kinds: [:], commands: rows)
        var published: MenuFile? = catalog
        var dispatched: [HostCommandRequest] = []
        let router = RequestRouter(
            configuration: HostConfiguration(urlScheme: "macease-test", supportDirectory: directory),
            jobs: jobs, notifier: notifier, menuFile: { published }, openApp: { XCTFail("Unexpected app") },
            openUpdate: { XCTFail("Unexpected update") }, openPreview: { XCTFail("Unexpected preview") },
            finderCommand: { dispatched.append($0) })
        for action in catalog.commandActions {
            let request = HostCommandRequest(
                action: action, catalogVersion: catalog.catalogVersion, token: token,
                paths: ["/tmp/folder & 日本語"])
            let valid = try XCTUnwrap(request.url(scheme: "macease-test"))
            let initialCount = dispatched.count
            for suffix in ["&t=\(token)", "&t", "&path", "&preset=invalid", "&v=stale"] {
                router.route(try XCTUnwrap(URL(string: valid.absoluteString + suffix)))
                XCTAssertEqual(dispatched.count, initialCount)
            }
            for replacement in ["", "wrong"] {
                let rejected = HostCommandRequest(
                    action: action, catalogVersion: catalog.catalogVersion,
                    token: replacement, paths: request.paths)
                router.route(try XCTUnwrap(rejected.url(scheme: "macease-test")))
                XCTAssertEqual(dispatched.count, initialCount)
            }
            let stale = HostCommandRequest(action: action, catalogVersion: "old", token: token, paths: request.paths)
            router.route(try XCTUnwrap(stale.url(scheme: "macease-test")))
            published = nil
            router.route(valid)
            published = MenuFile(token: token, hostAvailable: false, entries: [], kinds: [:], commands: rows)
            router.route(valid)
            XCTAssertEqual(dispatched.count, initialCount)
            published = catalog
            router.route(valid)
            XCTAssertEqual(dispatched.last, request)
            XCTAssertEqual(dispatched.count, initialCount + 1)
            published = MenuFile(token: token, hostAvailable: true, entries: [], kinds: [:])
            router.route(valid)
            XCTAssertEqual(dispatched.count, initialCount + 1)
            published = catalog
        }
        XCTAssertEqual(dispatched.count, 5)
        XCTAssertTrue(jobs.active.isEmpty)
        let records = await engine.history.records
        XCTAssertTrue(records.isEmpty)
    }

    func testHostCaseMatchingAndDotPathRejectionHoldAcrossAllRoutes() async throws {
        let suite = "MacEaseRouteCaseAndPaths-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
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
        let entry = MenuEntry(op: .anyChecksum, preset: "sha256", path: ["Checksum", "SHA-256"])
        let catalog = MenuFile(
            token: token, hostAvailable: true, entries: [entry], kinds: [.any: "All Files"],
            commands: [
                MenuCommandItem(group: MenuGroupID(.update), title: "Update", placement: .primary),
                MenuCommandItem(group: MenuGroupID(.preview), title: "Preview", placement: .primary),
                MenuCommandItem(
                    group: MenuGroupID(.newFile), title: "New File", placement: .primary,
                    leaves: [MenuCommandLeaf(preset: "txt", title: "Text")]),
            ])
        var openCount = 0
        var updateCount = 0
        var previewCount = 0
        var dispatchedCommands: [HostCommandRequest] = []
        let router = RequestRouter(
            configuration: HostConfiguration(urlScheme: "macease-test", supportDirectory: directory),
            jobs: jobs, notifier: notifier, menuFile: { catalog },
            openApp: { openCount += 1 }, openUpdate: { updateCount += 1 }, openPreview: { previewCount += 1 },
            finderCommand: { dispatchedCommands.append($0) })

        router.route(try XCTUnwrap(URL(string: "macease-test://OPEN")))
        router.route(try XCTUnwrap(URL(string: "macease-test://UPDATE?t=\(token)")))
        router.route(try XCTUnwrap(URL(string: "macease-test://PREVIEW?t=\(token)")))
        router.route(
            try XCTUnwrap(
                URL(string: "macease-test://PREVIEW?t=\(token)&v=\(catalog.catalogVersion)&path=/tmp")))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(previewCount, 2)
        XCTAssertTrue(dispatchedCommands.isEmpty)

        for rejected in [
            "macease-test://run?v=\(catalog.catalogVersion)&e=0&t=\(token)&path=/tmp/symdir/.",
            "macease-test://run?v=\(catalog.catalogVersion)&e=0&t=\(token)&path=/tmp/symdir/..",
            "macease-test://newfile?t=\(token)&v=\(catalog.catalogVersion)&preset=txt&path=/tmp/symdir/.",
            "macease-test://newfile?t=\(token)&v=\(catalog.catalogVersion)&preset=txt&path=/tmp/symdir/..",
        ] {
            router.route(try XCTUnwrap(URL(string: rejected)))
        }
        XCTAssertTrue(dispatchedCommands.isEmpty)
        XCTAssertTrue(jobs.active.isEmpty)
        XCTAssertTrue(jobs.completed.isEmpty)
    }
}
