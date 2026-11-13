import CryptoKit
import Foundation
import Testing

@testable import Engine

@Suite struct DownloadedMediaRepairTests {
    private func tools() throws -> MediaDownloadTools {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try MediaDownloadTools(directory: root.appending(path: "Vendor/build/media-tools/bin"))
    }

    private func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Resources"))
    }

    @Test func emptyNALTailRepairsWithoutChangingAnyMediaPacket() async throws {
        let tools = try tools()
        let folder = try TestVolume.makeFolder()
        let output = folder.appending(path: "download.mp4")
        try FileManager.default.copyItem(at: resource("h264-empty-nal-tail"), to: output)
        await #expect(throws: EngineError.self) {
            _ = try await MediaToolProcess().run(
                executable: tools.ffmpeg,
                arguments: [
                    "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode", "-i", output.path,
                    "-map", "0:v?", "-map", "0:a?", "-f", "null", "-",
                ], directory: folder, tools: tools, captureOutput: false)
        }
        try await MediaDownloader.verify(output, tools: tools)
        let actual = try await packetSignatures(output, tools: tools)
        #expect(actual.count == 143)
        let digest = SHA256.hash(data: Data(actual.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "f14e20abcd178110d1bb4024a45008c173224266203d3d521bd33fe5a3b3633a")
        try await MediaDownloader.verify(output, tools: tools)
    }

    @Test func otherVideoCorruptionStillFailsAndKeepsTheStagedBytes() async throws {
        let tools = try tools()
        let folder = try TestVolume.makeFolder()
        let output = folder.appending(path: "damaged.mp4")
        var damaged = try Data(contentsOf: resource("ffmpeg-h264-aac"))
        let listing = try await MediaToolProcess().run(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_entries", "packet=pos",
                "-of", "csv=p=0", try resource("ffmpeg-h264-aac").path,
            ], directory: folder, tools: tools)
        let offset = try #require(
            Int(String(decoding: listing.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        damaged.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
        try damaged.write(to: output)
        await #expect(throws: EngineError.self) { try await MediaDownloader.verify(output, tools: tools) }
        #expect(try Data(contentsOf: output) == damaged)
    }

    @Test func missingHLSFragmentCannotCommitAnIncompleteDownload() async throws {
        let tools = try tools()
        let folder = try TestVolume.makeFolder()
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
                "-c:a", "aac", "-f", "hls", "-hls_time", "1", "-hls_list_size", "0",
                folder.appending(path: "playlist.m3u8").path,
            ], directory: folder, tools: tools, captureOutput: false)
        try FileManager.default.removeItem(at: folder.appending(path: "playlist1.ts"))
        let server = Process()
        let endpoint = Pipe()
        server.executableURL = tools.python
        server.arguments = [
            "-I", "-B", "-c",
            """
            import functools,http.server,sys
            class Quiet(http.server.SimpleHTTPRequestHandler):
                def log_message(self,*args): pass
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=sys.argv[1]))
            print(server.server_port,flush=True)
            server.serve_forever()
            """, folder.path,
        ]
        server.standardOutput = endpoint
        server.standardError = FileHandle.nullDevice
        let terminated = AsyncStream<Void>.makeStream()
        server.terminationHandler = { _ in terminated.continuation.finish() }
        try server.run()
        var failure: (any Error)?
        do {
            try await verifyIncompleteDownload(endpoint: endpoint, folder: folder, tools: tools)
        } catch {
            failure = error
        }
        server.terminate()
        var termination = terminated.stream.makeAsyncIterator()
        _ = await termination.next()
        #expect(!server.isRunning)
        if let failure { throw failure }
    }

    private func verifyIncompleteDownload(endpoint: Pipe, folder: URL, tools: MediaDownloadTools) async throws {
        let port = String(decoding: endpoint.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let page = try #require(URL(string: "http://127.0.0.1:\(port)/playlist.m3u8"))
        let downloader = try MediaDownloader(tools: tools)
        let analysis = try await downloader.analyze(urls: [page])
        let source = try #require(analysis.sources.first)
        let destination = folder.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = MediaDownloadRequest(
            destination: destination, selections: [MediaDownloadSelection(source: source)])
        let outcome = await engine.run(try downloader.makeBatch(request), settings: Settings()) { _ in }
        guard case .failed = outcome.outcomes.first else {
            Issue.record("Missing fragments must fail: \(outcome.outcomes)")
            return
        }
        #expect(outcome.record == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    private func packetSignatures(_ output: URL, tools: MediaDownloadTools) async throws -> [String] {
        let result = try await MediaToolProcess().run(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-show_packets", "-show_data_hash", "sha256", "-show_entries",
                "packet=stream_index,pts_time,dts_time,duration_time,size,data_hash", "-of", "csv=p=0", output.path,
            ], directory: output.deletingLastPathComponent(), tools: tools)
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }
}
