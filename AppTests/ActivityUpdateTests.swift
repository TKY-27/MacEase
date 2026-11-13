import AppKit
import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class ActivityUpdateTests: XCTestCase {
    func testClosingActivityClearsFailedResultButKeepsHistoryUndo() async throws {
        let suite = "MacEaseActivityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: directory, concurrency: 1)
        let notifier = BatchNotifier(settings: settings)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: notifier)
        let activity = ActivityWindow(jobs: jobs, settings: settings, notifier: notifier)
        let output = directory.appendingPathComponent("result.txt")
        let successful = await engine.saveReport("report", to: output, operation: .folderAnalyze)
        let successID = UUID()
        let success = JobCenter.ActiveBatch(
            id: successID, batchID: successful.batchID, operation: .folderAnalyze, fileNames: ["result.txt"])
        activity.started(success)
        settings.activityClosesAfterSuccess = false
        XCTAssertFalse(activity.finished(success, outcome: successful))

        let invalid = try XCTUnwrap(URL(string: "https://example.invalid/result.txt"))
        let failed = await engine.saveReport("report", to: invalid, operation: .folderAnalyze)
        let failureID = UUID()
        let failure = JobCenter.ActiveBatch(
            id: failureID, batchID: failed.batchID, operation: .folderAnalyze, fileNames: ["result.txt"])
        activity.started(failure)
        activity.show()
        XCTAssertTrue(activity.finished(failure, outcome: failed))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == String(localized: "MacEase Activity") })
        XCTAssertTrue(panel.isVisible)
        activity.dismissBatch(successful.batchID)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(activity.windowShouldClose(panel) == false)
        XCTAssertFalse(panel.isVisible)
        activity.show()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let records = await engine.history.records
        let record = try XCTUnwrap(records.first { $0.id == successful.batchID })
        XCTAssertTrue(record.canUndo)
        XCTAssertTrue(jobs.canUndo(successful.batchID))
    }

    func testAvailableUpdateNotifiesDailyAcrossLaunchAndNewVersionImmediately() throws {
        let suite = "MacEaseUpdateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let running = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let major = try XCTUnwrap(SemanticVersion(running)).components[0]
        let first = "\(major + 1).0.0"
        let second = "\(major + 2).0.0"
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var notices: [String] = []
        let checker = UpdateChecker(settings: settings, defaults: defaults)
        checker.onAvailableRelease = { release in
            notices.append(release.version)
            return true
        }
        checker.applyLatestRelease(first, checkedAt: day)
        checker.applyLatestRelease(first, checkedAt: day.addingTimeInterval(23 * 60 * 60))
        XCTAssertEqual(notices, [first])
        XCTAssertEqual(checker.availableRelease?.version, first)

        let relaunched = UpdateChecker(settings: settings, defaults: defaults)
        relaunched.onAvailableRelease = { release in
            notices.append(release.version)
            return true
        }
        relaunched.applyLatestRelease(first, checkedAt: day.addingTimeInterval(24 * 60 * 60))
        relaunched.applyLatestRelease(second, checkedAt: day.addingTimeInterval(24 * 60 * 60 + 1))
        XCTAssertEqual(notices, [first, first, second])
        relaunched.applyLatestRelease(running, checkedAt: day.addingTimeInterval(2 * 24 * 60 * 60))
        XCTAssertNil(relaunched.availableRelease)
    }

    func testDisabledUpdateNoticeDoesNotConsumeDailyReminder() throws {
        let suite = "MacEaseUpdateDisabledTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let running = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let major = try XCTUnwrap(SemanticVersion(running)).components[0]
        let checker = UpdateChecker(settings: settings, defaults: defaults)
        var permitted = false
        var notices = 0
        checker.onAvailableRelease = { _ in
            notices += 1
            return permitted
        }
        let version = "\(major + 1).0.0"
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        checker.applyLatestRelease(version, checkedAt: day)
        permitted = true
        checker.applyLatestRelease(version, checkedAt: day.addingTimeInterval(60))
        XCTAssertEqual(notices, 2)
        checker.applyLatestRelease(version, checkedAt: day.addingTimeInterval(120))
        XCTAssertEqual(notices, 2)
    }
}
