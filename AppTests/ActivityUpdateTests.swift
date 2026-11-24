import AppKit
import Engine
import MenuCatalog
import XCTest

@testable import MacEase

@MainActor
final class ActivityUpdateTests: XCTestCase {
    func testSuccessfulWarningsStaySuccessfulAndBecomeGroupedNotes() async throws {
        let outcome = try await runBatch([
            { context in
                context.warn(.imageMetadataDropped([.exif]))
                context.warn(.imageMetadataDropped([.exif]))
                return .text("first", .report)
            },
            { context in
                context.warn(.imageMetadataDropped([.exif]))
                return .text("second", .report)
            },
        ])
        let result = ActivityResult(outcome)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.systemImage, "checkmark.circle.fill")
        XCTAssertFalse(result.isFailure)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(result.noteCount, 2)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.count, 2)
        XCTAssertTrue(result.hasCondensedWarnings)
        let summary = BatchSummary(outcome)
        XCTAssertEqual(
            summary.body,
            [String(localized: "\(2) done"), String(localized: "\(2) notes")].formatted(.list(type: .and)))
        XCTAssertFalse(summary.body.contains("EXIF"))
        XCTAssertTrue(summary.details.contains("EXIF"))
        XCTAssertTrue(summary.details.contains("input-1.txt"))
        XCTAssertTrue(summary.details.contains("input-2.txt"))
    }

    func testCleanSuccessNotificationHasOnlyTheSuccessCount() async throws {
        let outcome = try await runBatch([{ _ in .text("result", .report) }])
        XCTAssertEqual(BatchSummary(outcome).body, String(localized: "\(1) done"))
        XCTAssertEqual(ActivityResult(outcome).noteCount, 0)
    }

    func testDecodeFailureExposesTechnicalDetailOutsideTheHeadlineAndNotification() async throws {
        let detail = "Decoder fixture: missing sample at offset 42"
        let outcome = try await runBatch([{ _ in throw EngineError.decodeFailed(detail) }])
        let result = ActivityResult(outcome)
        let problem = try XCTUnwrap(result.problems.first)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.systemImage, "xmark.octagon.fill")
        XCTAssertTrue(problem.isFailure)
        XCTAssertEqual(problem.technicalDetail, detail)
        let file = "input-1.txt"
        XCTAssertEqual(
            problem.message,
            String(
                localized:
                    "Couldn’t read “\(file)”: decoding failed. Check that the file opens in another app, then retry."))
        XCTAssertFalse(problem.message.contains(detail))
        XCTAssertFalse(BatchSummary(outcome).body.contains(detail))
        XCTAssertTrue(BatchSummary(outcome).details.contains(detail))
        XCTAssertEqual(result.noteCount, 0)
    }

    func testResultReportKeepsMalformedInputCause() async throws {
        let cause = "subtitle line 7 has no timing"
        let outcome = try await runBatch([{ _ in throw EngineError.invalidInput(.malformed(cause)) }])
        let summary = BatchSummary(outcome)
        XCTAssertFalse(summary.body.contains(cause))
        XCTAssertEqual(summary.details.components(separatedBy: cause).count, 2)
    }

    func testMixedResultsKeepFailuresSeparateFromNotesAndSkipsNeutral() async throws {
        let outcome = try await runBatch([
            { context in
                context.warn(.metadataDropped)
                return .text("result", .report)
            },
            { _ in .skipped(.alreadyDone) },
            { _ in throw EngineError.encodeFailed("Encoder fixture") },
        ])
        let result = ActivityResult(outcome)
        XCTAssertEqual(result.status, .problems)
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.systemImage, "xmark.octagon.fill")
        XCTAssertEqual(result.noteCount, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.problems.map(\.isFailure), [false, true])
        XCTAssertEqual(result.problems.last?.technicalDetail, "Encoder fixture")
        XCTAssertFalse(BatchSummary(outcome).body.contains("Encoder fixture"))
        let skipped = ActivityResult(try await runBatch([{ _ in .skipped(.alreadyDone) }]))
        XCTAssertFalse(skipped.isFailure)
        XCTAssertEqual(skipped.systemImage, "info.circle")
    }

    func testTechnicalDetailPreservesDiagnosticsOnlyForSupportedErrors() {
        let detail = "Codec fixture: unsupported profile"
        for error in [
            EngineError.decodeFailed(detail), .encodeFailed(detail), .commitFailed(detail),
            .unexpected(detail), .unsupportedCodec(detail), .invalidInput(.malformed(detail)),
        ] {
            XCTAssertEqual(UserMessages.technicalDetail(error), detail)
            XCTAssertFalse(UserMessages.describeResult(error, file: "clip.mp4").contains(detail))
        }
        XCTAssertNil(UserMessages.technicalDetail(.cancelled))
        XCTAssertNil(UserMessages.technicalDetail(.permissionDenied(.downloads)))
        XCTAssertNil(UserMessages.technicalDetail(.decodeFailed("")))
        XCTAssertEqual(UserMessages.noteCount(1), String(localized: "1 note"))
    }

    func testFallbackErrorsAndPhaseMessages() {
        XCTAssertEqual(UserMessages.describe(ItemPhase.convertingInput), "Converting input")
        XCTAssertEqual(
            UserMessages.describe(
                .insufficientDiskSpace(requiredBytes: 500_000_000, availableBytes: 100_000_000),
                file: "movie.wmv"),
            "Couldn’t process “movie.wmv”: not enough disk space (needs about 500 MB, 100 MB available). Free up space and retry."
        )
        XCTAssertEqual(
            UserMessages.describe(.fallbackToolMissing, file: "movie.wmv"),
            "Couldn’t read “movie.wmv”: the media converter component is missing. Reinstall MacEase and retry.")
        XCTAssertEqual(
            UserMessages.describe(.fallbackConversionUnfaithful("audio channel layout: quad != 5.0"), file: "song.wv"),
            "Couldn’t process “song.wv”: the file couldn’t be converted faithfully. Nothing was changed.")
        XCTAssertEqual(
            UserMessages.technicalDetail(.fallbackConversionUnfaithful("audio channel layout: quad != 5.0")),
            "audio channel layout: quad != 5.0")
        XCTAssertEqual(
            UserMessages.describe(ItemWarning.keptAsNewFileForFormat),
            "Saved as a new file: MacEase cannot write the original format.")
        XCTAssertEqual(
            UserMessages.describe(ItemWarning.videoVariableFrameRateConverted),
            "Variable frame timing converted to a constant frame rate; original kept.")
        XCTAssertNil(UserMessages.technicalDetail(.insufficientDiskSpace(requiredBytes: 1, availableBytes: 0)))
        XCTAssertNil(UserMessages.technicalDetail(.fallbackToolMissing))
    }

    func testReverseCapacityMessageStatesRequiredAndAvailableSpace() {
        let reason = EngineError.insufficientDiskSpace(
            requiredBytes: 20_000_000_000, availableBytes: 1_000_000_000)
        XCTAssertEqual(
            UserMessages.describe(reason, file: "clip.mov"),
            "Couldn’t process “clip.mov”: not enough disk space (needs about 20 GB, 1 GB available). Free up space and retry."
        )
    }

    func testMalformedToolDiagnosticStaysOutOfNotifications() async throws {
        let detail = "java.lang.IllegalArgumentException\n\tat example.Decompiler.run(Decompiler.java:42)"
        let outcome = try await runBatch([{ _ in throw EngineError.invalidInput(.malformed(detail)) }])
        let problem = try XCTUnwrap(ActivityResult(outcome).problems.first)
        XCTAssertEqual(problem.technicalDetail, detail)
        XCTAssertFalse(problem.message.contains("java.lang"))
        XCTAssertFalse(problem.message.contains("\n"))
        XCTAssertFalse(BatchSummary(outcome).body.contains("java.lang"))
        XCTAssertFalse(BatchSummary(outcome).body.contains("Decompiler.java"))
        XCTAssertTrue(UserMessages.describe(.invalidInput(.malformed(detail)), file: "input.jar").contains(detail))
    }

    private func runBatch(_ actions: [@Sendable (ItemContext) throws -> ItemResult]) async throws -> BatchOutcome {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = try JobEngine(supportDirectory: directory, concurrency: 1)
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch {
                XCTFail("Fixture cleanup failed: \(error)")
            }
        }
        let work = try actions.enumerated().map { index, action in
            let input = directory.appendingPathComponent("input-\(index + 1).txt")
            try Data("fixture".utf8).write(to: input)
            return WorkItem(inputs: [input]) { context in try action(context) }
        }
        return await engine.run(Batch(operation: .imageConvert, items: work), settings: Settings()) { _ in }
    }

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
