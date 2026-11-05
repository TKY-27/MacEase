import Darwin
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite struct MediaDownloadTests {
    @Test(arguments: [
        "file:///etc/passwd", "https://user:password@example.com/video", "https:///", "--help",
        "https://example.com/\nvideo",
    ])
    func rejectsUnsafeURLs(_ text: String) {
        #expect(throws: EngineError.self) { try MediaDownloader.validateURL(text) }
    }

    @Test func analyzesSubprocessMetadataAndSanitizesFailure() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let downloader = try MediaDownloader(tools: fixture.tools)
        let analysis = try await downloader.analyze(urls: [
            try #require(URL(string: "https://example.com/video")),
            try #require(URL(string: "https://example.com/fail?secret=private")),
        ])
        let source = try #require(analysis.sources.first)
        #expect(source.title == "Fixture")
        #expect(source.resolutions == [1080, 720])
        #expect(source.availableFormats == ["mp4", "webm"])
        #expect(source.subtitles.contains(MediaSubtitle(language: "en", automatic: false)))
        #expect(source.subtitles.contains(MediaSubtitle(language: "ja", automatic: true)))
        #expect(analysis.failures.count == 1)
        #expect(analysis.failures[0].message == "The website refused the request or applied a rate limit")
        #expect(!analysis.failures[0].message.contains("private"))
        let arguments = try String(contentsOf: fixture.root.appending(path: "arguments"), encoding: .utf8)
        #expect(arguments.contains("--ignore-config\n--no-plugin-dirs\n--no-update"))
        #expect(arguments.contains("--no-remote-components"))
        #expect(arguments.contains("--\nhttps://example.com/fail?secret=private"))
    }

    @Test func commitsWithoutOverwritingAndRecordsRetryFailures() async throws {
        let fixture = try DownloadFixture(root: TestVolume.makeFolder())
        defer { fixture.remove() }
        let downloader = try MediaDownloader(tools: fixture.tools)
        let analysis = try await downloader.analyze(urls: [try #require(URL(string: "https://example.com/video"))])
        let source = try #require(analysis.sources.first)
        let selection = MediaDownloadSelection(source: source)
        let request = MediaDownloadRequest(destination: fixture.destination, selections: [selection])
        let original = fixture.destination.appending(path: "Fixture.mp4")
        try Data("original".utf8).write(to: original)
        let engine = try JobEngine(supportDirectory: fixture.root.appending(path: "support"), concurrency: 1)
        let snapshots = Mutex<[BatchProgress]>([])
        let outcome = await engine.run(try downloader.makeBatch(request), settings: Settings()) {
            snapshot in snapshots.withLock { $0.append(snapshot) }
        }
        guard case .succeeded(let outputs, _) = outcome.outcomes.first else {
            Issue.record("Download failed: \(outcome.outcomes)")
            return
        }
        #expect(outputs.map(\.lastPathComponent) == ["Fixture (2).mp4"])
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOf: outputs[0], encoding: .utf8) == "fixture-media")
        #expect(outcome.record?.outputPaths == outputs.map(\.path))
        #expect(request.retryingFailed(outcome) == nil)
        #expect(snapshots.withLock { $0.contains { $0.currentFileFraction == 0.5 } })
        let journal = fixture.root.appending(path: "support/history.json")
        #expect(try Data(contentsOf: journal).range(of: Data("example.com".utf8)) == nil)
        let undone = try await engine.undo(outcome.batchID)
        #expect(undone == [.restored])
        #expect(!FileManager.default.fileExists(atPath: outputs[0].path))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }

    @Test func retriesOnlyFailuresAndResolvesMetadataAgain() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let downloader = try MediaDownloader(tools: fixture.tools)
        let page = try #require(URL(string: "https://example.com/video"))
        let analysis = try await downloader.analyze(urls: [page])
        let source = try #require(analysis.sources.first)
        let selection = MediaDownloadSelection(source: source)
        let request = MediaDownloadRequest(
            destination: fixture.destination, selections: [selection, selection, selection])
        let engine = try JobEngine(supportDirectory: fixture.root.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(
            Batch(
                operation: .folderDownloadMedia,
                items: [
                    WorkItem(inputs: []) { _ in .text("done", .clipboard) },
                    WorkItem(inputs: []) { _ in throw EngineError.decodeFailed("network") },
                    WorkItem(inputs: []) { _ in throw EngineError.cancelled },
                ]), settings: Settings()
        ) { _ in }
        let retry = try #require(request.retryingFailed(outcome))
        #expect(retry.selections.count == 1)
        try Data("changed".utf8).write(to: fixture.root.appending(path: "changed"))
        let retried = await engine.run(try downloader.makeBatch(retry), settings: Settings()) { _ in }
        #expect(retried.outcomes == [.failed(.decodeFailed("The selected media is no longer available"))])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test func rejectsSymlinkOutputBeforeCommit() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let downloader = try MediaDownloader(tools: fixture.tools)
        let page = try #require(URL(string: "https://example.com/video"))
        let analysis = try await downloader.analyze(urls: [page])
        let source = try #require(analysis.sources.first)
        try Data().write(to: fixture.root.appending(path: "symlink"))
        let request = MediaDownloadRequest(
            destination: fixture.destination, selections: [MediaDownloadSelection(source: source)])
        let engine = try JobEngine(supportDirectory: fixture.root.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(try downloader.makeBatch(request), settings: Settings()) { _ in }
        #expect(outcome.outcomes == [.failed(.decodeFailed("Download output is unsafe or incomplete"))])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test(arguments: [
        ("vtt", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start position:0%\n<c>Caption</c>\n", true),
        ("srt", "1\n00:00:01,000 --> 00:00:02,000\nCaption\n", true),
        ("vtt", "WEBVTT\n\n00:00:02.000 --> 00:00:01.000\nBackwards\n", false),
        ("srt", "1\n00:00:01,000 --> 00:00:02,000\n", false),
    ])
    func validatesSubtitleTiming(format: String, text: String, valid: Bool) throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let subtitle = fixture.root.appending(path: "captions." + format)
        try Data(text.utf8).write(to: subtitle)
        if valid {
            try DownloadSubtitles.validate(subtitle)
        } else {
            #expect(throws: EngineError.self) { try DownloadSubtitles.validate(subtitle) }
        }
    }

    @Test func phaseSnapshotsResetMeasurementsAndPreserveOrdering() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let snapshots = Mutex<[BatchProgress]>([])
        let batch = Batch(
            operation: .folderDownloadMedia,
            items: [
                WorkItem(inputs: []) { context in
                    context.phase(.encoding)
                    context.progress(0.8)
                    context.phase(.searching)
                    context.progress(0.9)
                    context.phase(.encoding)
                    context.progress(0.2)
                    return .text("done", .clipboard)
                }
            ])
        let engine = try JobEngine(supportDirectory: fixture.root.appending(path: "support"), concurrency: 1)
        _ = await engine.run(batch, settings: Settings()) { snapshot in snapshots.withLock { $0.append(snapshot) } }
        let observed = snapshots.withLock { $0 }
        #expect(zip(observed, observed.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
        #expect(observed.filter { $0.itemPhases == [.searching] }.allSatisfy { $0.currentFileFraction == nil })
        #expect(observed.contains { $0.currentFileFraction == 0.2 && $0.completedItems == 0 && $0.fraction == 0 })
        #expect(observed.last?.completedItems == 1)
        #expect(observed.last?.fraction == 1)
    }
}

private struct DownloadFixture {
    let root: URL
    let destination: URL
    let tools: MediaDownloadTools

    init(root: URL? = nil) throws {
        self.root =
            root ?? FileManager.default.temporaryDirectory.appending(path: "MacEaseDownload-" + UUID().uuidString)
        destination = self.root.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bin = self.root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let metadata =
            #"{"id":"fixture","title":"Fixture","webpage_url":"https://example.com/video","duration":10,"formats":[{"height":1080,"ext":"mp4"},{"height":720,"ext":"webm"}],"subtitles":{"en":[]},"automatic_captions":{"ja":[]}}"#
        try Data(metadata.utf8).write(to: self.root.appending(path: "metadata"))
        let launcher = """
            #!/bin/sh
            fixture='\(self.root.path)'
            printf '%s\\n' "$@" > "$fixture/arguments"
            case "$*" in
              *example.com/fail*) printf 'HTTP 403 https://private.example/?secret=private' >&2; exit 1;;
              *--dump-single-json*)
                if [ -f "$fixture/changed" ]; then printf '{"id":"different","title":"Changed"}'; else cat "$fixture/metadata"; fi
                exit 0;;
            esac
            if [ -f "$fixture/symlink" ]; then ln -s /etc/hosts download.mp4; else printf fixture-media > download.mp4; fi
            printf 'MACEASE:5:10\\n' >&2
            """
        try Self.executable(launcher, at: bin.appending(path: "python3"))
        try Self.executable(
            "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\",\"nb_read_packets\":\"3\"}]}'\n",
            at: bin.appending(path: "ffprobe"))
        for name in ["ffmpeg", "deno"] { try Self.executable("#!/bin/sh\nexit 0\n", at: bin.appending(path: name)) }
        tools = try MediaDownloadTools(directory: bin)
    }

    private static func executable(_ content: String, at url: URL) throws {
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
}
