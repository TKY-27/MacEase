import Darwin
import Engine
import Foundation
import Synchronization

private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct Probe: Decodable {
    struct Stream: Decodable {
        let codecType: String
        let codecName: String?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
        }
    }

    let streams: [Stream]
}

@main
struct MediaIntegration {
    static func main() async {
        do {
            try await run()
            print("Media integration passed")
        } catch {
            fputs("Media integration failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (arguments.count == 3 || arguments.count == 4), let rootURL = URL(string: arguments[1]),
            ["http", "https"].contains(rootURL.scheme ?? "")
        else {
            throw CheckFailure(
                message: "Usage: MediaIntegration MEDIA_TOOLS_BIN FIXTURE_ROOT_URL FIXTURE_DIR [CAPACITY_VOLUME]")
        }

        let tools = try MediaDownloadTools(directory: URL(fileURLWithPath: arguments[0], isDirectory: true))
        let downloader = try MediaDownloader(tools: tools)
        let fixtureDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let recoveryFlag = fixtureDirectory.appending(path: "recovery.enabled")
        if FileManager.default.fileExists(atPath: recoveryFlag.path) {
            try FileManager.default.removeItem(at: recoveryFlag)
        }
        defer {
            if FileManager.default.fileExists(atPath: recoveryFlag.path) {
                do { try FileManager.default.removeItem(at: recoveryFlag) } catch {
                    fatalError("Could not remove recovery flag: \(error)")
                }
            }
        }
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MacEaseMediaIntegration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: workspace) } catch {
                fputs("Could not remove integration workspace: \(error)\n", stderr)
            }
        }
        let engine = try JobEngine(supportDirectory: workspace.appending(path: "support"), concurrency: 2)

        let source = try await analyze("source.mp4", at: rootURL, downloader: downloader)
        if arguments.count == 4 {
            try await capacity(
                source, on: URL(fileURLWithPath: arguments[3], isDirectory: true),
                fixtureDirectory: fixtureDirectory, downloader: downloader, engine: engine)
            return
        }
        let sourceFolder = try folder("source", in: workspace)
        let first = try await download(
            MediaDownloadSelection(source: source), to: sourceFolder, with: downloader, engine: engine)
        let firstURL = try output(first.outcome, extension: "mp4")
        try inspect(firstURL, using: tools, video: true, audio: true)
        try inspectStages(first.snapshots)
        let firstBytes = try Data(contentsOf: firstURL)

        let collision = try await download(
            MediaDownloadSelection(source: source), to: sourceFolder, with: downloader, engine: engine)
        let secondURL = try output(collision.outcome, extension: "mp4")
        try expect(secondURL != firstURL, "A second download must receive a different filename")
        try expect(try Data(contentsOf: firstURL) == firstBytes, "A collision must preserve the first file")
        try inspect(secondURL, using: tools, video: true, audio: true)
        let collisionUndo = try await engine.undo(collision.outcome.batchID)
        try expect(collisionUndo == [.restored], "Undo must remove collision output")
        try expect(!FileManager.default.fileExists(atPath: secondURL.path), "Undo left the second file")
        try expect(try Data(contentsOf: firstURL) == firstBytes, "Undo changed the first file")

        let dash = try await analyze("manifest.mpd", at: rootURL, downloader: downloader)
        let mkv = try await download(
            MediaDownloadSelection(source: dash, format: .mkv), to: try folder("dash", in: workspace),
            with: downloader, engine: engine)
        try inspect(try output(mkv.outcome, extension: "mkv"), using: tools, video: true, audio: true)

        let hls = try await analyze("playlist.m3u8", at: rootURL, downloader: downloader)
        let webm = try await download(
            MediaDownloadSelection(source: hls, format: .webm), to: try folder("hls", in: workspace),
            with: downloader, engine: engine)
        let webmProbe = try inspect(try output(webm.outcome, extension: "webm"), using: tools, video: true, audio: true)
        try expect(
            webmProbe.streams.filter { $0.codecType == "video" }.allSatisfy {
                ["vp8", "vp9", "av1"].contains($0.codecName ?? "")
            }, "WebM video codec is incompatible")

        let audio = try await download(
            MediaDownloadSelection(source: source, format: .mp3), to: try folder("audio", in: workspace),
            with: downloader, engine: engine)
        try inspect(try output(audio.outcome, extension: "mp3"), using: tools, video: false, audio: true)

        let page = try await analyze("index.html", at: rootURL, downloader: downloader)
        guard let subtitle = page.subtitles.first(where: { $0.language == "en" }) else {
            throw CheckFailure(message: "HTML subtitle track was not offered")
        }
        let pageRun = try await download(
            MediaDownloadSelection(source: page, subtitle: subtitle, subtitleFormat: .vtt),
            to: try folder("page", in: workspace), with: downloader, engine: engine)
        let pageOutputs = try outputs(pageRun.outcome)
        guard let sidecar = pageOutputs.first(where: { $0.pathExtension == "vtt" }) else {
            throw CheckFailure(message: "Requested VTT sidecar is missing")
        }
        try expect(try String(contentsOf: sidecar, encoding: .utf8).contains("WEBVTT"), "VTT content is invalid")

        try await cancellation(
            try await analyze("slow.mp4", at: rootURL, downloader: downloader),
            to: try folder("slow", in: workspace), downloader: downloader, engine: engine)
        try await disconnection(
            try await analyze("disconnected.mp4", at: rootURL, downloader: downloader),
            to: try folder("disconnected", in: workspace), downloader: downloader, engine: engine)
        try await permission(
            source, to: try folder("unwritable", in: workspace), downloader: downloader, engine: engine)
        try await failureOnlyRetry(
            source: source, disconnected: try await analyze("disconnected.mp4", at: rootURL, downloader: downloader),
            to: try folder("retry", in: workspace), recoveryFlag: recoveryFlag,
            downloader: downloader, engine: engine, tools: tools)

        let firstUndo = try await engine.undo(first.outcome.batchID)
        try expect(firstUndo == [.restored], "Undo must remove first output")
        try expect(!FileManager.default.fileExists(atPath: firstURL.path), "Undo left the first file")
    }

    private static func analyze(_ path: String, at rootURL: URL, downloader: MediaDownloader) async throws
        -> MediaSource
    {
        let url = rootURL.appending(path: path)
        let analysis = try await downloader.analyze(urls: [url])
        guard analysis.failures.isEmpty, analysis.sources.count == 1, let source = analysis.sources.first else {
            throw CheckFailure(message: "Analysis failed for \(path): \(analysis.failures.map(\.message))")
        }
        return source
    }

    private static func folder(_ name: String, in workspace: URL) throws -> URL {
        let destination = workspace.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    private static func download(
        _ selection: MediaDownloadSelection, to destination: URL, with downloader: MediaDownloader,
        engine: JobEngine
    ) async throws -> (outcome: BatchOutcome, snapshots: [BatchProgress]) {
        let snapshots = Mutex<[BatchProgress]>([])
        let request = MediaDownloadRequest(destination: destination, selections: [selection])
        let outcome = await engine.run(try downloader.makeBatch(request), settings: Settings()) {
            progress in snapshots.withLock { $0.append(progress) }
        }
        return (outcome, snapshots.withLock { $0 })
    }

    private static func outputs(_ outcome: BatchOutcome) throws -> [URL] {
        guard outcome.outcomes.count == 1, case .succeeded(let files, _) = outcome.outcomes[0],
            !files.isEmpty, outcome.record != nil
        else { throw CheckFailure(message: "Download failed: \(outcome.outcomes)") }
        for file in files {
            try expect(FileManager.default.fileExists(atPath: file.path), "Committed output is missing: \(file.path)")
        }
        return files
    }

    private static func output(_ outcome: BatchOutcome, extension name: String) throws -> URL {
        guard let file = try outputs(outcome).first(where: { $0.pathExtension == name }) else {
            throw CheckFailure(message: "Expected .\(name) output is missing")
        }
        return file
    }

    @discardableResult
    private static func inspect(_ file: URL, using tools: MediaDownloadTools, video: Bool, audio: Bool) throws -> Probe
    {
        let probeProcess = Process()
        probeProcess.executableURL = tools.ffprobe
        probeProcess.arguments = [
            "-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "json", file.path,
        ]
        let pipe = Pipe()
        probeProcess.standardOutput = pipe
        try probeProcess.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        probeProcess.waitUntilExit()
        try expect(probeProcess.terminationStatus == 0, "ffprobe rejected \(file.lastPathComponent)")
        let probe = try JSONDecoder().decode(Probe.self, from: result)
        try expect(probe.streams.contains { $0.codecType == "video" } == video, "Unexpected video stream")
        try expect(probe.streams.contains { $0.codecType == "audio" } == audio, "Unexpected audio stream")
        return probe
    }

    private static func inspectStages(_ snapshots: [BatchProgress]) throws {
        try expect(!snapshots.isEmpty, "No progress snapshots were delivered")
        try expect(
            zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.0.sequence < $0.1.sequence },
            "Progress sequence must advance")
        try expect(
            snapshots.contains { $0.itemPhases.first == .downloading && ($0.currentFileFraction ?? 0) > 0 },
            "Measured download bytes were not reported")
        try expect(
            snapshots.contains { $0.itemPhases.first == .verifying && $0.currentFileFraction == nil },
            "Verification must reset stage measurement")
        try expect(snapshots.contains { $0.itemPhases.first == .saving }, "Saving stage was not reported")
        try expect(
            snapshots.contains { $0.currentFileFraction == 1 && $0.completedItems == 0 },
            "Stage completion must not mark the batch complete")
        try expect(snapshots.last?.completedItems == 1, "Batch completion was not reported")
    }

    private static func cancellation(
        _ source: MediaSource, to destination: URL, downloader: MediaDownloader, engine: JobEngine
    ) async throws {
        let snapshots = Mutex<[BatchProgress]>([])
        let request = MediaDownloadRequest(
            destination: destination, selections: [MediaDownloadSelection(source: source)])
        let batch = try downloader.makeBatch(request)
        let task = Task {
            await engine.run(batch, settings: Settings()) { progress in
                snapshots.withLock { $0.append(progress) }
            }
        }
        var reachedTransfer = false
        for _ in 0..<150 {
            if snapshots.withLock({ $0.contains { $0.itemPhases.first == .downloading } }) {
                reachedTransfer = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard reachedTransfer else {
            task.cancel()
            _ = await task.value
            throw CheckFailure(message: "Slow route did not enter download stage")
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let outcome = await task.value
        try expect(outcome.outcomes == [.failed(.cancelled)], "Cancelled transfer did not report cancellation")
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
            "Cancellation published output")
    }

    private static func disconnection(
        _ source: MediaSource, to destination: URL, downloader: MediaDownloader, engine: JobEngine
    ) async throws {
        let result = try await download(
            MediaDownloadSelection(source: source), to: destination, with: downloader, engine: engine)
        guard result.snapshots.contains(where: { $0.itemPhases.first == .downloading }),
            result.outcome.outcomes.count == 1,
            case .failed(let error) = result.outcome.outcomes[0], error != .cancelled
        else { throw CheckFailure(message: "Disconnected transfer did not fail during download") }
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Failure published output")
    }

    private static func permission(
        _ source: MediaSource, to destination: URL, downloader: MediaDownloader, engine: JobEngine
    ) async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            } catch { fatalError("Could not restore destination permissions: \(error)") }
        }
        let result = try await download(
            MediaDownloadSelection(source: source), to: destination, with: downloader, engine: engine)
        guard result.outcome.outcomes.count == 1,
            case .failed(.permissionDenied) = result.outcome.outcomes[0]
        else {
            throw CheckFailure(message: "Unwritable destination was accepted")
        }
        try expect(result.outcome.record == nil, "Unwritable destination entered history")
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
            "Permission failure published output")
    }

    private static func failureOnlyRetry(
        source: MediaSource, disconnected: MediaSource, to destination: URL, recoveryFlag: URL,
        downloader: MediaDownloader, engine: JobEngine, tools: MediaDownloadTools
    ) async throws {
        let request = MediaDownloadRequest(
            destination: destination,
            selections: [
                MediaDownloadSelection(source: source), MediaDownloadSelection(source: disconnected),
            ])
        let first = await engine.run(try downloader.makeBatch(request), settings: Settings()) { _ in }
        guard first.outcomes.count == 2, case .succeeded(let successfulFiles, _) = first.outcomes[0],
            case .failed(let failure) = first.outcomes[1], failure != .cancelled,
            successfulFiles.count == 1
        else { throw CheckFailure(message: "Mixed batch did not produce one success and one failure") }
        let successfulFile = successfulFiles[0]
        try inspect(successfulFile, using: tools, video: true, audio: true)
        let originalBytes = try Data(contentsOf: successfulFile)
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1,
            "Failed item published output")
        guard let retry = request.retryingFailed(first), retry.selections.count == 1,
            retry.selections[0].source.id == disconnected.id
        else { throw CheckFailure(message: "Retry selected the wrong item") }

        try Data().write(to: recoveryFlag)
        let second = await engine.run(try downloader.makeBatch(retry), settings: Settings()) { _ in }
        let recoveredFile = try output(second, extension: "mp4")
        try inspect(recoveredFile, using: tools, video: true, audio: true)
        try expect(recoveredFile != successfulFile, "Retry replaced the successful file")
        try expect(try Data(contentsOf: successfulFile) == originalBytes, "Retry changed the successful output")
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2,
            "Retry changed output count")
        try expect(retry.retryingFailed(second) == nil, "Successful retry remains eligible for retry")
        try FileManager.default.removeItem(at: recoveryFlag)
    }

    private static func capacity(
        _ source: MediaSource, on volume: URL, fixtureDirectory: URL,
        downloader: MediaDownloader, engine: JobEngine
    ) async throws {
        let marker = volume.appending(path: ".macease-capacity-fixture")
        let destination = volume.appending(path: "output", directoryHint: .isDirectory)
        try expect(FileManager.default.fileExists(atPath: marker.path), "Capacity volume marker is missing")
        var isDirectory: ObjCBool = false
        try expect(
            FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "Capacity output folder is missing")
        var statistics = statfs()
        try expect(statfs(volume.path, &statistics) == 0, "Could not read capacity volume")
        let sourceFile = fixtureDirectory.appending(path: "source.mp4")
        let sourceSize = try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as? Int64
        guard let sourceSize else { throw CheckFailure(message: "Source fixture size is unavailable") }
        try expect(
            Int64(statistics.f_bavail) * Int64(statistics.f_bsize) < sourceSize,
            "Capacity volume has room for the source file")
        let result = try await download(
            MediaDownloadSelection(source: source), to: destination, with: downloader, engine: engine)
        guard result.outcome.outcomes.count == 1,
            case .failed(.decodeFailed(let reason)) = result.outcome.outcomes[0],
            reason.localizedCaseInsensitiveContains("disk space")
        else {
            throw CheckFailure(message: "Full test volume did not report disk space failure")
        }
        try expect(result.outcome.record == nil, "Capacity failure entered history")
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
            "Capacity failure published output")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
    }
}
