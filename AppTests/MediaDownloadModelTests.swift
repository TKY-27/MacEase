import XCTest

@testable import Engine
@testable import MacEase

@MainActor
final class MediaDownloadModelTests: XCTestCase {
    func testReturnDownloadsListedResultsButAnalyzesEditedURLs() async throws {
        let root = try fixtureFolder()
        let model = MediaDownloadModel(destination: root, tools: try fakeTools(in: root))
        addTeardownBlock { await model.close() }
        var requests: [MediaDownloadRequest] = []
        var results: [ItemOutcome] = [.failed(.decodeFailed("fixture")), .succeeded(outputs: [root], warnings: [])]
        let start: MediaDownloadModel.StartDownloads = { request in
            requests.append(request)
            let result = results.removeFirst()
            let batchID = UUID()
            let task = Task<BatchOutcome?, Never> {
                BatchOutcome(
                    batchID: batchID, operation: .folderDownloadMedia, inputs: [[]], outcomes: [result],
                    clipboardText: nil, reportText: nil, record: nil, historyFailed: false, details: [ItemDetails()])
            }
            return (batchID, task)
        }

        model.urls = "https://example.com/video"
        model.submitURLs(start)
        try await eventually { !model.sources.isEmpty }
        XCTAssertTrue(requests.isEmpty)

        model.urls += "\n"
        XCTAssertTrue(model.sources.isEmpty)
        model.submitURLs(start)
        XCTAssertTrue(model.isAnalyzing)
        try await eventually { !model.sources.isEmpty }
        XCTAssertTrue(requests.isEmpty)

        model.submitURLs(start)
        XCTAssertEqual(requests.map(\.selections.count), [1])
        XCTAssertEqual(requests.first?.destination, root)
        XCTAssertTrue(model.urls.isEmpty)
        let download = try XCTUnwrap(model.downloads.first)
        XCTAssertEqual(model.status(of: download, progress: nil), .queued)
        var running = JobCenter.ActiveBatch(
            id: UUID(), batchID: download.batchID, operation: .folderDownloadMedia, fileNames: ["Fixture"])
        running.itemPhases = [.downloading]
        running.stageFractions = [0.4]
        XCTAssertEqual(model.status(of: download, progress: running), .running(.downloading, fraction: 0.4))

        try await eventually { model.downloads.first?.outcome != nil }
        XCTAssertEqual(
            model.status(of: try XCTUnwrap(model.downloads.first), progress: nil),
            .failed(UserMessages.describeResult(.decodeFailed("fixture"), file: "Fixture")))
        model.retry(download.id, start)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.selections, requests.first?.selections)
        XCTAssertEqual(model.downloads.count, 1)
        try await eventually { model.downloads.first?.outcome != nil }
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.downloads.first), progress: nil), .done([root]))
    }

    func testItemOutcomesAndRetryArriveBeforeTheBatchFinishes() async throws {
        let root = try fixtureFolder()
        let suite = "MacEaseDownloadProgress-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 4)
        let jobs = JobCenter(engine: engine, settings: settings, notifier: BatchNotifier(settings: settings))
        let model = MediaDownloadModel(destination: root, tools: try fakeTools(in: root, count: 4))
        addTeardownBlock { await model.close() }
        let held = AsyncStream<Void>.makeStream()
        defer { held.continuation.finish() }
        var requests: [MediaDownloadRequest] = []
        var tasks: [Task<BatchOutcome?, Never>] = []
        let start: MediaDownloadModel.StartDownloads = { request in
            requests.append(request)
            let retry = requests.count > 1
            let work = request.selections.indices.map { index in
                WorkItem(inputs: []) { context in
                    context.phase(.downloading)
                    if !retry {
                        switch index {
                        case 0: throw EngineError.protectionDiskFull
                        case 2: throw CancellationError()
                        case 3:
                            for await _ in held.stream { break }
                        default: break
                        }
                    }
                    let name = retry ? "retry.txt" : "download-\(index).txt"
                    let staged = try context.stagingURL(for: root, name: name)
                    try Data("downloaded".utf8).write(to: staged)
                    return .created(in: root, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
                }
            }
            let batch = Batch(operation: .folderDownloadMedia, items: work)
            let task = jobs.run(batch: batch)
            tasks.append(task)
            self.addTeardownBlock {
                task.cancel()
                _ = await task.value
            }
            return (batch.id, task)
        }
        model.urls = "https://example.com/playlist"
        model.analyze()
        try await eventually { model.sources.count == 4 }
        model.selectedIDs = Set(model.sources.map(\.id))
        model.download(start)
        let rows = model.downloads
        XCTAssertEqual(rows.count, 4)
        let batchID = try XCTUnwrap(rows.first?.batchID)
        try await eventually {
            jobs.active.first { $0.batchID == batchID }?.completedItems == 3
        }
        let progress = try XCTUnwrap(jobs.active.first { $0.batchID == batchID })
        XCTAssertTrue(model.downloads.allSatisfy { $0.outcome == nil })
        XCTAssertEqual(
            model.status(of: rows[0], progress: progress),
            .failed(UserMessages.describeResult(.protectionDiskFull, file: rows[0].selection.source.title)))
        let output = root.appending(path: "download-1.txt")
        XCTAssertEqual(model.status(of: rows[1], progress: progress), .done([output]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(model.status(of: rows[2], progress: progress), .cancelled)
        XCTAssertEqual(model.status(of: rows[3], progress: progress), .running(.downloading, fraction: nil))
        model.retry(rows[1].id, progress: progress, start)
        model.retry(rows[2].id, progress: progress, start)
        XCTAssertEqual(requests.count, 1)
        model.retry(rows[0].id, progress: progress, start)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].selections, [rows[0].selection])
        XCTAssertNotEqual(model.downloads[0].batchID, batchID)
        XCTAssertEqual(model.status(of: model.downloads[0], progress: progress), .queued)
        try await eventually { model.downloads[0].outcome != nil }
        let retried = root.appending(path: "retry.txt")
        XCTAssertEqual(model.status(of: model.downloads[0], progress: nil), .done([retried]))
        held.continuation.finish()
        for task in tasks { _ = await task.value }
        try await eventually { model.downloads.allSatisfy { $0.outcome != nil } }
        XCTAssertEqual(model.status(of: model.downloads[0], progress: nil), .done([retried]))
        XCTAssertEqual(model.status(of: model.downloads[1], progress: nil), .done([output]))
        XCTAssertEqual(model.status(of: model.downloads[2], progress: nil), .cancelled)
    }

    private func fixtureFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseDownloadModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func fakeTools(in root: URL, count: Int = 1) throws -> MediaDownloadTools {
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        var metadata =
            #"{"id":"fixture","title":"Fixture","webpage_url":"https://example.com/video","duration":10,"formats":[{"height":720,"ext":"mp4"}]}"#
        if count > 1 {
            let entries = (0..<count).map {
                metadata.replacingOccurrences(of: "fixture", with: "fixture-\($0)")
                    .replacingOccurrences(of: "https://example.com/video", with: "https://example.com/video-\($0)")
            }
            metadata = #"{"_type":"playlist","entries":["# + entries.joined(separator: ",") + "]}"
        }
        let scripts = [
            "python3": "#!/bin/sh\nprintf '%s' '\(metadata)'\n",
            "node": "#!/bin/sh\nexit 0\n", "ffmpeg": "#!/bin/sh\nexit 0\n", "ffprobe": "#!/bin/sh\nexit 0\n",
        ]
        for (name, script) in scripts {
            let url = bin.appending(path: name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return try MediaDownloadTools(directory: bin)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the download window")
    }
}
