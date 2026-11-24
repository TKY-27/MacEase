import AVFoundation
import CoreMedia
import CoreVideo
import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing
import VideoToolbox

@testable import Engine

private func fallbackTestToolsAvailable() -> Bool {
    (try? mediaFixtureTools()) != nil
}

extension Trait where Self == ConditionTrait {
    static var requiresFallbackMediaTools: Self {
        .enabled("Requires bundled ffmpeg/ffprobe media tools") {
            let present = fallbackTestToolsAvailable()
            if !present, ProcessInfo.processInfo.environment["MACEASE_DEVICE_TESTS"] == "1" {
                throw EngineError.fallbackToolMissing
            }
            return present
        }
    }
}

private enum FallbackFixtures {
    static func runFFmpeg(_ arguments: [String], in folder: URL, tools: MediaDownloadTools) async throws {
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: ["-v", "error", "-nostdin", "-y"] + arguments,
            directory: folder,
            tools: tools,
            captureOutput: false)
    }

    static func makeWMV(named name: String = "clip.wmv", duration: Double = 0.4, in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=\(duration)",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(duration)",
                "-c:v", "wmv2", "-c:a", "wmav2", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeMPEG2PS(named name: String = "clip.mpg", in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=25:duration=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpeg", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeMKVDTS(named name: String = "h264_dts.mkv", in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:v", "h264_videotoolbox", "-b:v", "400k",
                "-c:a", "dca", "-strict", "-2", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeMKVEAC3(named name: String = "h264_eac3.mkv", in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:v", "h264_videotoolbox", "-b:v", "400k",
                "-c:a", "eac3", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeMOVVorbis(named name: String = "h264_vorbis.mov", in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let intermediate = folder.appending(path: "source-\(UUID().uuidString).mkv")
        let movie = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:v", "mpeg4", "-c:a", "vorbis", "-ac", "2", "-strict", "-2", intermediate.path,
            ], in: folder, tools: tools)
        try await runFFmpeg(
            [
                "-i", intermediate.path,
                "-c:v", "h264_videotoolbox", "-b:v", "400k", "-c:a", "copy", "-strict", "-2", movie.path,
            ], in: folder, tools: tools)
        try? FileManager.default.removeItem(at: intermediate)
        return movie
    }

    static func makeWMA(named name: String = "song.wma", duration: Double = 0.6, in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(duration)",
                "-c:a", "wmav2", "-metadata", "title=Fallback Song", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeWavPack(
        named name: String = "lossless.wv", channelsLayout: String? = nil, in folder: URL
    ) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        var filter = "sine=frequency=440:sample_rate=48000:duration=0.4"
        if let channelsLayout { filter += ",aformat=channel_layouts=\(channelsLayout)" }
        try await runFFmpeg(["-f", "lavfi", "-i", filter, "-c:a", "wavpack", url.path], in: folder, tools: tools)
        return url
    }

    static func makeOggFLAC(named name: String = "track.oga", in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: name)
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:a", "flac", "-f", "ogg", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeAlphaFFV1(in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: "alpha.mkv")
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "color=c=red@0.5:size=128x128:rate=24:duration=0.3,format=yuva420p",
                "-c:v", "ffv1", "-pix_fmt", "yuva420p", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeHDR10FFV1(in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let url = folder.appending(path: "hdr10.mkv")
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i",
                "testsrc2=size=128x128:rate=24:duration=0.3,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
                "-c:v", "ffv1", "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
                url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeSubtitledMKV(in folder: URL) async throws -> URL {
        let tools = try mediaFixtureTools()
        let subtitle = folder.appending(path: "captions.srt")
        try Data("1\n00:00:00,000 --> 00:00:00,300\nHello\n".utf8).write(to: subtitle)
        let url = folder.appending(path: "subtitled.mkv")
        try await runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.4",
                "-i", subtitle.path,
                "-c:v", "ffv1", "-c:s", "srt", url.path,
            ], in: folder, tools: tools)
        return url
    }

    static func makeQuickTimeReferenceMovie(referencing relativeTarget: String) -> Data {
        func appendUInt32BE(_ buffer: inout Data, _ value: UInt32) {
            buffer.append(contentsOf: [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ])
        }
        func atom(_ type: String, _ payload: Data) -> Data {
            var buffer = Data()
            appendUInt32BE(&buffer, UInt32(8 + payload.count))
            buffer.append(contentsOf: type.utf8)
            buffer.append(payload)
            return buffer
        }
        var rdrf = Data([0, 0, 0, 0])
        rdrf.append(contentsOf: "url ".utf8)
        var target = Data(relativeTarget.utf8)
        target.append(0)
        appendUInt32BE(&rdrf, UInt32(target.count))
        rdrf.append(target)
        let moov = atom("moov", atom("rmra", atom("rmda", atom("rdrf", rdrf))))
        var ftyp = Data("qt  ".utf8)
        appendUInt32BE(&ftyp, 0)
        ftyp.append(contentsOf: "qt  ".utf8)
        return atom("ftyp", ftyp) + moov
    }

    static func context(
        in support: URL, omittedStreams: Set<UnpreservedStream> = [],
        phase: @escaping @Sendable (ItemPhase) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) -> ItemContext {
        ItemContext(
            settings: Settings(),
            staging: StagingArea(supportDirectory: support),
            omittedStreams: omittedStreams,
            phase: phase,
            progress: progress)
    }
}

@Suite(.serialized, .requiresFallbackMediaTools) struct StagedMediaFallbackCrashTests {
    @Test func unsupportedAudioCodecInMOVThrowsTypedErrorInsteadOfCrashing() async throws {
        let folder = try TestVolume.makeFolder()
        let movie = try await FallbackFixtures.makeMOVVorbis(in: folder)
        var thrown: EngineError?
        do {
            let input = try AudioInput(url: movie)
            let reader = try input.open()
            _ = try reader.read()
        } catch let error as EngineError {
            thrown = error
        }
        let error = try #require(thrown)
        switch error {
        case .decodeFailed, .unsupportedCodec:
            break
        default:
            Issue.record("expected decodeFailed or unsupportedCodec, got \(error)")
        }
    }
}

@Suite(.serialized, .requiresFallbackMediaTools) struct StagedMediaFallbackCoreTests {
    @Test func stagesLegacyVideoAndAudioFormatsIntoNativeIntermediates() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let wmv = try await FallbackFixtures.makeWMV(in: folder)
        let mpg = try await FallbackFixtures.makeMPEG2PS(in: folder)
        let mkvEAC3 = try await FallbackFixtures.makeMKVEAC3(in: folder)
        let wma = try await FallbackFixtures.makeWMA(in: folder)
        let wavpack = try await FallbackFixtures.makeWavPack(in: folder)
        let oggFlac = try await FallbackFixtures.makeOggFLAC(in: folder)

        for video in [wmv, mpg, mkvEAC3] {
            let phases = Mutex<[ItemPhase]>([])
            let context = FallbackFixtures.context(
                in: support, phase: { phase in phases.withLock { $0.append(phase) } })
            defer { context.removeStaging() }
            let staged = try await StagedMediaFallback.prepareVideo(video, context: context)
            #expect(staged.profile == .hevcSDR)
            #expect(phases.withLock { $0.contains(.convertingInput) })
            let opened = try await MediaInput.open(staged.stagedURL)
            #expect(opened.video != nil)
            #expect(opened.audio != nil)
        }

        for (audio, expectedLossy) in [(wma, true), (wavpack, false), (oggFlac, false)] {
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            let staged = try await StagedMediaFallback.prepareAudio(audio, context: context)
            #expect(staged.profile == .alacM4A)
            #expect(!staged.origin.isLosslessAudio == expectedLossy)
            let opened = try AudioInput(url: staged.stagedURL)
            #expect(opened.codec == .alac)
            #expect(opened.sampleRate == 48_000)
        }
    }

    @Test func alphaAndHDR10SourcesPreserveAlphaAndBitDepth() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()

        let alpha = try await FallbackFixtures.makeAlphaFFV1(in: folder)
        let alphaContext = FallbackFixtures.context(in: support)
        defer { alphaContext.removeStaging() }
        let stagedAlpha = try await StagedMediaFallback.prepareVideo(alpha, context: alphaContext)
        #expect(stagedAlpha.profile == .prores4444Alpha)
        let openedAlpha = try await MediaInput.open(stagedAlpha.stagedURL)
        #expect(openedAlpha.video?.hasAlpha == true)

        let hdr10 = try await FallbackFixtures.makeHDR10FFV1(in: folder)
        let hdrContext = FallbackFixtures.context(in: support)
        defer { hdrContext.removeStaging() }
        let stagedHDR = try await StagedMediaFallback.prepareVideo(hdr10, context: hdrContext)
        #expect(stagedHDR.profile == .hevcMain10)
        let openedHDR = try await MediaInput.open(stagedHDR.stagedURL)
        let hdrConfig = try await VideoProperties.hdrConfiguration(openedHDR)
        #expect(hdrConfig != nil)
    }

    @Test func profileSelectionUsesExplicitPixelFormatFor422And444() {
        let stream422 = StagedMediaFallback.Probe.Stream(
            index: 0, codecType: "video", codecName: "prores", codecTagString: nil,
            width: 1920, height: 1080, pixelFormat: "yuv422p10le", bitsPerRawSample: "10", bitsPerSample: nil,
            colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, colorRange: nil,
            channels: nil, channelLayout: nil, sampleFormat: nil, sampleRate: nil, duration: "1.0",
            disposition: nil, tags: nil)
        #expect(StagedMediaFallback.selectVideoProfile(for: stream422) == .proresStandard422)
        let probe = StagedMediaFallback.Probe(format: nil, streams: [stream422], chapters: nil)
        let args = StagedMediaFallback.videoTranscodeArguments(
            for: URL(fileURLWithPath: "/tmp/in.mkv"), probe: probe, videoStream: stream422, audioStream: nil,
            videoProfile: .proresStandard422, audioProfile: nil, output: URL(fileURLWithPath: "/tmp/out.mov"))
        #expect(args.contains("prores_videotoolbox"))
        #expect(args.contains("p210le"))
        #expect(!args.contains("yuv420p"))
    }

    @Test func surround51And71AudioPreserveChannelLayouts() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let tools = try mediaFixtureTools()

        let wv51Back = try await FallbackFixtures.makeWavPack(named: "surround51.wv", channelsLayout: "5.1", in: folder)
        let context51Back = FallbackFixtures.context(in: support)
        defer { context51Back.removeStaging() }
        let staged51Back = try await StagedMediaFallback.prepareAudio(wv51Back, context: context51Back)
        #expect(staged51Back.profile == .alacM4A)
        let input51Back = try AudioInput(url: staged51Back.stagedURL)
        #expect(input51Back.channels == 6)
        try AudioFormat.m4aAAC.validateLayout(input51Back)

        let eac351 = folder.appending(path: "surround51.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4,aformat=channel_layouts=5.1",
                "-c:a", "eac3", eac351.path,
            ], in: folder, tools: tools)
        let context51 = FallbackFixtures.context(in: support)
        defer { context51.removeStaging() }
        let staged51 = try await StagedMediaFallback.prepareAudio(eac351, context: context51)
        // E-AC-3 writes 5.1(side), which ALAC alters.
        #expect(staged51.profile == .cafPCM24)
        let input51 = try AudioInput(url: staged51.stagedURL)
        #expect(input51.channels == 6)
        try AudioFormat.m4aAAC.validateLayout(input51)

        let wv71 = try await FallbackFixtures.makeWavPack(named: "surround71.wv", channelsLayout: "7.1", in: folder)
        let context71 = FallbackFixtures.context(in: support)
        defer { context71.removeStaging() }
        let staged71 = try await StagedMediaFallback.prepareAudio(wv71, context: context71)
        #expect(staged71.profile == .cafPCM24)
        let input71 = try AudioInput(url: staged71.stagedURL)
        #expect(input71.channels == 8)
    }

    @Test func extraStreamsRequireConsentBeforeFFmpegRuns() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let subtitled = try await FallbackFixtures.makeSubtitledMKV(in: folder)

        let phases = Mutex<[ItemPhase]>([])
        let unconsented = FallbackFixtures.context(
            in: support, phase: { phase in phases.withLock { $0.append(phase) } })
        defer { unconsented.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.subtitle]))) {
            _ = try await StagedMediaFallback.prepareVideo(subtitled, context: unconsented)
        }
        #expect(!phases.withLock { $0.contains(.convertingInput) })
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "staging.json").path))
        let stagingMatches =
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "fallback.mov" } ?? []
        #expect(stagingMatches.isEmpty)

        let consented = FallbackFixtures.context(in: support, omittedStreams: [.subtitle])
        defer { consented.removeStaging() }
        let staged = try await StagedMediaFallback.prepareVideo(subtitled, context: consented)
        #expect(staged.omittedStreams == [.subtitle])
        #expect(consented.warnings == [.streamsOmitted([.subtitle])])
    }

    @Test func diskSpaceCheckRejectsBeforeSpawningFFmpeg() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let wmv = try await FallbackFixtures.makeWMV(in: folder)
        let context = FallbackFixtures.context(in: support)
        defer { context.removeStaging() }
        var capturedError: EngineError?
        do {
            _ = try await StagedMediaFallback.prepareVideo(wmv, context: context, availableBytes: { _ in 1_000 })
        } catch let error as EngineError {
            capturedError = error
        }
        guard case .insufficientDiskSpace(let required, let available) = capturedError else {
            Issue.record("expected insufficientDiskSpace, got \(String(describing: capturedError))")
            return
        }
        #expect(required > available)
        #expect(available == 1_000)

        let emptyDir = try TestVolume.makeFolder()
        #expect(throws: EngineError.fallbackToolMissing) {
            _ = try StagedMediaFallback.resolveTools(
                environment: ["MACEASE_MEDIA_TOOLS": emptyDir.path], bundleIdentifier: "test")
        }
    }

    @Test func securityRejectsConcatPlaylistAndReferenceMovieAndAcceptsTrickyNames() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let realClip = try await FallbackFixtures.makeWMV(named: "real.wmv", in: folder)

        let concatFile = folder.appending(path: "evil.concat")
        try Data("ffconcat version 1.0\nfile '\(realClip.path)'\n".utf8).write(to: concatFile)
        let concatContext = FallbackFixtures.context(in: support)
        defer { concatContext.removeStaging() }
        await #expect(throws: EngineError.self) {
            _ = try await StagedMediaFallback.prepareVideo(concatFile, context: concatContext)
        }

        let m3u8 = folder.appending(path: "playlist.m3u8")
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1.0,\n\(realClip.path)\n#EXT-X-ENDLIST\n".utf8)
            .write(to: m3u8)
        let m3u8Context = FallbackFixtures.context(in: support)
        defer { m3u8Context.removeStaging() }
        await #expect(throws: EngineError.self) {
            _ = try await StagedMediaFallback.prepareVideo(m3u8, context: m3u8Context)
        }

        let reference = folder.appending(path: "ref.mov")
        let mp4Source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let secret = folder.appending(path: "secret.mp4")
        try FileManager.default.copyItem(at: mp4Source, to: secret)
        try FallbackFixtures.makeQuickTimeReferenceMovie(referencing: "secret.mp4").write(to: reference)
        let refContext = FallbackFixtures.context(in: support)
        defer { refContext.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await StagedMediaFallback.prepareVideo(reference, context: refContext)
        }
        let tools = try mediaFixtureTools()
        let directProbe = try await MediaToolProcess().run(
            executable: tools.ffprobe,
            arguments: StagedMediaFallback.probeArguments(for: reference),
            directory: folder, tools: tools, captureOutput: true, includeTLSCertificate: false)
        let probedRef = try JSONDecoder().decode(StagedMediaFallback.Probe.self, from: directProbe.stdout)
        #expect(probedRef.videoStreams.isEmpty && probedRef.audioStreams.isEmpty)

        for trickyName in ["http:test.wmv", "-dash.wmv"] {
            let trickyURL = folder.appending(path: trickyName)
            try FileManager.default.copyItem(at: realClip, to: trickyURL)
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            let staged = try await StagedMediaFallback.prepareVideo(trickyURL, context: context)
            #expect(FileManager.default.fileExists(atPath: staged.stagedURL.path))
        }
    }

    @Test func cancellationStopsFFmpegAndCleansUpStaging() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let tools = try mediaFixtureTools()
        let uniqueName = "cancel-\(UUID().uuidString).wmv"
        let longClip = folder.appending(path: uniqueName)
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=20",
                "-c:v", "wmv2", longClip.path,
            ], in: folder, tools: tools)

        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let settings = Settings()
        let request = OperationRequest(op: .videoConvert, options: .video(.convert(.mp4)), inputs: [longClip])
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let started = Mutex(false)
        let task = Task {
            await engine.run(batch, settings: settings) { progress in
                if progress.itemPhases.first == .convertingInput {
                    started.withLock { $0 = true }
                }
            }
        }
        func hasRunningFFmpeg() throws -> Bool {
            let checker = Process()
            checker.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            checker.arguments = ["-f", uniqueName]
            try checker.run()
            checker.waitUntilExit()
            return checker.terminationStatus == 0
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var observedRunning = false
        while ContinuousClock.now < deadline {
            if started.withLock({ $0 }), try hasRunningFFmpeg() {
                observedRunning = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedRunning, "expected live ffmpeg child before cancel")
        task.cancel()
        let outcome = await task.value
        guard case .failed(.cancelled) = outcome.outcomes.first else {
            Issue.record("expected cancellation, got \(String(describing: outcome.outcomes))")
            return
        }
        #expect(try !hasRunningFFmpeg(), "ffmpeg child must exit after cancellation")
        let registryURL = support.appending(path: "staging.json")
        if FileManager.default.fileExists(atPath: registryURL.path) {
            let remaining = try JSONDecoder().decode([String].self, from: Data(contentsOf: registryURL))
            #expect(remaining.isEmpty)
        }
        let leftovers =
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "fallback.mov" } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func watchdogTerminatesStalledChildAndLiveDiskMonitorAborts() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let tools = try mediaFixtureTools()
        let stub = folder.appending(path: "stalled-tool.sh")
        let pidFile = folder.appending(path: "stalled.pid")
        try Data("#!/bin/sh\necho $$ > \"\(pidFile.path)\"\nexec sleep 30\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        var timedOutFailure: MediaToolProcess.Failure?
        do {
            _ = try await MediaToolProcess().runTyped(
                executable: stub, arguments: [], directory: folder, tools: tools,
                captureOutput: false, includeTLSCertificate: false, noProgressTimeout: .milliseconds(300))
            Issue.record("expected stalled child to time out")
        } catch let error as MediaToolProcess.Failure {
            timedOutFailure = error
        }
        #expect(timedOutFailure == .timedOut)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        #expect(kill(pid, 0) != 0)

        let longClip = folder.appending(path: "disk-drop.wmv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=20",
                "-c:v", "wmv2", longClip.path,
            ], in: folder, tools: tools)
        let queries = Mutex(0)
        let context = FallbackFixtures.context(in: support)
        defer { context.removeStaging() }
        var diskError: EngineError?
        do {
            _ = try await StagedMediaFallback.prepareVideo(
                longClip, context: context,
                availableBytes: { _ in
                    let count = queries.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    return count == 1 ? 10_000_000_000 : 1_000
                },
                diskMonitorInterval: .milliseconds(25))
            Issue.record("expected live disk drop to abort transcode")
        } catch let error as EngineError {
            diskError = error
        }
        guard case .insufficientDiskSpace(_, let available) = diskError else {
            Issue.record("expected insufficientDiskSpace on live drop, got \(String(describing: diskError))")
            return
        }
        #expect(available == 1_000)
    }
}

@Suite(.serialized, .requiresFallbackMediaTools) struct StagedMediaFallbackEndToEndTests {
    private func runJob(
        op: OperationID, options: OperationOptions, inputs: [URL], mode: Settings.OutputMode = .newFile,
        omittedStreams: Set<UnpreservedStream> = [],
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async throws -> (outcome: BatchOutcome, support: URL) {
        let support = try TestVolume.makeFolder()
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        var settings = Settings()
        settings.outputMode = mode
        let request = OperationRequest(op: op, options: options, inputs: inputs, omittedStreams: omittedStreams)
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let outcome = await engine.run(batch, settings: settings, progress: progress)
        return (outcome, support)
    }

    private func assertStagingEmpty(in support: URL) throws {
        let registryURL = support.appending(path: "staging.json")
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return }
        let remaining = try JSONDecoder().decode([String].self, from: Data(contentsOf: registryURL))
        #expect(remaining.isEmpty)
    }

    @Test func fileKindAndContentSnifferAcceptLegacyFormatsAndKeepTSAsText() throws {
        for ext in ["wmv", "asf", "mpg", "mpeg", "m2ts", "mts", "vob", "rm", "rmvb", "3gp", "3g2", "mxf", "dv", "ogv"] {
            #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/sample.\(ext)", isDirectory: false)) == .video)
        }
        for ext in ["wma", "ac3", "dts", "mp2", "wv", "ape", "tta", "amr", "ra", "mka"] {
            #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/sample.\(ext)", isDirectory: false)) == .audio)
        }
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/component.ts", isDirectory: false)) == .text)

        let folder = try TestVolume.makeFolder()
        let m2tsPacket = [UInt8](repeating: 0, count: 4) + [0x47] + [UInt8](repeating: 0, count: 187)
        let m2tsBytes = m2tsPacket + m2tsPacket + m2tsPacket + m2tsPacket
        let samples: [(String, [UInt8], FileKind)] = [
            ("clip.wmv", AudioInput.asfSignature + [0, 0, 0, 0], .video),
            ("clip.mpg", [0x00, 0x00, 0x01, 0xBA, 0x44, 0x00], .video),
            ("clip.m2ts", m2tsBytes, .video),
            ("clip.rm", Array(".RMF".utf8) + [0, 0, 0, 0], .video),
            ("clip.mxf", [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05], .video),
            ("audio.ac3", [0x0B, 0x77, 0x00, 0x00], .audio),
            ("audio.dts", [0x7F, 0xFE, 0x80, 0x01, 0x00], .audio),
            ("audio.wv", Array("wvpk".utf8) + [0, 0, 0, 0], .audio),
            ("audio.tta", Array("TTA1".utf8) + [0, 0, 0, 0], .audio),
            ("audio.amr", Array("#!AMR\n".utf8), .audio),
        ]
        for (name, bytes, kind) in samples {
            let file = folder.appending(path: name)
            try Data(bytes).write(to: file)
            #expect(try ContentSniffer.matches(file, kind: kind), "\(name)")
        }
        let falseTS = folder.appending(path: "coincidence.m2ts")
        let twoSyncOnly = [UInt8(0x47)] + [UInt8](repeating: 0, count: 187) + [0x47] + [UInt8](repeating: 0, count: 400)
        try Data(twoSyncOnly).write(to: falseTS)
        #expect(try !ContentSniffer.matches(falseTS, kind: .video))
    }

    @Test func endToEndVideoConversionsThroughJobEnginePreserveOriginalsAndCleanStaging() async throws {
        let folder = try TestVolume.makeFolder()
        let fixtures = [
            try await FallbackFixtures.makeWMV(named: "legacy.wmv", in: folder),
            try await FallbackFixtures.makeMPEG2PS(named: "broadcast.mpg", in: folder),
            try await FallbackFixtures.makeMKVDTS(named: "partial_dts.mkv", in: folder),
            try await FallbackFixtures.makeMKVEAC3(named: "partial_eac3.mkv", in: folder),
            try await FallbackFixtures.makeMOVVorbis(named: "partial_vorbis.mov", in: folder),
        ]

        for source in fixtures {
            let originalBytes = try Data(contentsOf: source)
            let (outcome, support) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [source])
            guard case .succeeded(let outputs, _) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record(
                    "expected MP4 conversion success for \(source.lastPathComponent), got \(String(describing: outcome.outcomes))"
                )
                continue
            }
            #expect(output.pathExtension.lowercased() == "mp4")
            let verified = try await MediaInput.open(output)
            #expect(verified.video != nil)
            #expect(verified.audio != nil)
            #expect(try Data(contentsOf: source) == originalBytes)
            try assertStagingEmpty(in: support)
        }
    }

    @Test func wmvToMOVConvertsInsteadOfSkippingAsAlreadyMOV() async throws {
        let folder = try TestVolume.makeFolder()
        let wmv = try await FallbackFixtures.makeWMV(named: "movie.wmv", in: folder)
        let originalBytes = try Data(contentsOf: wmv)

        // Control: native MOV skips convert(.mov).
        let supportControl = try TestVolume.makeFolder()
        let controlContext = FallbackFixtures.context(in: supportControl)
        defer { controlContext.removeStaging() }
        let stagedControl = try await StagedMediaFallback.prepareVideo(wmv, context: controlContext)
        let rawStagedInput = try await MediaInput.open(stagedControl.stagedURL)
        #expect(rawStagedInput.container == .mov)
        #expect(throws: SkipError.self) {
            _ = try VideoEdits.plan(
                .convert(.mov), input: rawStagedInput, source: try #require(rawStagedInput.video),
                settings: VideoSettings())
        }

        let (outcome, support) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mov)), inputs: [wmv])
        guard case .succeeded(let outputs, _) = outcome.outcomes.first, let output = outputs.first else {
            Issue.record("expected WMV->MOV success, got \(String(describing: outcome.outcomes))")
            return
        }
        #expect(output.lastPathComponent == "movie.mov")
        let converted = try await MediaInput.open(output)
        #expect(converted.video != nil)
        #expect(converted.audio?.codec == MediaCodec.aac)
        #expect(try Data(contentsOf: wmv) == originalBytes)
        try assertStagingEmpty(in: support)
    }

    @Test func wmaTrimAndLosslessWavPackTTAConversionsSucceed() async throws {
        let folder = try TestVolume.makeFolder()
        let wma = try await FallbackFixtures.makeWMA(named: "voice.wma", duration: 0.8, in: folder)
        let wmaBytes = try Data(contentsOf: wma)
        let (trimOutcome, trimSupport) = try await runJob(
            op: .audioTrim, options: .audio(.trim(start: 0.1, end: 0.5)), inputs: [wma])
        guard case .succeeded(let trimOutputs, _) = trimOutcome.outcomes.first, let trimmed = trimOutputs.first else {
            Issue.record("expected WMA trim success, got \(String(describing: trimOutcome.outcomes))")
            return
        }
        #expect(trimmed.pathExtension.lowercased() == "m4a")
        let trimmedAudio = try AudioInput(url: trimmed)
        #expect(trimmedAudio.codec == .aac)
        #expect((trimmedAudio.duration ?? 0) > 0.3 && (trimmedAudio.duration ?? 0) < 0.5)
        #expect(try Data(contentsOf: wma) == wmaBytes)
        try assertStagingEmpty(in: trimSupport)

        let tools = try mediaFixtureTools()
        let wavpack = try await FallbackFixtures.makeWavPack(named: "master.wv", in: folder)
        let tta = folder.appending(path: "master.tta")
        try await FallbackFixtures.runFFmpeg(
            ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4", "-c:a", "tta", tta.path],
            in: folder, tools: tools)
        for source in [wavpack, tta] {
            let sourceBytes = try Data(contentsOf: source)
            let (outcome, support) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.flac)), inputs: [source])
            guard case .succeeded(let outputs, _) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record(
                    "expected lossless convert success for \(source.lastPathComponent), got \(String(describing: outcome.outcomes))"
                )
                continue
            }
            let decoded = try AudioInput(url: output)
            #expect(decoded.codec == .flac)
            #expect(decoded.bitDepth == 16)
            #expect(try Data(contentsOf: source) == sourceBytes)
            try assertStagingEmpty(in: support)
        }
    }

    @Test func endToEndExtraStreamsConsentAndAlphaHDR10AndSurround51() async throws {
        let folder = try TestVolume.makeFolder()

        let subtitled = try await FallbackFixtures.makeSubtitledMKV(in: folder)
        let (blocked, blockedSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [subtitled])
        #expect(blocked.outcomes == [.failed(.invalidInput(.unpreservedStreams([.subtitle])))])
        try assertStagingEmpty(in: blockedSupport)

        let (consented, consentedSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [subtitled], omittedStreams: [.subtitle])
        guard case .succeeded(let outputs, let warnings) = consented.outcomes.first, !outputs.isEmpty else {
            Issue.record("expected consented convert success, got \(String(describing: consented.outcomes))")
            return
        }
        #expect(warnings.contains(.streamsOmitted([.subtitle])))
        try assertStagingEmpty(in: consentedSupport)

        let alpha = try await FallbackFixtures.makeAlphaFFV1(in: folder)
        let (alphaOutcome, alphaSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mov)), inputs: [alpha])
        guard case .succeeded(let alphaOutputs, _) = alphaOutcome.outcomes.first, let alphaOut = alphaOutputs.first
        else {
            Issue.record("expected alpha MOV success, got \(String(describing: alphaOutcome.outcomes))")
            return
        }
        #expect(try await MediaInput.open(alphaOut).video?.hasAlpha == true)
        try assertStagingEmpty(in: alphaSupport)

        let hdr10 = try await FallbackFixtures.makeHDR10FFV1(in: folder)
        let (hdrOutcome, hdrSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [hdr10])
        guard case .succeeded(let hdrOutputs, _) = hdrOutcome.outcomes.first, let hdrOut = hdrOutputs.first else {
            Issue.record("expected HDR10 MP4 success, got \(String(describing: hdrOutcome.outcomes))")
            return
        }
        let verifiedHDR = try await MediaInput.open(hdrOut)
        #expect(try await VideoProperties.hdrConfiguration(verifiedHDR) != nil)
        try assertStagingEmpty(in: hdrSupport)

        let tools = try mediaFixtureTools()
        let eac351 = folder.appending(path: "cinema51.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4,aformat=channel_layouts=5.1",
                "-c:a", "eac3", eac351.path,
            ], in: folder, tools: tools)
        let (surroundOutcome, surroundSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.m4aAAC)), inputs: [eac351])
        guard case .succeeded(let surroundOutputs, _) = surroundOutcome.outcomes.first,
            let surroundOut = surroundOutputs.first
        else {
            Issue.record("expected 5.1 E-AC-3->M4A success, got \(String(describing: surroundOutcome.outcomes))")
            return
        }
        let verifiedSurround = try AudioInput(url: surroundOut)
        #expect(verifiedSurround.channels == 6)
        try AudioFormat.m4aAAC.validateLayout(verifiedSurround)
        try assertStagingEmpty(in: surroundSupport)
    }

    @Test func replacedOriginalDuringFallbackAbortsCommitAndLeavesStagingEmpty() async throws {
        let folder = try TestVolume.makeFolder()
        let wmv = try await FallbackFixtures.makeWMV(named: "changing.wmv", duration: 1.5, in: folder)
        let replacementBytes = Data("replaced-by-user-mid-job".utf8)
        let mutated = Mutex(false)

        let (outcome, support) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [wmv], mode: .replace
        ) { progress in
            if progress.itemPhases.first == .encoding {
                let shouldWrite = mutated.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if shouldWrite {
                    try? replacementBytes.write(to: wmv, options: .atomic)
                }
            }
        }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try Data(contentsOf: wmv) == replacementBytes)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "changing.mp4").path))
        try assertStagingEmpty(in: support)

        let corruptWMV = folder.appending(path: "corrupt.wmv")
        let corruptBytes = Data(AudioInput.asfSignature + [0xFF, 0xFE, 0xFD, 0xFC])
        try corruptBytes.write(to: corruptWMV)
        let (failedOutcome, failedSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [corruptWMV])
        guard case .failed(.decodeFailed(let detail)) = failedOutcome.outcomes.first else {
            Issue.record("expected decodeFailed on corrupt WMV, got \(String(describing: failedOutcome.outcomes))")
            return
        }
        #expect(detail == "unrecognized video container")
        #expect(try Data(contentsOf: corruptWMV) == corruptBytes)
        try assertStagingEmpty(in: failedSupport)
    }

    @Test func sameFormatFallbackOperationsSaveNewFileInReplaceMode() async throws {
        for mode in [Settings.OutputMode.newFile, .replace] {
            let folder = try TestVolume.makeFolder()
            let wma = try await FallbackFixtures.makeWMA(named: "voice.wma", duration: 0.8, in: folder)
            let wmaBytes = try Data(contentsOf: wma)
            let (audioOutcome, audioSupport) = try await runJob(
                op: .audioTrim, options: .audio(.trim(start: 0.1, end: 0.5)), inputs: [wma], mode: mode)
            guard case .succeeded(let audioOutputs, let audioWarnings) = audioOutcome.outcomes.first,
                let trimmed = audioOutputs.first
            else {
                Issue.record("expected WMA trim success in \(mode), got \(String(describing: audioOutcome.outcomes))")
                continue
            }
            #expect(trimmed.lastPathComponent == "voice_trimmed.m4a")
            #expect(FileManager.default.fileExists(atPath: wma.path))
            #expect(try Data(contentsOf: wma) == wmaBytes)
            #expect(audioWarnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            try assertStagingEmpty(in: audioSupport)

            let wmv = try await FallbackFixtures.makeWMV(named: "clip.wmv", duration: 0.6, in: folder)
            let wmvBytes = try Data(contentsOf: wmv)
            let (videoOutcome, videoSupport) = try await runJob(
                op: .videoRemoveAudio, options: .video(.removeAudio), inputs: [wmv], mode: mode)
            guard case .succeeded(let videoOutputs, let videoWarnings) = videoOutcome.outcomes.first,
                let muted = videoOutputs.first
            else {
                Issue.record(
                    "expected WMV removeAudio success in \(mode), got \(String(describing: videoOutcome.outcomes))")
                continue
            }
            #expect(muted.lastPathComponent == "clip_noaudio.mp4")
            #expect(FileManager.default.fileExists(atPath: wmv.path))
            #expect(try Data(contentsOf: wmv) == wmvBytes)
            #expect(videoWarnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            try assertStagingEmpty(in: videoSupport)
        }
    }

    @Test func coverArtSurvivesIntermediateOrTriggersLossPolicy() async throws {
        let tools = try mediaFixtureTools()
        func makeWavPackWithCoverArt(in folder: URL) async throws -> URL {
            let base = try await FallbackFixtures.makeWavPack(named: "base.wv", in: folder)
            let cover = folder.appending(path: "cover.png")
            try await FallbackFixtures.runFFmpeg(
                ["-f", "lavfi", "-i", "color=c=blue:size=16x16:duration=0.1", "-frames:v", "1", cover.path],
                in: folder, tools: tools)
            let audioBytes = try Data(contentsOf: base)
            let imageBytes = try Data(contentsOf: cover)
            var value = Data("cover.png".utf8)
            value.append(0)
            value.append(imageBytes)
            var entry = Data()
            func appendUInt32LE(_ destination: inout Data, _ number: UInt32) {
                var little = number.littleEndian
                withUnsafeBytes(of: &little) { destination.append(contentsOf: $0) }
            }
            appendUInt32LE(&entry, UInt32(value.count))
            appendUInt32LE(&entry, 2)
            entry.append(contentsOf: "Cover Art (Front)".utf8)
            entry.append(0)
            entry.append(value)
            let tagSize = UInt32(entry.count + 32)
            var header = Data("APETAGEX".utf8)
            for field: UInt32 in [2_000, tagSize, 1, (1 << 31) | (1 << 29), 0, 0] { appendUInt32LE(&header, field) }
            var footer = Data("APETAGEX".utf8)
            for field: UInt32 in [2_000, tagSize, 1, 1 << 31, 0, 0] { appendUInt32LE(&footer, field) }
            let tagged = folder.appending(path: "album.wv")
            try (audioBytes + header + entry + footer).write(to: tagged)
            try FileManager.default.removeItem(at: base)
            try FileManager.default.removeItem(at: cover)
            return tagged
        }

        for mode in [Settings.OutputMode.newFile, .replace] {
            let flacFolder = try TestVolume.makeFolder()
            let sourceFLAC = try await makeWavPackWithCoverArt(in: flacFolder)
            let originalBytes = try Data(contentsOf: sourceFLAC)
            let (flacOutcome, flacSupport) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.flac)), inputs: [sourceFLAC], mode: mode)
            guard case .succeeded(let flacOutputs, let flacWarnings) = flacOutcome.outcomes.first,
                let flacURL = flacOutputs.first
            else {
                Issue.record(
                    "expected FLAC cover art success in \(mode), got \(String(describing: flacOutcome.outcomes))")
                continue
            }
            let tags = try await AudioInput(url: flacURL).tags()
            #expect(tags.artwork != nil)
            #expect(!flacWarnings.contains(.metadataDropped))
            #expect(flacWarnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: sourceFLAC) == originalBytes)
            try assertStagingEmpty(in: flacSupport)

            let wavFolder = try TestVolume.makeFolder()
            let sourceWAV = try await makeWavPackWithCoverArt(in: wavFolder)
            let wavOriginal = try Data(contentsOf: sourceWAV)
            let (wavOutcome, wavSupport) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.wav)), inputs: [sourceWAV], mode: mode)
            guard case .succeeded(let wavOutputs, let wavWarnings) = wavOutcome.outcomes.first, !wavOutputs.isEmpty
            else {
                Issue.record("expected WAV new-file success in \(mode), got \(String(describing: wavOutcome.outcomes))")
                continue
            }
            #expect(wavWarnings.contains(.metadataDropped))
            #expect(wavWarnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: sourceWAV) == wavOriginal)
            try assertStagingEmpty(in: wavSupport)
        }
    }

    @Test func droppedOriginalMetadataTriggersLossPolicyInBothModes() async throws {
        let tools = try mediaFixtureTools()
        for mode in [Settings.OutputMode.newFile, .replace] {
            let folder = try TestVolume.makeFolder()
            let taggedMKV = folder.appending(path: "tagged.mkv")
            try await FallbackFixtures.runFFmpeg(
                [
                    "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.3",
                    "-c:v", "ffv1", "-metadata", "title=MyClip", "-metadata", "custom_note=secret",
                    taggedMKV.path,
                ], in: folder, tools: tools)
            let mkvBytes = try Data(contentsOf: taggedMKV)
            let (videoOutcome, videoSupport) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mov)), inputs: [taggedMKV], mode: mode)
            guard case .succeeded(let outputs, let warnings) = videoOutcome.outcomes.first, !outputs.isEmpty else {
                Issue.record("expected MOV success in \(mode), got \(String(describing: videoOutcome.outcomes))")
                continue
            }
            #expect(warnings.contains(.videoMetadataDropped([.descriptiveMetadata])))
            #expect(warnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: taggedMKV) == mkvBytes)
            try assertStagingEmpty(in: videoSupport)

            let taggedWV = folder.appending(path: "tagged.wv")
            try await FallbackFixtures.runFFmpeg(
                [
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                    "-c:a", "wavpack", "-metadata", "custom_note=secret", taggedWV.path,
                ], in: folder, tools: tools)
            let wvBytes = try Data(contentsOf: taggedWV)
            let (audioOutcome, audioSupport) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.flac)), inputs: [taggedWV], mode: mode)
            guard case .succeeded(let outputs, let warnings) = audioOutcome.outcomes.first, !outputs.isEmpty else {
                Issue.record("expected FLAC success in \(mode), got \(String(describing: audioOutcome.outcomes))")
                continue
            }
            #expect(warnings.contains(.metadataDropped))
            #expect(warnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: taggedWV) == wvBytes)
            try assertStagingEmpty(in: audioSupport)
        }
    }

    @Test func highBitDepthAndFloatAudioPreservePrecisionAndEnforceLosslessRule() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()

        let sampleCount = 14_400
        let int32WAV = folder.appending(path: "src32.wav")
        let int32WV = folder.appending(path: "src32.wv")
        do {
            let format = try #require(
                AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48_000, channels: 1, interleaved: true))
            let writer = try AVAudioFile(
                forWriting: int32WAV, settings: format.settings, commonFormat: .pcmFormatInt32, interleaved: true)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)))
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            let destination = try #require(buffer.int32ChannelData?[0])
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<sampleCount {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                // Non-zero low byte fails any 24-bit truncation.
                let raw = Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32)) | 0x2B
                destination[index] = raw
            }
            try writer.write(from: buffer)
        }
        try await FallbackFixtures.runFFmpeg(
            ["-i", int32WAV.path, "-c:a", "wavpack", int32WV.path], in: folder, tools: tools)

        let int32Context = FallbackFixtures.context(in: support)
        defer { int32Context.removeStaging() }
        let stagedInt32 = try await StagedMediaFallback.prepareAudio(int32WV, context: int32Context)
        #expect(stagedInt32.profile == .cafPCM32)
        let refInt32File = try AVAudioFile(forReading: int32WAV, commonFormat: .pcmFormatInt32, interleaved: true)
        let stagedInt32File = try AVAudioFile(
            forReading: stagedInt32.stagedURL, commonFormat: .pcmFormatInt32, interleaved: true)
        #expect(refInt32File.length == stagedInt32File.length)
        func readAllInt32(_ file: AVAudioFile) throws -> [Int32] {
            var samples: [Int32] = []
            samples.reserveCapacity(Int(file.length))
            let chunk: AVAudioFrameCount = 4_096
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining))
                try file.read(into: buffer, frameCount: remaining)
                if buffer.frameLength == 0 { break }
                let channel = try #require(buffer.int32ChannelData?[0])
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            return samples
        }
        func readAllFloat32(_ file: AVAudioFile) throws -> [Float] {
            var samples: [Float] = []
            samples.reserveCapacity(Int(file.length))
            let chunk: AVAudioFrameCount = 4_096
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining))
                try file.read(into: buffer, frameCount: remaining)
                if buffer.frameLength == 0 { break }
                let channel = try #require(buffer.floatChannelData?[0])
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            return samples
        }

        let refInt32Samples = try readAllInt32(refInt32File)
        let stgInt32Samples = try readAllInt32(stagedInt32File)
        #expect(refInt32Samples.count == sampleCount)
        #expect(refInt32Samples.contains { ($0 & 0xFF) != 0 })
        #expect(refInt32Samples == stgInt32Samples)

        let floatWAV = folder.appending(path: "srcf32.wav")
        let floatWV = folder.appending(path: "srcf32.wv")
        do {
            let format = try #require(
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
            let writer = try AVAudioFile(
                forWriting: floatWAV, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)))
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            let destination = try #require(buffer.floatChannelData?[0])
            var state: UInt64 = 0xD1B5_4A32_D192_ED03
            for index in 0..<sampleCount {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(UInt32(truncatingIfNeeded: state >> 40)) / Float(1 << 24)
                destination[index] = (unit * 3.0) - 1.5
            }
            try writer.write(from: buffer)
        }
        try await FallbackFixtures.runFFmpeg(
            ["-i", floatWAV.path, "-c:a", "wavpack", floatWV.path], in: folder, tools: tools)
        let floatContext = FallbackFixtures.context(in: support)
        defer { floatContext.removeStaging() }
        let stagedFloat = try await StagedMediaFallback.prepareAudio(floatWV, context: floatContext)
        #expect(stagedFloat.profile == .cafPCMFloat32)
        let refFloatFile = try AVAudioFile(forReading: floatWAV, commonFormat: .pcmFormatFloat32, interleaved: true)
        let stagedFloatFile = try AVAudioFile(
            forReading: stagedFloat.stagedURL, commonFormat: .pcmFormatFloat32, interleaved: true)
        #expect(refFloatFile.length == stagedFloatFile.length)
        let refFloatSamples = try readAllFloat32(refFloatFile)
        let stgFloatSamples = try readAllFloat32(stagedFloatFile)
        #expect(refFloatSamples.count == sampleCount)
        #expect(refFloatSamples.contains { abs($0) > 1.0 })
        #expect(refFloatSamples == stgFloatSamples)

        for mode in [Settings.OutputMode.newFile, .replace] {
            let runFolder = try TestVolume.makeFolder()
            let copy32 = runFolder.appending(path: "master32.wv")
            try FileManager.default.copyItem(at: int32WV, to: copy32)
            let orig32 = try Data(contentsOf: copy32)
            let (refused, refusedSupport) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.flac)), inputs: [copy32], mode: mode)
            guard case .failed(.unsupportedCodec) = refused.outcomes.first else {
                Issue.record(
                    "expected >24-bit lossless refusal in \(mode), got \(String(describing: refused.outcomes))")
                continue
            }
            #expect(try Data(contentsOf: copy32) == orig32)
            try assertStagingEmpty(in: refusedSupport)

            let copyFloat = runFolder.appending(path: "masterf32.wv")
            try FileManager.default.copyItem(at: floatWV, to: copyFloat)
            let origFloat = try Data(contentsOf: copyFloat)
            let (floatOutcome, floatSupport) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.cafPCM)), inputs: [copyFloat], mode: mode)
            guard case .succeeded(let floatOutputs, let floatWarnings) = floatOutcome.outcomes.first,
                let floatOut = floatOutputs.first
            else {
                Issue.record("expected float CAF success in \(mode), got \(String(describing: floatOutcome.outcomes))")
                continue
            }
            #expect(try AudioInput(url: floatOut).isFloat)
            #expect(floatWarnings == (mode == .replace ? [.keptAsNewFileForFormat] : []))
            #expect(try Data(contentsOf: copyFloat) == origFloat)
            try assertStagingEmpty(in: floatSupport)
        }
    }

    @Test func vp9AlphaWithUnsupportedAudioPreservesAlphaOrAppliesLossPolicy() async throws {
        let tools = try mediaFixtureTools()
        func makeVP9AlphaDTS(in folder: URL) async throws -> URL {
            let url = folder.appending(path: "vp9_alpha_dts.mkv")
            try await FallbackFixtures.runFFmpeg(
                [
                    "-f", "lavfi", "-i", "color=c=red@0.5:size=128x128:rate=24:duration=0.3,format=yuva420p",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                    "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-c:a", "dca", "-strict", "-2", url.path,
                ], in: folder, tools: tools)
            return url
        }

        for mode in [Settings.OutputMode.newFile, .replace] {
            let movFolder = try TestVolume.makeFolder()
            let sourceMOV = try await makeVP9AlphaDTS(in: movFolder)
            let origMOV = try Data(contentsOf: sourceMOV)
            let (movOutcome, movSupport) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mov)), inputs: [sourceMOV], mode: mode)
            guard case .succeeded(let movOutputs, let movWarnings) = movOutcome.outcomes.first,
                let movOut = movOutputs.first
            else {
                Issue.record(
                    "expected VP9 alpha MOV success in \(mode), got \(String(describing: movOutcome.outcomes))")
                continue
            }
            let opened = try await MediaInput.open(movOut)
            #expect(opened.video?.hasAlpha == true)
            #expect(!movWarnings.contains(.videoTransparencyFlattened))
            #expect(movWarnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            let sampler = try await FrameSampler(
                input: opened, frameDuration: opened.frameDuration,
                edit: FrameEdit(displayOrientation: try opened.displayOrientation, preservesAlpha: true),
                start: 0, end: opened.duration)
            let decoded = try #require(try await sampler.next())
            CVPixelBufferLockBaseAddress(decoded.image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(decoded.image, .readOnly) }
            let base = try #require(CVPixelBufferGetBaseAddress(decoded.image))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(decoded.image)
            let centerAlpha = base.assumingMemoryBound(to: UInt8.self)[(64 * bytesPerRow) + (64 * 4) + 3]
            #expect(centerAlpha > 10 && centerAlpha < 245, "expected semi-transparent alpha, got \(centerAlpha)")
            #expect(try Data(contentsOf: sourceMOV) == origMOV)
            try assertStagingEmpty(in: movSupport)

            let mp4Folder = try TestVolume.makeFolder()
            let sourceMP4 = try await makeVP9AlphaDTS(in: mp4Folder)
            let origMP4 = try Data(contentsOf: sourceMP4)
            let (mp4Outcome, mp4Support) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [sourceMP4], mode: mode)
            guard case .succeeded(let mp4Outputs, let mp4Warnings) = mp4Outcome.outcomes.first, !mp4Outputs.isEmpty
            else {
                Issue.record(
                    "expected VP9 alpha MP4 success in \(mode), got \(String(describing: mp4Outcome.outcomes))")
                continue
            }
            #expect(mp4Warnings.contains(.videoTransparencyFlattened))
            #expect(mp4Warnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: sourceMP4) == origMP4)
            try assertStagingEmpty(in: mp4Support)
        }
    }

    @Test func vp9FourFourFourWebMTriggersFallbackThroughRealDecoderCheck() async throws {
        let tools = try mediaFixtureTools()
        for mode in [Settings.OutputMode.newFile, .replace] {
            let folder = try TestVolume.makeFolder()
            let webm = folder.appending(path: "vp9_444.webm")
            try await FallbackFixtures.runFFmpeg(
                [
                    "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.3,format=yuv444p",
                    "-c:v", "libvpx-vp9", "-profile:v", "1", "-pix_fmt", "yuv444p", webm.path,
                ], in: folder, tools: tools)
            let origBytes = try Data(contentsOf: webm)
            let native = try await MediaInput.open(webm)
            await #expect(throws: EngineError.unsupportedCodec("VPX image format")) {
                try await native.verifyDecodable()
            }
            let (outcome, support) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [webm], mode: mode)
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record("expected VP9 4:4:4 MP4 success in \(mode), got \(String(describing: outcome.outcomes))")
                continue
            }
            let verified = try await MediaInput.open(output)
            #expect(verified.codedSize == PixelSize(width: 128, height: 128))
            #expect(warnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: webm) == origBytes)
            try assertStagingEmpty(in: support)
        }
    }

    @Test func oddDimensionsPreservedInMOVAndHandledExplicitlyIn420() async throws {
        let tools = try mediaFixtureTools()
        func makeOddMKV(in folder: URL) async throws -> URL {
            let url = folder.appending(path: "odd.mkv")
            try await FallbackFixtures.runFFmpeg(
                [
                    "-f", "lavfi", "-i", "color=c=red:size=129x127:rate=24:duration=0.3",
                    "-c:v", "ffv1", "-pix_fmt", "yuv420p", url.path,
                ], in: folder, tools: tools)
            return url
        }

        for mode in [Settings.OutputMode.newFile, .replace] {
            let movFolder = try TestVolume.makeFolder()
            let oddMOV = try await makeOddMKV(in: movFolder)
            let origMOV = try Data(contentsOf: oddMOV)
            let (movOutcome, movSupport) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mov)), inputs: [oddMOV], mode: mode)
            guard case .succeeded(let movOutputs, let movWarnings) = movOutcome.outcomes.first,
                let movOut = movOutputs.first
            else {
                Issue.record("expected 129x127 MOV success in \(mode), got \(String(describing: movOutcome.outcomes))")
                continue
            }
            let verifiedMOV = try await MediaInput.open(movOut)
            #expect(verifiedMOV.codedSize == PixelSize(width: 129, height: 127))
            #expect(verifiedMOV.displaySize == PixelSize(width: 129, height: 127))
            #expect(movWarnings == (mode == .replace ? [.keptAsNewFileForFormat] : []))
            #expect(try Data(contentsOf: oddMOV) == origMOV)
            try assertStagingEmpty(in: movSupport)

            let mp4Folder = try TestVolume.makeFolder()
            let oddMP4 = try await makeOddMKV(in: mp4Folder)
            let origMP4 = try Data(contentsOf: oddMP4)
            let (mp4Outcome, mp4Support) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [oddMP4], mode: mode)
            guard case .succeeded(let mp4Outputs, let mp4Warnings) = mp4Outcome.outcomes.first, !mp4Outputs.isEmpty
            else {
                Issue.record(
                    "expected 129x127 MP4 success in \(mode), got \(String(describing: mp4Outcome.outcomes))")
                continue
            }
            #expect(mp4Warnings.contains(.videoMetadataDropped([.trackMetadata])))
            #expect(mp4Warnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: oddMP4) == origMP4)
            try assertStagingEmpty(in: mp4Support)
        }
    }

    @Test func nativeDecodeErrorDetailSurvivesWhenFallbackAlsoFails() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let brokenVideo = folder.appending(path: "corrupt.mkv")
        try Data("not a valid matroska container".utf8).write(to: brokenVideo)
        let brokenAudio = folder.appending(path: "corrupt.wav")
        try Data("RIFF\u{24}\0\0\0WAVEfmt \u{10}\0\0\0\0\0\0\0".utf8).write(to: brokenAudio)

        let expectedVideoDetail: String
        do {
            _ = try await MediaInput.open(brokenVideo)
            Issue.record("expected native MediaInput.open to fail")
            return
        } catch {
            guard case .decodeFailed(let detail) = EngineError.wrapping(error, path: brokenVideo.path) else {
                Issue.record("expected native decodeFailed, got \(error)")
                return
            }
            expectedVideoDetail = detail
        }
        let context = FallbackFixtures.context(in: support)
        defer { context.removeStaging() }
        do {
            _ = try await MediaInput.openWithFallback(brokenVideo, context: context)
            Issue.record("expected openWithFallback to fail on corrupt video")
        } catch let error as EngineError {
            #expect(error == .decodeFailed(expectedVideoDetail))
        }

        let expectedAudioDetail: String
        do {
            _ = try AudioInput(url: brokenAudio)
            Issue.record("expected native AudioInput to fail")
            return
        } catch {
            guard case .decodeFailed(let detail) = EngineError.wrapping(error, path: brokenAudio.path) else {
                Issue.record("expected native audio decodeFailed, got \(error)")
                return
            }
            expectedAudioDetail = detail
        }
        do {
            _ = try await AudioInput.openWithFallback(brokenAudio, context: context)
            Issue.record("expected AudioInput.openWithFallback to fail on corrupt audio")
        } catch let error as EngineError {
            #expect(error == .decodeFailed(expectedAudioDetail))
        }
    }

    @Test func fallbackAlwaysSavesDerivedFileAcrossEveryOperationFamilyInReplaceMode() async throws {
        var preset = try #require(Settings().platformPresets.first { $0.id == "discord" })
        preset.video?.maxBytes = nil

        let tools = try mediaFixtureTools()
        let videoCases: [(String, OperationID, OperationOptions, String, Bool)] = [
            ("edit", .videoRemoveAudio, .video(.removeAudio), "clip_noaudio.mp4", false),
            ("convert", .videoConvert, .video(.convert(.mp4)), "clip.mp4", false),
            (
                "compressQuality", .videoCompress, .video(.compress(VideoCompression(goal: .quality(0.6)))),
                "clip_compressed.mp4", false
            ),
            (
                "compressTargetSize", .videoCompress, .video(.compress(VideoCompression(goal: .bytes(80_000)))),
                "clip_compressed.mp4", true
            ),
            (
                "platformPreset", .videoCompress, .video(.compress(VideoCompression(goal: .platform(preset)))),
                "clip_compressed.mp4", false
            ),
            ("extractAudio", .videoExtractAudio, .video(.extractAudio(.m4aAAC)), "clip.m4a", false),
        ]
        for (label, op, options, expectedName, largeSource) in videoCases {
            let folder = try TestVolume.makeFolder()
            let support = try TestVolume.makeFolder()
            let source: URL
            if largeSource {
                source = folder.appending(path: "clip.wmv")
                try await FallbackFixtures.runFFmpeg(
                    [
                        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=1.5",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.5",
                        "-c:v", "wmv2", "-b:v", "1500k", "-c:a", "wmav2", source.path,
                    ], in: folder, tools: tools)
            } else {
                source = try await FallbackFixtures.makeWMV(named: "clip.wmv", duration: 0.6, in: folder)
            }
            let originalBytes = try Data(contentsOf: source)
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            var settings = Settings()
            settings.outputMode = .replace
            let batch = OperationPlanner.batch(
                for: OperationRequest(op: op, options: options, inputs: [source]), settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record("expected \(label) success, got \(String(describing: outcome.outcomes))")
                continue
            }
            #expect(output.lastPathComponent == expectedName, "\(label)")
            #expect(warnings.contains(.keptAsNewFileForFormat), "\(label)")
            #expect(try Data(contentsOf: source) == originalBytes, "\(label)")
            let undone = try await engine.undo(outcome.batchID)
            #expect(undone == [.restored], "\(label)")
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(label)")
            #expect(try Data(contentsOf: source) == originalBytes, "\(label)")
            try assertStagingEmpty(in: support)
        }

        let audioCases: [(String, OperationID, OperationOptions, String)] = [
            ("audioConvert", .audioConvert, .audio(.convert(.flac)), "song.flac"),
            ("audioTrim", .audioTrim, .audio(.trim(start: 0.1, end: 0.45)), "song_trimmed.m4a"),
            ("audioNormalize", .audioNormalize, .audio(.normalize(targetLoudness: -16.0)), "song_normalized.m4a"),
        ]
        for (label, op, options, expectedName) in audioCases {
            let folder = try TestVolume.makeFolder()
            let support = try TestVolume.makeFolder()
            let source = try await FallbackFixtures.makeWMA(named: "song.wma", duration: 0.6, in: folder)
            let originalBytes = try Data(contentsOf: source)
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            var settings = Settings()
            settings.outputMode = .replace
            let batch = OperationPlanner.batch(
                for: OperationRequest(op: op, options: options, inputs: [source]), settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record("expected \(label) success, got \(String(describing: outcome.outcomes))")
                continue
            }
            #expect(output.lastPathComponent == expectedName, "\(label)")
            #expect(warnings.contains(.keptAsNewFileForFormat), "\(label)")
            #expect(try Data(contentsOf: source) == originalBytes, "\(label)")
            let undone = try await engine.undo(outcome.batchID)
            #expect(undone == [.restored], "\(label)")
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(label)")
            #expect(try Data(contentsOf: source) == originalBytes, "\(label)")
            try assertStagingEmpty(in: support)
        }

        let recipeFolder = try TestVolume.makeFolder()
        let recipeSupport = try TestVolume.makeFolder()
        let recipeSource = try await FallbackFixtures.makeWMV(named: "clip.wmv", duration: 0.5, in: recipeFolder)
        let recipeOriginalBytes = try Data(contentsOf: recipeSource)
        let recipeEngine = try JobEngine(supportDirectory: recipeSupport, concurrency: 1)
        var replaceSettings = Settings()
        replaceSettings.outputMode = .replace
        let recipe = Recipe(name: "Delivery", variants: [OutputVariant(output: .videoMP4)])
        let recipeBatch = try RecipePlanner.batch(
            recipe: recipe, inputs: [recipeSource], destination: recipeFolder, settings: replaceSettings)
        let recipeOutcome = await recipeEngine.run(recipeBatch, settings: replaceSettings) { _ in }
        guard case .succeeded(let recipeOutputs, let recipeWarnings) = recipeOutcome.outcomes.first,
            let packaged = recipeOutputs.first
        else {
            Issue.record("expected recipe success, got \(String(describing: recipeOutcome.outcomes))")
            return
        }
        #expect(packaged.lastPathComponent == "Delivery")
        #expect(recipeWarnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: recipeSource) == recipeOriginalBytes)
        let undoneRecipe = try await recipeEngine.undo(recipeOutcome.batchID)
        #expect(undoneRecipe == [.restored])
        #expect(!FileManager.default.fileExists(atPath: packaged.path))
        #expect(try Data(contentsOf: recipeSource) == recipeOriginalBytes)
        try assertStagingEmpty(in: recipeSupport)
    }

    @Test func unfaithfulIntermediateCheckRejectsEveryFactMismatchAndQuadAudio() async throws {
        func videoStream(
            width: Int = 128, height: Int = 128, pixFmt: String = "yuv420p10le", bits: String? = "10",
            duration: String = "1.0", frames: String? = "24", startTime: String? = "0.0", rotation: Double? = nil
        ) -> StagedMediaFallback.Probe.Stream {
            let sideData = rotation.map {
                [StagedMediaFallback.Probe.SideData(sideDataType: "Display Matrix", rotation: $0)]
            }
            return StagedMediaFallback.Probe.Stream(
                index: 0, codecType: "video", codecName: "hevc", codecTagString: nil,
                width: width, height: height, pixelFormat: pixFmt, bitsPerRawSample: bits, bitsPerSample: nil,
                colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, colorRange: nil,
                channels: nil, channelLayout: nil, sampleFormat: nil, sampleRate: nil, duration: duration,
                disposition: nil, tags: nil, fieldOrder: nil, nbFrames: frames, rFrameRate: "24/1",
                startTime: startTime, sideDataList: sideData)
        }
        func audioStream(
            codec: String = "pcm_s24le", channels: Int = 2, layout: String? = "stereo",
            sampleFmt: String = "s32", bits: Int? = 24, rate: String = "48000", duration: String = "1.0",
            startTime: String? = "0.0"
        ) -> StagedMediaFallback.Probe.Stream {
            StagedMediaFallback.Probe.Stream(
                index: 1, codecType: "audio", codecName: codec, codecTagString: nil,
                width: nil, height: nil, pixelFormat: nil, bitsPerRawSample: nil, bitsPerSample: bits,
                colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, colorRange: nil,
                channels: channels, channelLayout: layout, sampleFormat: sampleFmt, sampleRate: rate,
                duration: duration, disposition: nil, tags: nil, startTime: startTime)
        }
        let baseVideo = videoStream()
        let baseAudio = audioStream()
        let original = StagedMediaFallback.Probe(format: nil, streams: [baseVideo, baseAudio], chapters: nil)
        try StagedMediaFallback.verifyIntermediate(
            original: original, intermediate: original, kind: .video(hasAudio: true))

        let mismatches:
            [(String, StagedMediaFallback.Probe, StagedMediaFallback.Probe, StagedMediaFallback.VerificationKind)] = [
                (
                    StagedMediaFallback.IntermediateFact.mappedStreams.rawValue,
                    original,
                    StagedMediaFallback.Probe(format: nil, streams: [baseVideo], chapters: nil),
                    .video(hasAudio: true)
                ),
                (
                    StagedMediaFallback.IntermediateFact.relativeStreamStart.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [baseVideo, audioStream(startTime: "0.5")], chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [baseVideo, audioStream(startTime: "0.0")], chapters: nil),
                    .video(hasAudio: true)
                ),
                (
                    StagedMediaFallback.IntermediateFact.videoDisplayDimensions.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(width: 640, height: 360, rotation: -90)], chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(width: 640, height: 360)], chapters: nil),
                    .video(hasAudio: false)
                ),
                (
                    StagedMediaFallback.IntermediateFact.videoPixelBitDepth.rawValue,
                    original,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(pixFmt: "yuv420p", bits: "8"), baseAudio], chapters: nil),
                    .video(hasAudio: true)
                ),
                (
                    StagedMediaFallback.IntermediateFact.videoChromaClass.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(pixFmt: "yuv444p10le")], chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(pixFmt: "yuv420p10le")], chapters: nil),
                    .video(hasAudio: false)
                ),
                (
                    StagedMediaFallback.IntermediateFact.videoAlpha.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(pixFmt: "yuva420p", bits: "8")], chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(pixFmt: "yuv420p", bits: "8")], chapters: nil),
                    .video(hasAudio: false)
                ),
                (
                    StagedMediaFallback.IntermediateFact.videoDuration.rawValue,
                    original,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [videoStream(frames: "10"), baseAudio], chapters: nil),
                    .video(hasAudio: true)
                ),
                (
                    StagedMediaFallback.IntermediateFact.audioChannelCount.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [audioStream(channels: 4, layout: "quad")], chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [audioStream(channels: 5, layout: "5.0")], chapters: nil),
                    .audio
                ),
                (
                    StagedMediaFallback.IntermediateFact.audioChannelLayout.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [audioStream(channels: 4, layout: "quad")], chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [audioStream(channels: 4, layout: "quad(side)")], chapters: nil),
                    .audio
                ),
                (
                    StagedMediaFallback.IntermediateFact.audioSampleRate.rawValue,
                    StagedMediaFallback.Probe(format: nil, streams: [audioStream(rate: "96000")], chapters: nil),
                    StagedMediaFallback.Probe(format: nil, streams: [audioStream(rate: "48000")], chapters: nil),
                    .audio
                ),
                (
                    StagedMediaFallback.IntermediateFact.audioPrecisionClass.rawValue,
                    StagedMediaFallback.Probe(
                        format: nil, streams: [audioStream(codec: "pcm_f64le", sampleFmt: "dbl", bits: 64)],
                        chapters: nil),
                    StagedMediaFallback.Probe(
                        format: nil, streams: [audioStream(codec: "pcm_f32le", sampleFmt: "flt", bits: 32)],
                        chapters: nil),
                    .audio
                ),
                (
                    StagedMediaFallback.IntermediateFact.audioDuration.rawValue,
                    StagedMediaFallback.Probe(format: nil, streams: [audioStream(duration: "2.0")], chapters: nil),
                    StagedMediaFallback.Probe(format: nil, streams: [audioStream(duration: "0.5")], chapters: nil),
                    .audio
                ),
            ]
        for (expectedFact, origProbe, intProbe, kind) in mismatches {
            do {
                try StagedMediaFallback.verifyIntermediate(original: origProbe, intermediate: intProbe, kind: kind)
                Issue.record("expected unfaithful failure for \(expectedFact)")
            } catch EngineError.fallbackConversionUnfaithful(let detail) {
                #expect(detail.contains(expectedFact), "expected \(expectedFact) in \(detail)")
            }
        }

        let folder = try TestVolume.makeFolder()
        let quad = try await FallbackFixtures.makeWavPack(named: "quad.wv", channelsLayout: "quad", in: folder)
        let quadBytes = try Data(contentsOf: quad)
        for mode in [Settings.OutputMode.newFile, .replace] {
            let (outcome, support) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.flac)), inputs: [quad], mode: mode)
            guard case .failed(.fallbackConversionUnfaithful(let detail)) = outcome.outcomes.first else {
                Issue.record(
                    "expected fallbackConversionUnfaithful on quad in \(mode), got \(String(describing: outcome.outcomes))"
                )
                continue
            }
            #expect(detail.contains(StagedMediaFallback.IntermediateFact.audioChannelLayout.rawValue))
            #expect(try Data(contentsOf: quad) == quadBytes)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "quad.flac").path))
            try assertStagingEmpty(in: support)
        }
    }

    @Test func side51WavPackUsesCAFAndPreservesSideLayout() async throws {
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let side51 = try await FallbackFixtures.makeWavPack(
            named: "side51.wv", channelsLayout: "5.1(side)", in: folder)
        let context = FallbackFixtures.context(in: support)
        defer { context.removeStaging() }
        let staged = try await StagedMediaFallback.prepareAudio(side51, context: context)
        #expect(staged.profile == .cafPCM24)
        let probed = try await StagedMediaFallback.probe(staged.stagedURL)
        #expect(probed.audioStreams.first?.channelLayout == "5.1(side)")
        #expect(probed.audioStreams.first?.channels == 6)
    }

    @Test func audioStreamMetadataTagsCarryToTagBearingTargetsAndWarnOnTagless() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let taggedMKA = folder.appending(path: "stream_tags.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                "-c:a", "wavpack",
                "-metadata:s:a:0", "title=Stream Only Title",
                "-metadata:s:a:0", "artist=Stream Only Artist",
                taggedMKA.path,
            ], in: folder, tools: tools)
        let probed = try await StagedMediaFallback.probe(taggedMKA)
        #expect(probed.format?.tags?["title"] == nil)
        #expect(
            probed.audioStreams.first?.tags?["TITLE"] == "Stream Only Title"
                || probed.audioStreams.first?.tags?["title"] == "Stream Only Title")

        let (flacOutcome, flacSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [taggedMKA], mode: .replace)
        guard case .succeeded(let flacOutputs, let flacWarnings) = flacOutcome.outcomes.first,
            let flacURL = flacOutputs.first
        else {
            Issue.record("expected FLAC success, got \(String(describing: flacOutcome.outcomes))")
            return
        }
        let tags = try await AudioInput(url: flacURL).tags()
        #expect(tags.title == "Stream Only Title")
        #expect(tags.artist == "Stream Only Artist")
        #expect(!flacWarnings.contains(.metadataDropped))
        #expect(flacWarnings.contains(.keptAsNewFileForFormat))
        try assertStagingEmpty(in: flacSupport)

        let (wavOutcome, wavSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.wav)), inputs: [taggedMKA], mode: .replace)
        guard case .succeeded(let wavOutputs, let wavWarnings) = wavOutcome.outcomes.first, !wavOutputs.isEmpty else {
            Issue.record("expected WAV success, got \(String(describing: wavOutcome.outcomes))")
            return
        }
        #expect(wavWarnings.contains(.metadataDropped))
        #expect(wavWarnings.contains(.keptAsNewFileForFormat))
        try assertStagingEmpty(in: wavSupport)
    }

    @Test func dolbyVisionWithUnsupportedAudioEmitsDolbyVisionRemovedWarning() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let hlgSource = try #require(
            Bundle.module.url(forResource: "x265-hlg", withExtension: "mov", subdirectory: "Resources"))
        let asset = AVURLAsset(url: hlgSource)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let dvOnly = folder.appending(path: "dv84.mov")
        let writer = try AVAssetWriter(outputURL: dvOnly, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                    kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: kVTHDRMetadataInsertionMode_Auto,
                ],
            ])
        try #require(writer.canAdd(writerInput))
        writer.add(writerInput)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .hdrFrames)
        let deadline = ContinuousClock.now + .seconds(30)
        while let sample = try await reader.nextSample() {
            while !writerInput.isReadyForMoreMediaData {
                try #require(writer.status == .writing && ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(writerInput.append(sample))
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)

        let dvDTS = folder.appending(path: "dv84_dts.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-i", dvOnly.path,
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                "-c:v", "copy", "-c:a", "dca", "-strict", "-2", "-shortest", dvDTS.path,
            ], in: folder, tools: tools)
        let probed = try await StagedMediaFallback.probe(dvDTS)
        #expect(probed.videoStreams.first?.hasDolbyVision == true)

        let originalBytes = try Data(contentsOf: dvDTS)
        let (outcome, support) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [dvDTS], mode: .replace)
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, !outputs.isEmpty else {
            Issue.record("expected DV 8.4 + DTS MP4 success, got \(String(describing: outcome.outcomes))")
            return
        }
        #expect(warnings.contains(.dolbyVisionRemoved))
        #expect(warnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: dvDTS) == originalBytes)
        try assertStagingEmpty(in: support)
    }

    @Test func disabledTrackInterlacedFieldOrderAndTagKeyMismatchAreDetected() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        let movDTS = folder.appending(path: "enabled_dts.mov")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.3",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                "-c:v", "h264_videotoolbox", "-b:v", "400k",
                "-c:a", "dca", "-strict", "-2", movDTS.path,
            ], in: folder, tools: tools)
        var bytes = try Data(contentsOf: movDTS)
        let tkhd = Data("tkhd".utf8)
        let range = try #require(bytes.range(of: tkhd))
        // Clear QuickTime tkhd enabled flag (bit 0).
        bytes[range.upperBound + 3] &= ~0x01
        let disabledMOV = folder.appending(path: "disabled_dts.mov")
        try bytes.write(to: disabledMOV)
        let disabledTrack = try #require(try await AVURLAsset(url: disabledMOV).loadTracks(withMediaType: .video).first)
        #expect(try await disabledTrack.load(.isEnabled) == false)

        let (movOutcome, movSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mov)), inputs: [disabledMOV], mode: .replace)
        guard case .succeeded(let movOutputs, _) = movOutcome.outcomes.first, let convertedMOV = movOutputs.first else {
            Issue.record("expected disabled-track MOV success, got \(String(describing: movOutcome.outcomes))")
            return
        }
        let outTrack = try #require(try await AVURLAsset(url: convertedMOV).loadTracks(withMediaType: .video).first)
        #expect(try await outTrack.load(.isEnabled) == false)
        try assertStagingEmpty(in: movSupport)

        let (aviOutcome, aviSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.avi)), inputs: [disabledMOV], mode: .replace)
        guard case .succeeded(_, let aviWarnings) = aviOutcome.outcomes.first else {
            Issue.record("expected disabled-track AVI success, got \(String(describing: aviOutcome.outcomes))")
            return
        }
        let dropped = aviWarnings.compactMap { warning -> [VideoMetadataProperty]? in
            if case .videoMetadataDropped(let properties) = warning { return properties }
            return nil
        }.flatMap { $0 }
        #expect(dropped.contains(.enabledState))
        try assertStagingEmpty(in: aviSupport)

        let interlaced = folder.appending(path: "interlaced.mpg")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=25:duration=0.4",
                "-vf", "setfield=bff", "-c:v", "mpeg2video", "-flags", "+ildct+ilme",
                "-f", "mpeg", interlaced.path,
            ], in: folder, tools: tools)
        let probedInterlaced = try await StagedMediaFallback.probe(interlaced)
        #expect(probedInterlaced.videoStreams.first?.fieldOrder == "bb")
        let (interlacedOutcome, interlacedSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [interlaced], mode: .replace)
        guard case .succeeded(_, let interlacedWarnings) = interlacedOutcome.outcomes.first else {
            Issue.record("expected interlaced MP4 success, got \(String(describing: interlacedOutcome.outcomes))")
            return
        }
        let interlacedDropped = interlacedWarnings.compactMap { warning -> [VideoMetadataProperty]? in
            if case .videoMetadataDropped(let properties) = warning { return properties }
            return nil
        }.flatMap { $0 }
        #expect(interlacedDropped.contains(.trackMetadata))
        try assertStagingEmpty(in: interlacedSupport)

        let sameValueMKV = folder.appending(path: "same_value.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.3",
                "-c:v", "ffv1",
                "-metadata", "title=SharedValue",
                "-metadata", "custom_tag=SharedValue",
                sameValueMKV.path,
            ], in: folder, tools: tools)
        let (tagOutcome, tagSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mov)), inputs: [sameValueMKV], mode: .replace)
        guard case .succeeded(_, let tagWarnings) = tagOutcome.outcomes.first else {
            Issue.record("expected same-value MKV MOV success, got \(String(describing: tagOutcome.outcomes))")
            return
        }
        #expect(tagWarnings.contains(.videoMetadataDropped([.descriptiveMetadata])))
        try assertStagingEmpty(in: tagSupport)
    }

    @Test func rotatedVideoBakesOrientationWithoutDoubleRotation() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let rawLandscape = folder.appending(path: "raw_landscape.mov")
        let rotated = folder.appending(path: "portrait_dts.mov")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=0.3",
                "-c:v", "h264_videotoolbox", "-b:v", "400k", rawLandscape.path,
            ], in: folder, tools: tools)
        try await FallbackFixtures.runFFmpeg(
            [
                "-display_rotation", "90", "-i", rawLandscape.path,
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                "-c:v", "copy", "-c:a", "dca", "-strict", "-2", rotated.path,
            ], in: folder, tools: tools)
        let probed = try await StagedMediaFallback.probe(rotated)
        let videoStream = try #require(probed.videoStreams.first)
        #expect(videoStream.codedSize == PixelSize(width: 640, height: 360))
        #expect(videoStream.displaySize == PixelSize(width: 360, height: 640))

        let (outcome, support) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [rotated], mode: .replace)
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let output = outputs.first else {
            Issue.record("expected rotated MOV->MP4 success, got \(String(describing: outcome.outcomes))")
            return
        }
        let opened = try await MediaInput.open(output)
        #expect(opened.displaySize == PixelSize(width: 360, height: 640))
        #expect(opened.codedSize == PixelSize(width: 360, height: 640))
        #expect(opened.transform == .identity)
        #expect(warnings.contains(.keptAsNewFileForFormat))
        try assertStagingEmpty(in: support)
    }

    @Test func float64VideoAudioExtractionRefusesLossyPrecisionDropAndAudioStagesAsFloat64() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()

        let mkvFloat64 = folder.appending(path: "master_f64.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.3",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                "-c:v", "ffv1", "-c:a", "pcm_f64le", mkvFloat64.path,
            ], in: folder, tools: tools)
        let (extractOutcome, extractSupport) = try await runJob(
            op: .videoExtractAudio, options: .video(.extractAudio(.cafPCM)), inputs: [mkvFloat64], mode: .replace)
        guard case .failed(.unsupportedCodec) = extractOutcome.outcomes.first else {
            Issue.record(
                "expected unsupportedCodec on float64 extractAudio, got \(String(describing: extractOutcome.outcomes))")
            return
        }
        try assertStagingEmpty(in: extractSupport)

        let mkaFloat64 = folder.appending(path: "audio_f64.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
                "-c:a", "pcm_f64le", mkaFloat64.path,
            ], in: folder, tools: tools)
        let audioContext = FallbackFixtures.context(in: support)
        defer { audioContext.removeStaging() }
        let staged = try await StagedMediaFallback.prepareAudio(mkaFloat64, context: audioContext)
        #expect(staged.profile == .cafPCMFloat64)
        #expect(staged.origin.isFloat)
        #expect(staged.origin.bitDepth == 64)
        let (flacOutcome, flacSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [mkaFloat64], mode: .newFile)
        guard case .failed(.unsupportedCodec) = flacOutcome.outcomes.first else {
            Issue.record("expected unsupportedCodec on float64->FLAC, got \(String(describing: flacOutcome.outcomes))")
            return
        }
        try assertStagingEmpty(in: flacSupport)
    }

    @Test func openWithFallbackPreservesWatchdogDiskAndUnfaithfulErrors() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let support = try TestVolume.makeFolder()
        let wmv = try await FallbackFixtures.makeWMV(named: "probe_err.wmv", in: folder)
        let wma = try await FallbackFixtures.makeWMA(named: "probe_err.wma", in: folder)
        let quad = try await FallbackFixtures.makeWavPack(named: "quad_open.wv", channelsLayout: "quad", in: folder)

        let fakeBin = folder.appending(path: "fake-tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeProbe = fakeBin.appending(path: "ffprobe")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: fakeProbe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeProbe.path)
        for name in ["python3", "qjs", "ffmpeg"] {
            let link = fakeBin.appending(path: name)
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: tools.directory.appending(path: name))
        }
        let stalledTools = try MediaDownloadTools(directory: fakeBin)

        let videoTimeoutContext = FallbackFixtures.context(in: support)
        defer { videoTimeoutContext.removeStaging() }
        do {
            _ = try await MediaInput.openWithFallback(
                wmv, context: videoTimeoutContext, tools: stalledTools, probeNoProgressTimeout: .milliseconds(200))
            Issue.record("expected timeout from MediaInput.openWithFallback")
        } catch EngineError.decodeFailed(let detail) {
            #expect(detail == MediaToolProcess.timedOutMessage)
        }

        let audioTimeoutContext = FallbackFixtures.context(in: support)
        defer { audioTimeoutContext.removeStaging() }
        do {
            _ = try await AudioInput.openWithFallback(
                wma, context: audioTimeoutContext, tools: stalledTools, probeNoProgressTimeout: .milliseconds(200))
            Issue.record("expected timeout from AudioInput.openWithFallback")
        } catch EngineError.decodeFailed(let detail) {
            #expect(detail == MediaToolProcess.timedOutMessage)
        }

        let diskContext = FallbackFixtures.context(in: support)
        defer { diskContext.removeStaging() }
        do {
            _ = try await MediaInput.openWithFallback(wmv, context: diskContext, availableBytes: { _ in 1_000 })
            Issue.record("expected insufficientDiskSpace from MediaInput.openWithFallback")
        } catch EngineError.insufficientDiskSpace {
            // Expected error preserved.
        }

        let quadContext = FallbackFixtures.context(in: support)
        defer { quadContext.removeStaging() }
        do {
            _ = try await AudioInput.openWithFallback(quad, context: quadContext)
            Issue.record("expected fallbackConversionUnfaithful from AudioInput.openWithFallback")
        } catch EngineError.fallbackConversionUnfaithful {
            // Expected error preserved.
        }
    }

    @Test func watchdogIgnoresNonProgressNoiseAndResetsOnAdvancingOutTime() async throws {
        // Unit-test the monotonic progress reset predicate.
        let predicate = StagedMediaFallback.makeProgressWatchdogReset()
        #expect(!predicate("progress=continue"))
        #expect(!predicate("frame=12"))
        #expect(!predicate("out_time_us=N/A"))
        #expect(!predicate("out_time_us=0"))
        #expect(!predicate("out_time_us=-10"))
        #expect(predicate("out_time_us=100000"))
        #expect(!predicate("out_time_us=100000"))
        #expect(!predicate("out_time_us=50000"))
        #expect(predicate("out_time_us=250000"))
        #expect(!predicate("progress=end"))

        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        let noisyStub = folder.appending(path: "noisy.sh")
        let noisyPID = folder.appending(path: "noisy.pid")
        try Data(
            """
            #!/bin/sh
            echo $$ > "\(noisyPID.path)"
            while true; do
                echo "progress=continue"
                echo "out_time_us=0"
                echo "noise" >&2
                sleep 0.1
            done
            """.utf8
        ).write(to: noisyStub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noisyStub.path)

        var timedOutFailure: MediaToolProcess.Failure?
        do {
            _ = try await MediaToolProcess().runTyped(
                executable: noisyStub, arguments: [], directory: folder, tools: tools,
                captureOutput: false, includeTLSCertificate: false,
                noProgressTimeout: .milliseconds(500),
                watchdogReset: MediaToolProcess.WatchdogReset(
                    matches: StagedMediaFallback.makeProgressWatchdogReset()))
            Issue.record("expected noisy non-advancing child to time out")
        } catch let failure as MediaToolProcess.Failure {
            timedOutFailure = failure
        }
        #expect(timedOutFailure == .timedOut)
        let noisyPIDText = try String(contentsOf: noisyPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noisyProcessID = try #require(Int32(noisyPIDText))
        #expect(kill(noisyProcessID, 0) != 0)

        let advancingStub = folder.appending(path: "advancing.sh")
        try Data(
            """
            #!/bin/sh
            for t in 100000 200000 300000 400000 500000 600000; do
                sleep 0.2
                echo "out_time_us=$t"
            done
            echo "progress=end"
            """.utf8
        ).write(to: advancingStub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: advancingStub.path)

        _ = try await MediaToolProcess().run(
            executable: advancingStub, arguments: [], directory: folder, tools: tools,
            captureOutput: false, includeTLSCertificate: false,
            noProgressTimeout: .seconds(1),
            watchdogReset: MediaToolProcess.WatchdogReset(
                matches: StagedMediaFallback.makeProgressWatchdogReset()))
    }

    @Test func decodabilityProbeBoundsScannedPacketsOnAudioHeavyContainer() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        // Generate a real VP9 4:4:4 keyframe sentinel.
        let vp9444 = folder.appending(path: "sentinel444.webm")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24:duration=0.1",
                "-frames:v", "1", "-c:v", "libvpx-vp9", "-pix_fmt", "yuv444p", vp9444.path,
            ], in: folder, tools: tools)
        var sentinelDemuxer = try MatroskaDemuxer(url: vp9444)
        var sentinelPacket: MediaPacket?
        while let packet = try sentinelDemuxer.nextPacket() {
            if packet.track == sentinelDemuxer.tracks.first(where: \.isVideo)?.number {
                sentinelPacket = packet
                break
            }
        }
        let vp9Packet = try #require(sentinelPacket)

        // Confirm the sentinel fails when reached.
        let reachableMKV = folder.appending(path: "reachable_sentinel.mkv")
        var framedVideo = MediaTrack(number: 1, kind: .video(width: 64, height: 64), codec: .vp9)
        framedVideo.defaultDuration = 41_666_667
        let audio = MediaTrack(number: 2, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus)
        do {
            var muxer = try MatroskaMuxer(url: reachableMKV, tracks: [framedVideo, audio], webm: false)
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: 0, isKeyframe: true, payload: vp9Packet.payload))
            try muxer.finish()
            let opened = try await MediaInput.open(reachableMKV)
            var sawUnsupported = false
            do {
                try await opened.verifyDecodable()
            } catch EngineError.unsupportedCodec {
                sawUnsupported = true
            }
            #expect(sawUnsupported)
        }

        // Bound 1: verifyContainerVideoDecodable stops before packet 270.
        let decodeBoundedMKV = folder.appending(path: "decode_bounded.mkv")
        do {
            var muxer = try MatroskaMuxer(url: decodeBoundedMKV, tracks: [framedVideo, audio], webm: false)
            for index in 0..<270 {
                try muxer.write(
                    MediaPacket(
                        track: 2, timestamp: Int64(index) * 20_000_000, isKeyframe: true,
                        payload: Data([0xF8, 0xFF, 0xFE])))
            }
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: 270 * 20_000_000, isKeyframe: true, payload: vp9Packet.payload))
            try muxer.finish()
            let opened = try await MediaInput.open(decodeBoundedMKV)
            try await opened.verifyDecodable()
        }

        // 300 leading audio packets keep 24 fps.
        let delayedVideoMKV = folder.appending(path: "delayed_24fps.mkv")
        let unframedVideo = MediaTrack(number: 1, kind: .video(width: 64, height: 64), codec: .vp9)
        let frameSpacingNs: Int64 = 41_666_667
        do {
            var muxer = try MatroskaMuxer(url: delayedVideoMKV, tracks: [unframedVideo, audio], webm: false)
            for index in 0..<300 {
                try muxer.write(
                    MediaPacket(
                        track: 2, timestamp: Int64(index) * 20_000_000, isKeyframe: true,
                        payload: Data([0xF8, 0xFF, 0xFE])))
            }
            for frameIndex in 0..<6 {
                let stamp = 6_000_000_000 + Int64(frameIndex) * frameSpacingNs
                try muxer.write(
                    MediaPacket(
                        track: 1, timestamp: stamp, isKeyframe: frameIndex == 0,
                        payload: vp9Packet.payload))
            }
            try muxer.finish()
            let opened = try await MediaInput.open(delayedVideoMKV)
            let measured = try #require(opened.video?.defaultDuration)
            #expect(measured >= 41_000_000 && measured <= 43_000_000)
        }

        // Single-frame video reaching EOF still opens cleanly.
        let singleFrameMKV = folder.appending(path: "single_frame.mkv")
        do {
            var muxer = try MatroskaMuxer(url: singleFrameMKV, tracks: [unframedVideo, audio], webm: false)
            try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: vp9Packet.payload))
            try muxer.finish()
            let opened = try await MediaInput.open(singleFrameMKV)
            #expect(opened.video?.defaultDuration == nil)
        }

        // Bound 2: exceeding packet limit throws decodeFailed.
        let rateBoundedMKV = folder.appending(path: "rate_bounded.mkv")
        let excessPackets = MediaInput.frameRateProbePacketLimit + 10
        do {
            var muxer = try MatroskaMuxer(url: rateBoundedMKV, tracks: [unframedVideo, audio], webm: false)
            for index in 0..<excessPackets {
                try muxer.write(
                    MediaPacket(
                        track: 2, timestamp: Int64(index) * 20_000_000, isKeyframe: true,
                        payload: Data([0xF8, 0xFF, 0xFE])))
            }
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(excessPackets) * 20_000_000, isKeyframe: true,
                    payload: Data(repeating: 0xAA, count: 64)))
            try muxer.finish()
            // Truncate final packet past the packet bound.
            var bytes = try Data(contentsOf: rateBoundedMKV)
            bytes.removeLast(32)
            try bytes.write(to: rateBoundedMKV)
            var sawDecodeFailed = false
            do {
                _ = try await MediaInput.open(rateBoundedMKV)
                Issue.record("expected frame-rate packet limit failure")
            } catch EngineError.decodeFailed(let detail) {
                sawDecodeFailed = detail.contains("packet limit")
            }
            #expect(sawDecodeFailed)
        }
    }

    @Test func contentDefaultPolicyContinuesFallbackInNewFileAndReplaceModeWithoutPrematureStaging() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let subtitle = folder.appending(path: "captions.srt")
        try Data("1\n00:00:00,000 --> 00:00:00,300\nHello\n".utf8).write(to: subtitle)

        let subtitledAudioMKV = folder.appending(path: "subtitled_av.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-i", subtitle.path,
                "-c:v", "ffv1", "-c:a", "dca", "-strict", "-2", "-c:s", "srt", subtitledAudioMKV.path,
            ], in: folder, tools: tools)
        let originalVideoBytes = try Data(contentsOf: subtitledAudioMKV)

        // Ask policy still blocks before staging.
        do {
            let askSupport = try TestVolume.makeFolder()
            let engine = try JobEngine(supportDirectory: askSupport, concurrency: 1)
            var settings = Settings()
            settings.outputMode = .replace
            let request = OperationRequest(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [subtitledAudioMKV],
                unpreservedStreams: .ask)
            let batch = OperationPlanner.batch(for: request, settings: settings)
            let phases = Mutex<[ItemPhase]>([])
            let outcome = await engine.run(batch, settings: settings) { progress in
                phases.withLock { $0.append(contentsOf: progress.itemPhases) }
            }
            #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.subtitle])))])
            #expect(!phases.withLock { $0.contains(.convertingInput) })
            #expect(try Data(contentsOf: subtitledAudioMKV) == originalVideoBytes)
            try assertStagingEmpty(in: askSupport)
        }

        // Automatic omission continues in both modes.
        let videoCases: [(Settings.OutputMode, OperationID, OperationOptions, String)] = [
            (.newFile, .videoConvert, .video(.convert(.mp4)), "subtitled_av.mp4"),
            (.replace, .videoConvert, .video(.convert(.mp4)), "subtitled_av.mp4"),
            (.replace, .videoRemoveAudio, .video(.removeAudio), "subtitled_av_noaudio.mp4"),
        ]
        for (mode, op, options, expectedName) in videoCases {
            let runFolder = try TestVolume.makeFolder()
            let source = runFolder.appending(path: "subtitled_av.mkv")
            try FileManager.default.copyItem(at: subtitledAudioMKV, to: source)
            let support = try TestVolume.makeFolder()
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            var settings = Settings()
            settings.outputMode = mode
            let request = OperationRequest(
                op: op, options: options, inputs: [source], unpreservedStreams: .omitFromNewFiles)
            let batch = OperationPlanner.batch(for: request, settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            #expect(outcome.batchID == batch.id)
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record(
                    "expected automatic omission in \(mode) \(op), got \(String(describing: outcome.outcomes))")
                continue
            }
            #expect(output.lastPathComponent == expectedName)
            #expect(warnings.contains(.streamsOmitted([.subtitle])))
            #expect(warnings.contains(.keptAsNewFileForFormat) == (mode == .replace))
            #expect(try Data(contentsOf: source) == originalVideoBytes)
            #expect(try await engine.undo(outcome.batchID) == [.restored])
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(try Data(contentsOf: source) == originalVideoBytes)
            try assertStagingEmpty(in: support)
        }

        // Audio fallback with extra stream continues.
        let dualMKA = folder.appending(path: "dual.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.6",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=0.6",
                "-map", "0:a", "-map", "1:a", "-c:a", "wmav2", dualMKA.path,
            ], in: folder, tools: tools)
        let originalAudioBytes = try Data(contentsOf: dualMKA)
        let audioSupport = try TestVolume.makeFolder()
        let audioEngine = try JobEngine(supportDirectory: audioSupport, concurrency: 1)
        var replaceSettings = Settings()
        replaceSettings.outputMode = .replace
        let audioRequest = OperationRequest(
            op: .audioTrim, options: .audio(.trim(start: 0.1, end: 0.4)), inputs: [dualMKA],
            unpreservedStreams: .omitFromNewFiles)
        let audioBatch = OperationPlanner.batch(for: audioRequest, settings: replaceSettings)
        let audioOutcome = await audioEngine.run(audioBatch, settings: replaceSettings) { _ in }
        guard case .succeeded(let audioOutputs, let audioWarnings) = audioOutcome.outcomes.first,
            let trimmed = audioOutputs.first
        else {
            Issue.record(
                "expected audio fallback omitFromNewFiles success, got \(String(describing: audioOutcome.outcomes))")
            return
        }
        #expect(trimmed.lastPathComponent == "dual_trimmed.m4a")
        #expect(audioWarnings.contains(.streamsOmitted([.audio])))
        #expect(audioWarnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: dualMKA) == originalAudioBytes)
        #expect(try await audioEngine.undo(audioOutcome.batchID) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: trimmed.path))
        #expect(try Data(contentsOf: dualMKA) == originalAudioBytes)
        try assertStagingEmpty(in: audioSupport)
    }

    @Test func joinedSourcesWithLaterConsentAfterFallbackEndsInQuestion() async throws {
        let folder = try TestVolume.makeFolder()
        let firstFallback = try await FallbackFixtures.makeWMV(named: "first.wmv", duration: 0.4, in: folder)
        let secondSubtitled = try await FallbackFixtures.makeSubtitledMKV(in: folder)
        let firstOriginal = try Data(contentsOf: firstFallback)
        let secondOriginal = try Data(contentsOf: secondSubtitled)

        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: firstFallback, duration: 0.4, stamp: try MediaSourceStamp(url: firstFallback)),
            VideoEditSource(url: secondSubtitled, duration: 0.4, stamp: try MediaSourceStamp(url: secondSubtitled)),
        ]
        edit.segments = [
            VideoSegment(start: 0, end: 0.3, sourceIndex: 0),
            VideoSegment(start: 0, end: 0.3, sourceIndex: 1),
        ]

        for mode in [Settings.OutputMode.newFile, .replace] {
            let support = try TestVolume.makeFolder()
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            var settings = Settings()
            settings.outputMode = mode
            let request = OperationRequest(
                op: .videoEdit, options: .video(.edit(edit)), inputs: [firstFallback],
                unpreservedStreams: .omitFromNewFiles)
            let batch = OperationPlanner.batch(for: request, settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.subtitle])))])
            #expect(try Data(contentsOf: firstFallback) == firstOriginal)
            #expect(try Data(contentsOf: secondSubtitled) == secondOriginal)
            try assertStagingEmpty(in: support)
        }
    }

    @Test func fallbackConsentReadsSameOmittedSetAsNativeOnReRun() async throws {
        let folder = try TestVolume.makeFolder()
        let nativeFixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let nativeClip = folder.appending(path: "native.mp4")
        try FileManager.default.copyItem(at: nativeFixture, to: nativeClip)
        let nativeInput = try await MediaInput.open(nativeClip)
        let nativeDuration = Double(nativeInput.duration) / Double(Nanoseconds.perSecond)
        let subtitled = try await FallbackFixtures.makeSubtitledMKV(in: folder)
        let subtitledStamp = try MediaSourceStamp(url: subtitled)

        // Re-run passes omitted streams to primary.
        var primaryFallbackEdit = VideoEdit()
        primaryFallbackEdit.sources = [
            VideoEditSource(url: subtitled, duration: 0.4, stamp: subtitledStamp),
            VideoEditSource(url: nativeClip, duration: nativeDuration, stamp: try MediaSourceStamp(url: nativeClip)),
        ]
        primaryFallbackEdit.segments = [
            VideoSegment(start: 0, end: 0.3, sourceIndex: 0),
            VideoSegment(start: 0, end: min(0.3, nativeDuration), sourceIndex: 1),
        ]
        do {
            let support = try TestVolume.makeFolder()
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            let settings = Settings()
            let request = OperationRequest(
                op: .videoEdit, options: .video(.edit(primaryFallbackEdit)), inputs: [subtitled],
                unpreservedStreams: .omitFromNewFiles)
            let batch = OperationPlanner.batch(for: request, settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, !outputs.isEmpty else {
                Issue.record(
                    "expected primary-fallback joined edit success, got \(String(describing: outcome.outcomes))")
                return
            }
            #expect(warnings.contains(.streamsOmitted([.subtitle])))
            try assertStagingEmpty(in: support)
        }

        // Secondary fallback reads per-source omissions only.
        var secondaryFallbackEdit = VideoEdit()
        secondaryFallbackEdit.sources = [
            VideoEditSource(url: nativeClip, duration: nativeDuration, stamp: try MediaSourceStamp(url: nativeClip)),
            VideoEditSource(url: subtitled, duration: 0.4, stamp: subtitledStamp),
        ]
        secondaryFallbackEdit.segments = [
            VideoSegment(start: 0, end: min(0.3, nativeDuration), sourceIndex: 0),
            VideoSegment(start: 0, end: 0.3, sourceIndex: 1),
        ]
        do {
            let support = try TestVolume.makeFolder()
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            let settings = Settings()
            let request = OperationRequest(
                op: .videoEdit, options: .video(.edit(secondaryFallbackEdit)), inputs: [nativeClip],
                unpreservedStreams: .omitFromNewFiles)
            let batch = OperationPlanner.batch(for: request, settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.subtitle])))])
            try assertStagingEmpty(in: support)
        }

        // Explicit secondary omissions entry succeeds cleanly.
        do {
            let support = try TestVolume.makeFolder()
            let engine = try JobEngine(supportDirectory: support, concurrency: 1)
            let settings = Settings()
            let batch = MediaEditing.video(
                url: nativeClip, edit: secondaryFallbackEdit, settings: settings,
                omissions: [subtitled: StreamOmission(stamp: subtitledStamp, streams: [.subtitle])])
            let outcome = await engine.run(batch, settings: settings) { _ in }
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, !outputs.isEmpty else {
                Issue.record("expected explicit secondary consent success, got \(String(describing: outcome.outcomes))")
                return
            }
            #expect(warnings.contains(.streamsOmitted([.subtitle])))
            try assertStagingEmpty(in: support)
        }
    }

    private func measureAVMarkerTimestamps(in url: URL) async throws -> (video: [Double], audio: [Double]) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)

        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)
        #expect(videoReader.startReading())

        var videoFlashes: [Double] = []
        while let sample = videoOutput.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let channelSum = Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
                let brightness = channelSum / 3
                if brightness > 128, videoFlashes.last.map({ pts - $0 > 0.2 }) ?? true {
                    videoFlashes.append(pts)
                }
            }
        }
        #expect(videoReader.status == .completed)

        let audioReader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        audioOutput.alwaysCopiesSampleData = false
        audioReader.add(audioOutput)
        #expect(audioReader.startReading())

        var audioBursts: [Double] = []
        while let sample = audioOutput.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite,
                let formatDesc = CMSampleBufferGetFormatDescription(sample),
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
                let block = CMSampleBufferGetDataBuffer(sample)
            else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let rate = asbd.mSampleRate
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer else { continue }
            let totalFloats = length / MemoryLayout<Float>.size
            let frames = totalFloats / channels
            pointer.withMemoryRebound(to: Float.self, capacity: totalFloats) { samples in
                for frame in 0..<frames {
                    var peak: Float = 0
                    for channel in 0..<channels {
                        peak = max(peak, abs(samples[frame * channels + channel]))
                    }
                    if peak > 0.1 {
                        let onset = pts + Double(frame) / rate
                        if audioBursts.last.map({ onset - $0 > 0.2 }) ?? true {
                            audioBursts.append(onset)
                        }
                    }
                }
            }
        }
        #expect(audioReader.status == .completed)
        return (videoFlashes, audioBursts)
    }

    @Test func lateAudioAndLateVideoPreserveStartOffsetsThroughConversion() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        // Tolerance catches 44 ms AAC priming drift.
        let markerSyncTolerance = 0.010
        let clipEnd = 3.0
        let firstMarker = 1.0
        let secondMarker = 2.5

        struct OffsetCase {
            let name: String
            let videoStart: Double
            let audioStart: Double
        }

        let cases = [
            OffsetCase(name: "late_audio", videoStart: 0.0, audioStart: 0.5),
            OffsetCase(name: "late_video", videoStart: 0.5, audioStart: 0.0),
            OffsetCase(name: "both_late", videoStart: 0.25, audioStart: 0.75),
        ]

        for offsetCase in cases {
            let source = folder.appending(path: "\(offsetCase.name).mkv")
            let videoDuration = clipEnd - offsetCase.videoStart
            let audioDuration = clipEnd - offsetCase.audioStart
            let frameOne = Int(((firstMarker - offsetCase.videoStart) * 24.0).rounded())
            let frameTwo = Int(((secondMarker - offsetCase.videoStart) * 24.0).rounded())
            let burstOne = firstMarker - offsetCase.audioStart
            let burstTwo = secondMarker - offsetCase.audioStart
            let videoFilter =
                "color=c=black:s=64x64:r=24:d=\(videoDuration),"
                + "drawbox=x=0:y=0:w=64:h=64:color=white:t=fill:enable='eq(n,\(frameOne))+eq(n,\(frameTwo))'"
            let audioFilter =
                "aevalsrc=exprs='if(between(t,\(burstOne),\(burstOne + 0.02))"
                + "+between(t,\(burstTwo),\(burstTwo + 0.02)),0.8*sin(2*PI*1000*t),0)':s=48000:d=\(audioDuration)"

            var args: [String] = []
            if offsetCase.videoStart > 0 { args += ["-itsoffset", String(offsetCase.videoStart)] }
            args += ["-f", "lavfi", "-i", videoFilter]
            if offsetCase.audioStart > 0 { args += ["-itsoffset", String(offsetCase.audioStart)] }
            args += [
                "-f", "lavfi", "-i", audioFilter,
                "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_s16le", source.path,
            ]
            try await FallbackFixtures.runFFmpeg(args, in: folder, tools: tools)
            let originalBytes = try Data(contentsOf: source)

            let (outcome, support) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [source], mode: .replace)
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let output = outputs.first else {
                Issue.record(
                    "expected \(offsetCase.name) conversion success, got \(String(describing: outcome.outcomes))")
                continue
            }
            #expect(warnings.contains(.keptAsNewFileForFormat))
            #expect(try Data(contentsOf: source) == originalBytes)

            let markers = try await measureAVMarkerTimestamps(in: output)
            #expect(markers.video.count == 2)
            #expect(markers.audio.count == 2)
            if markers.video.count == 2, markers.audio.count == 2 {
                let startDelta = markers.audio[0] - markers.video[0]
                let endDelta = markers.audio[1] - markers.video[1]
                #expect(
                    abs(startDelta) <= markerSyncTolerance,
                    "\(offsetCase.name) start sync drift: \(startDelta)s")
                #expect(
                    abs(endDelta) <= markerSyncTolerance,
                    "\(offsetCase.name) end sync drift: \(endDelta)s")
            }
            try assertStagingEmpty(in: support)
        }
    }

    @Test func conflictingContainerAndAudioStreamTagsKeepContainerPrecedenceAndWarn() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        let conflictMKA = folder.appending(path: "conflict_tags.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:a", "wavpack",
                "-metadata", "title=Container Title",
                "-metadata", "artist=Container Artist",
                "-metadata", "album=Container Album",
                "-metadata:s:a:0", "title=Track Title",
                "-metadata:s:a:0", "artist=Track Artist",
                "-metadata:s:a:0", "album=Track Album",
                conflictMKA.path,
            ], in: folder, tools: tools)
        let conflictOriginal = try Data(contentsOf: conflictMKA)
        let (outcome, support) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [conflictMKA], mode: .replace)
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let flac = outputs.first else {
            Issue.record("expected conflicting-tag conversion success, got \(String(describing: outcome.outcomes))")
            return
        }
        #expect(warnings.contains(.metadataDropped))
        #expect(warnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: conflictMKA) == conflictOriginal)
        let tags = try FLACMetadata.tags(in: flac)
        #expect(tags.title == "Container Title")
        #expect(tags.artist == "Container Artist")
        #expect(tags.album == "Container Album")
        try assertStagingEmpty(in: support)

        let matchingMKA = folder.appending(path: "matching_tags.mka")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:a", "wavpack",
                "-metadata", "title=Shared Title",
                "-metadata:s:a:0", "title=Shared Title",
                matchingMKA.path,
            ], in: folder, tools: tools)
        let (matchOutcome, matchSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [matchingMKA], mode: .newFile)
        guard case .succeeded(let matchOutputs, let matchWarnings) = matchOutcome.outcomes.first,
            let matchFlac = matchOutputs.first
        else {
            Issue.record("expected matching-tag conversion success, got \(String(describing: matchOutcome.outcomes))")
            return
        }
        #expect(!matchWarnings.contains(.metadataDropped))
        #expect(try FLACMetadata.tags(in: matchFlac).title == "Shared Title")
        try assertStagingEmpty(in: matchSupport)
    }

    @Test func openWithFallbackPreservesDiskFullAccessAndSignalledChildErrors() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let wma = try await FallbackFixtures.makeWMA(in: folder)

        func makeStubTools(named name: String, script: String) throws -> MediaDownloadTools {
            let bin = folder.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let ffmpeg = bin.appending(path: "ffmpeg")
            try Data(script.utf8).write(to: ffmpeg)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
            for sibling in ["python3", "qjs", "ffprobe"] {
                let source = tools.directory.appending(path: sibling)
                try FileManager.default.createSymbolicLink(
                    at: bin.appending(path: sibling), withDestinationURL: source)
            }
            return try MediaDownloadTools(directory: bin)
        }

        // ENOSPC stays a save error.
        let diskFullTools = try makeStubTools(
            named: "stub-enospc", script: "#!/bin/sh\necho 'No space left on device' >&2\nexit 1\n")
        do {
            let support = try TestVolume.makeFolder()
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            _ = try await AudioInput.openWithFallback(wma, context: context, tools: diskFullTools)
            Issue.record("expected ENOSPC child to fail")
        } catch EngineError.commitFailed(let detail) {
            #expect(detail.lowercased().contains("disk space"))
        }

        // Permission denied stays permissionDenied.
        let accessTools = try makeStubTools(
            named: "stub-eacces", script: "#!/bin/sh\necho 'Permission denied' >&2\nexit 1\n")
        do {
            let support = try TestVolume.makeFolder()
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            _ = try await AudioInput.openWithFallback(wma, context: context, tools: accessTools)
            Issue.record("expected permission-denied child to fail")
        } catch EngineError.permissionDenied {
            // Preserved typed permission error.
        }

        // Signalled child stays an unexpected termination error.
        let signalledTools = try makeStubTools(
            named: "stub-sigkill", script: "#!/bin/sh\nkill -9 $$\n")
        do {
            let support = try TestVolume.makeFolder()
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            _ = try await AudioInput.openWithFallback(wma, context: context, tools: signalledTools)
            Issue.record("expected signalled child to fail")
        } catch EngineError.unexpected(let detail) {
            #expect(detail.contains("signal 9"))
        }

        // Ordinary media rejection restores native unsupportedCodec.
        let mediaRejectTools = try makeStubTools(
            named: "stub-badmedia",
            script: "#!/bin/sh\necho 'Invalid data found when processing input' >&2\nexit 1\n")
        do {
            let support = try TestVolume.makeFolder()
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            _ = try await AudioInput.openWithFallback(wma, context: context, tools: mediaRejectTools)
            Issue.record("expected media-rejection child to fail")
        } catch EngineError.unsupportedCodec(let codec) {
            #expect(codec == "Windows Media Audio")
        }
    }

    @Test func variableFrameRateFallbackEmitsWarningWhileConstantRateAndExplicitFPSDoNot() async throws {
        #expect(!StagedMediaFallback.hasVariableFrameIntervals([0.041, 0.042, 0.042, 0.041, 0.042]))
        #expect(
            StagedMediaFallback.hasVariableFrameIntervals(
                Array(repeating: 1.0 / 24.0, count: 11) + Array(repeating: 1.0 / 12.0, count: 6)))

        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        // 12 fast then 6 slow frames.
        let vfrMKV = folder.appending(path: "vfr.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.75",
                "-vf", "setpts=if(lt(N\\,12)\\,N\\,12+(N-12)*2)",
                "-fps_mode", "passthrough", "-c:v", "ffv1", vfrMKV.path,
            ], in: folder, tools: tools)
        let vfrOriginal = try Data(contentsOf: vfrMKV)

        let (vfrOutcome, vfrSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mov)), inputs: [vfrMKV], mode: .replace)
        guard case .succeeded(_, let vfrWarnings) = vfrOutcome.outcomes.first else {
            Issue.record("expected VFR conversion success, got \(String(describing: vfrOutcome.outcomes))")
            return
        }
        #expect(vfrWarnings.contains(.videoVariableFrameRateConverted))
        #expect(vfrWarnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: vfrMKV) == vfrOriginal)
        try assertStagingEmpty(in: vfrSupport)

        // Explicit frame-rate change does not warn.
        let (fpsOutcome, fpsSupport) = try await runJob(
            op: .videoFPS, options: .video(.frameRate(24)), inputs: [vfrMKV], mode: .newFile)
        guard case .succeeded(_, let fpsWarnings) = fpsOutcome.outcomes.first else {
            Issue.record("expected explicit FPS conversion success, got \(String(describing: fpsOutcome.outcomes))")
            return
        }
        #expect(!fpsWarnings.contains(.videoVariableFrameRateConverted))
        try assertStagingEmpty(in: fpsSupport)

        // Constant-rate source does not warn.
        let cfrMKV = folder.appending(path: "cfr.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.75",
                "-c:v", "ffv1", cfrMKV.path,
            ], in: folder, tools: tools)
        let (cfrOutcome, cfrSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mov)), inputs: [cfrMKV], mode: .newFile)
        guard case .succeeded(_, let cfrWarnings) = cfrOutcome.outcomes.first else {
            Issue.record("expected CFR conversion success, got \(String(describing: cfrOutcome.outcomes))")
            return
        }
        #expect(!cfrWarnings.contains(.videoVariableFrameRateConverted))
        try assertStagingEmpty(in: cfrSupport)
    }

    @Test func explicitExportsReportOriginalOmittedStreamsWithoutWarningIntentionalSelection() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        let subtitle = folder.appending(path: "captions.srt")
        try Data("1\n00:00:00,000 --> 00:00:00,300\nHello\n".utf8).write(to: subtitle)
        let chapters = folder.appending(path: "chapters.txt")
        try Data(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=400\ntitle=Intro\n".utf8).write(to: chapters)

        let richMKV = folder.appending(path: "rich_export.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.5",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
                "-i", subtitle.path,
                "-i", chapters.path,
                "-map", "0:v", "-map", "1:a", "-map", "2:s", "-map_chapters", "3",
                "-c:v", "ffv1", "-c:a", "pcm_s16le", "-c:s", "srt", richMKV.path,
            ], in: folder, tools: tools)
        let originalBytes = try Data(contentsOf: richMKV)

        // Extract Audio reports subtitle and chapter.
        let (audioOutcome, audioSupport) = try await runJob(
            op: .videoExtractAudio, options: .video(.extractAudio(.m4aAAC, kilobits: 128)), inputs: [richMKV],
            mode: .replace)
        guard case .succeeded(_, let audioWarnings) = audioOutcome.outcomes.first else {
            Issue.record("expected extractAudio success, got \(String(describing: audioOutcome.outcomes))")
            return
        }
        #expect(audioWarnings.contains(.streamsOmitted([.subtitle, .chapter])))
        #expect(try Data(contentsOf: richMKV) == originalBytes)
        try assertStagingEmpty(in: audioSupport)

        // Save Frame reports subtitle and chapter.
        let (stillOutcome, stillSupport) = try await runJob(
            op: .videoThumbnail, options: .video(.still(.first)), inputs: [richMKV], mode: .newFile)
        guard case .succeeded(_, let stillWarnings) = stillOutcome.outcomes.first else {
            Issue.record("expected still export success, got \(String(describing: stillOutcome.outcomes))")
            return
        }
        #expect(stillWarnings.contains(.streamsOmitted([.subtitle, .chapter])))
        try assertStagingEmpty(in: stillSupport)

        // GIF export reports subtitle and chapter.
        let (gifOutcome, gifSupport) = try await runJob(
            op: .videoToGIF, options: .video(.gif(AnimationRendering(width: 128, framesPerSecond: 10))),
            inputs: [richMKV], mode: .newFile)
        guard case .succeeded(_, let gifWarnings) = gifOutcome.outcomes.first else {
            Issue.record("expected GIF export success, got \(String(describing: gifOutcome.outcomes))")
            return
        }
        #expect(gifWarnings.contains(.streamsOmitted([.subtitle, .chapter])))
        try assertStagingEmpty(in: gifSupport)
    }

    @Test func trackAttributeInspectionClassifiesExpectedErrorsAndPropagatesAccessAndCancellation() async throws {
        var attributes = StagedMediaFallback.OriginalTrackAttributes()
        try StagedMediaFallback.handleQuickTimeAttributeError(
            NSError(domain: AVFoundationErrorDomain, code: AVError.fileFormatNotRecognized.rawValue),
            attributes: &attributes)
        #expect(attributes.trackAttributesUnknown)

        var matroskaAttributes = StagedMediaFallback.OriginalTrackAttributes()
        try StagedMediaFallback.handleMatroskaAttributeError(
            FormatError.corrupt("non-standard track entry"), attributes: &matroskaAttributes)
        #expect(matroskaAttributes.trackAttributesUnknown)

        var propagatedAttributes = StagedMediaFallback.OriginalTrackAttributes()
        #expect(throws: CancellationError.self) {
            try StagedMediaFallback.handleQuickTimeAttributeError(
                CancellationError(), attributes: &propagatedAttributes)
        }
        #expect(throws: CocoaError.self) {
            try StagedMediaFallback.handleQuickTimeAttributeError(
                CocoaError(.fileReadNoPermission), attributes: &propagatedAttributes)
        }
        #expect(throws: POSIXError.self) {
            try StagedMediaFallback.handleQuickTimeAttributeError(
                POSIXError(.EACCES), attributes: &propagatedAttributes)
        }
        #expect(throws: FormatError.self) {
            try StagedMediaFallback.handleMatroskaAttributeError(
                FormatError.io("read failed"), attributes: &propagatedAttributes)
        }
        #expect(!propagatedAttributes.trackAttributesUnknown)

        // Unknown track attributes yield trackMetadata loss.
        let fixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        var input = try await MediaInput.open(fixture)
        input.fallbackOrigin = StagedMediaFallback.Probe(format: nil, streams: [], chapters: nil).sourceDescription(
            originalURL: fixture,
            trackAttributes: StagedMediaFallback.OriginalTrackAttributes(trackAttributesUnknown: true))
        let metadata = try await VideoMetadata.load(from: input)
        #expect(metadata.losses(for: .mp4, includingAudio: true).contains(.trackMetadata))
    }

    @Test func oversizedAttachedArtworkIsOmittedWithMetadataDroppedWarning() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        func attachCoverArt(image: URL, to baseWV: URL, output: URL) throws {
            let audioBytes = try Data(contentsOf: baseWV)
            let imageBytes = try Data(contentsOf: image)
            var value = Data("cover.png".utf8)
            value.append(0)
            value.append(imageBytes)
            var entry = Data()
            func appendUInt32LE(_ destination: inout Data, _ number: UInt32) {
                var little = number.littleEndian
                withUnsafeBytes(of: &little) { destination.append(contentsOf: $0) }
            }
            appendUInt32LE(&entry, UInt32(value.count))
            appendUInt32LE(&entry, 2)
            entry.append(contentsOf: "Cover Art (Front)".utf8)
            entry.append(0)
            entry.append(value)
            let tagSize = UInt32(entry.count + 32)
            var header = Data("APETAGEX".utf8)
            for field: UInt32 in [2_000, tagSize, 1, (1 << 31) | (1 << 29), 0, 0] { appendUInt32LE(&header, field) }
            var footer = Data("APETAGEX".utf8)
            for field: UInt32 in [2_000, tagSize, 1, 1 << 31, 0, 0] { appendUInt32LE(&footer, field) }
            try (audioBytes + header + entry + footer).write(to: output)
        }

        // Pixel limit: 5100x5100 exceeds 25,000,000 pixels.
        let hugePNG = folder.appending(path: "huge.png")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "color=c=blue:s=5100x5100:d=0.1",
                "-frames:v", "1", hugePNG.path,
            ], in: folder, tools: tools)
        let base16 = try await FallbackFixtures.makeWavPack(named: "base16.wv", in: folder)
        let pixelOversizedWV = folder.appending(path: "huge_art.wv")
        try attachCoverArt(image: hugePNG, to: base16, output: pixelOversizedWV)
        let (pixelOutcome, pixelSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [pixelOversizedWV], mode: .newFile)
        guard case .succeeded(let pixelOutputs, let pixelWarnings) = pixelOutcome.outcomes.first,
            let flac = pixelOutputs.first
        else {
            Issue.record(
                "expected pixel-oversized artwork conversion success, got \(String(describing: pixelOutcome.outcomes))")
            return
        }
        #expect(pixelWarnings.contains(.metadataDropped))
        #expect(try FLACMetadata.tags(in: flac).artwork == nil)
        try assertStagingEmpty(in: pixelSupport)

        // Byte limit drops oversized CAF artwork.
        let smallPNG = folder.appending(path: "cover.png")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=256x256:rate=1:duration=1",
                "-frames:v", "1", smallPNG.path,
            ], in: folder, tools: tools)
        let base32 = folder.appending(path: "base32.wv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:a", "wavpack", "-sample_fmt", "s32p", base32.path,
            ], in: folder, tools: tools)
        let byteOversizedWV = folder.appending(path: "byte_art.wv")
        try attachCoverArt(image: smallPNG, to: base32, output: byteOversizedWV)
        let byteSupport = try TestVolume.makeFolder()
        let byteContext = FallbackFixtures.context(in: byteSupport)
        defer { byteContext.removeStaging() }
        let staged = try await StagedMediaFallback.prepareAudio(
            byteOversizedWV, context: byteContext, tools: tools, maximumArtworkBytes: 256)
        #expect(staged.profile == .cafPCM32)
        #expect(staged.origin.attachedPicture == nil)
        #expect(staged.origin.attachedPictureDropped)
        #expect(staged.origin.hasUnsupportedAudioTags)
    }

    @Test func negativeStreamStartAndBothMatroskaDurationConventionsVerifyCleanly() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        // Negative audio start converts without misleading refusal.
        let negativeMKV = folder.appending(path: "negative_start.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=1.0",
                "-itsoffset", "-0.3", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.3",
                "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_s16le",
                "-avoid_negative_ts", "disabled", negativeMKV.path,
            ], in: folder, tools: tools)
        let negativeOriginal = try Data(contentsOf: negativeMKV)
        let (negConvert, negConvertSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [negativeMKV], mode: .replace)
        guard case .succeeded(let negOutputs, let negWarnings) = negConvert.outcomes.first, !negOutputs.isEmpty else {
            Issue.record("expected negative-start convert success, got \(String(describing: negConvert.outcomes))")
            return
        }
        #expect(negWarnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: negativeMKV) == negativeOriginal)
        try assertStagingEmpty(in: negConvertSupport)

        let (negExtract, negExtractSupport) = try await runJob(
            op: .videoExtractAudio, options: .video(.extractAudio(.m4aAAC, kilobits: 128)),
            inputs: [negativeMKV], mode: .newFile)
        guard case .succeeded(let negAudioOutputs, _) = negExtract.outcomes.first, !negAudioOutputs.isEmpty else {
            Issue.record("expected negative-start extractAudio success, got \(String(describing: negExtract.outcomes))")
            return
        }
        try assertStagingEmpty(in: negExtractSupport)

        // Patched elapsed-length Matroska DURATION tag converts cleanly.
        let endTaggedMKV = folder.appending(path: "end_tagged.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=1.0",
                "-itsoffset", "0.5", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
                "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_s16le", endTaggedMKV.path,
            ], in: folder, tools: tools)
        let endTaggedProbe = try await StagedMediaFallback.probe(endTaggedMKV, tools: tools)
        let originalAudioTag = try #require(
            endTaggedProbe.audioStreams.first?.tags?.first {
                $0.key.caseInsensitiveCompare("duration") == .orderedSame
            }?.value)
        let elapsedReplacement = "00:00:00.500000000"
        #expect(originalAudioTag.utf8.count == elapsedReplacement.utf8.count)
        let elapsedTaggedMKV = folder.appending(path: "elapsed_tagged.mkv")
        var mkvBytes = try Data(contentsOf: endTaggedMKV)
        let needle = Data(originalAudioTag.utf8)
        let patchRange = try #require(mkvBytes.range(of: needle, options: .backwards))
        mkvBytes.replaceSubrange(patchRange, with: Data(elapsedReplacement.utf8))
        try mkvBytes.write(to: elapsedTaggedMKV)

        for candidate in [endTaggedMKV, elapsedTaggedMKV] {
            let (outcome, support) = try await runJob(
                op: .videoConvert, options: .video(.convert(.mp4)), inputs: [candidate], mode: .newFile)
            guard case .succeeded(let outputs, _) = outcome.outcomes.first, !outputs.isEmpty else {
                Issue.record(
                    "expected \(candidate.lastPathComponent) conversion success, got \(String(describing: outcome.outcomes))"
                )
                continue
            }
            try assertStagingEmpty(in: support)
        }

        // Genuinely truncated intermediate still fails both conventions.
        func makeAudioProbe(start: String, duration: String?, tag: String?) -> StagedMediaFallback.Probe {
            StagedMediaFallback.Probe(
                format: StagedMediaFallback.Probe.Format(formatName: "matroska", duration: nil, size: nil, tags: nil),
                streams: [
                    StagedMediaFallback.Probe.Stream(
                        index: 0, codecType: "audio", codecName: "pcm_s16le", codecTagString: nil,
                        width: nil, height: nil, pixelFormat: nil, bitsPerRawSample: nil, bitsPerSample: 16,
                        colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, colorRange: nil,
                        channels: 2, channelLayout: "stereo", sampleFormat: "s16", sampleRate: "48000",
                        duration: duration, disposition: nil, tags: tag.map { ["DURATION": $0] }, startTime: start)
                ],
                chapters: nil)
        }

        let endConventionOriginal = makeAudioProbe(start: "0.5", duration: nil, tag: "00:00:03.000000000")
        let elapsedConventionOriginal = makeAudioProbe(start: "0.5", duration: nil, tag: "00:00:02.500000000")
        let negativeStartOriginal = makeAudioProbe(start: "-0.3", duration: nil, tag: "00:00:03.000000000")
        let matchingIntermediate = makeAudioProbe(start: "0.5", duration: "2.5", tag: nil)
        let negativeMatchingIntermediate = makeAudioProbe(start: "-0.3", duration: "3.3", tag: nil)
        let truncatedIntermediate = makeAudioProbe(start: "0.5", duration: "1.5", tag: nil)

        try StagedMediaFallback.verifyIntermediate(
            original: endConventionOriginal, intermediate: matchingIntermediate, kind: .audio)
        try StagedMediaFallback.verifyIntermediate(
            original: elapsedConventionOriginal, intermediate: matchingIntermediate, kind: .audio)
        try StagedMediaFallback.verifyIntermediate(
            original: negativeStartOriginal, intermediate: negativeMatchingIntermediate, kind: .audio)
        for original in [endConventionOriginal, elapsedConventionOriginal, negativeStartOriginal] {
            var sawUnfaithful = false
            do {
                try StagedMediaFallback.verifyIntermediate(
                    original: original, intermediate: truncatedIntermediate, kind: .audio)
            } catch EngineError.fallbackConversionUnfaithful {
                sawUnfaithful = true
            }
            #expect(sawUnfaithful)
        }
    }

    @Test func filenameContainingErrnoTextIsNotMisclassifiedAndLegacyRunMessagesMatchMain() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        // Classification ignores errno strings inside file paths.
        #expect(
            MediaToolProcess.classifyExitFailure(
                diagnostics: "file:/tmp/No space left on device.wma: Invalid data found when processing input",
                status: 1) == .exited(status: 1, reason: "Media tool failed (exit 1)"))
        #expect(
            MediaToolProcess.classifyExitFailure(
                diagnostics: "file:/tmp/Permission denied.wma: Invalid data found when processing input",
                status: 1) == .exited(status: 1, reason: "Media tool failed (exit 1)"))
        #expect(
            MediaToolProcess.classifyExitFailure(
                diagnostics: "file:/tmp/out.mov: No space left on device", status: 1)
                == .diskFull("There is not enough disk space for this operation"))
        #expect(
            MediaToolProcess.classifyExitFailure(
                diagnostics: "file:/tmp/in.wma: Permission denied", status: 1)
                == .permissionDenied("The destination or media tool is not accessible"))
        #expect(
            MediaToolProcess.classifyExitFailure(
                diagnostics: "ERROR: [Errno 28] No space left on device: '/tmp/out.mp4'", status: 1)
                == .diskFull("There is not enough disk space for this operation"))
        #expect(
            MediaToolProcess.classifyExitFailure(
                diagnostics: "ERROR: [Errno 13] Permission denied: '/tmp/in.mp4'", status: 1)
                == .permissionDenied("The destination or media tool is not accessible"))

        // Garbage files named after errno stay decodeFailed.
        for badName in ["No space left on device.wma", "Permission denied.wma"] {
            let garbage = folder.appending(path: badName)
            try Data(repeating: 0x5A, count: 4_096).write(to: garbage)
            let support = try TestVolume.makeFolder()
            let context = FallbackFixtures.context(in: support)
            defer { context.removeStaging() }
            var sawDecodeFailed = false
            do {
                _ = try await AudioInput.openWithFallback(garbage, context: context, tools: tools)
                Issue.record("expected garbage \(badName) to fail")
            } catch EngineError.decodeFailed {
                sawDecodeFailed = true
            }
            #expect(sawDecodeFailed)
        }

        // Legacy MediaToolProcess.run keeps exact main decodeFailed messages.
        let legacyCases: [(name: String, script: String, expected: String)] = [
            (
                "legacy-enospc.sh",
                "#!/bin/sh\necho '/tmp/out.mp4: No space left on device' >&2\nexit 1\n",
                "There is not enough disk space for this operation"
            ),
            (
                "legacy-eacces.sh",
                "#!/bin/sh\necho '/tmp/in.mp4: Permission denied' >&2\nexit 1\n",
                "The destination or media tool is not accessible"
            ),
            (
                "legacy-sigkill.sh",
                "#!/bin/sh\nkill -9 $$\n",
                "Media tool failed (exit 9)"
            ),
        ]
        for legacyCase in legacyCases {
            let stub = folder.appending(path: legacyCase.name)
            try Data(legacyCase.script.utf8).write(to: stub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
            var thrownMessage: String?
            do {
                _ = try await MediaToolProcess().run(
                    executable: stub, arguments: [], directory: folder, tools: tools,
                    captureOutput: false, includeTLSCertificate: false)
                Issue.record("expected \(legacyCase.name) to fail")
            } catch EngineError.decodeFailed(let message) {
                thrownMessage = message
            }
            #expect(thrownMessage == legacyCase.expected)
        }
    }

    @Test func oversizedAPEv2TagEmitsMetadataDroppedWarningOnWavPack() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let baseWV = try await FallbackFixtures.makeWavPack(named: "ape_base.wv", in: folder)
        let baseBytes = try Data(contentsOf: baseWV)

        func buildAPEv2File(entries: [(key: String, flags: UInt32, value: Data)], output: URL) throws {
            func appendUInt32LE(_ destination: inout Data, _ number: UInt32) {
                var little = number.littleEndian
                withUnsafeBytes(of: &little) { destination.append(contentsOf: $0) }
            }
            var body = Data()
            for entry in entries {
                appendUInt32LE(&body, UInt32(entry.value.count))
                appendUInt32LE(&body, entry.flags)
                body.append(contentsOf: entry.key.utf8)
                body.append(0)
                body.append(entry.value)
            }
            let tagSize = UInt32(body.count + 32)
            let count = UInt32(entries.count)
            var header = Data("APETAGEX".utf8)
            for field: UInt32 in [2_000, tagSize, count, (1 << 31) | (1 << 29), 0, 0] { appendUInt32LE(&header, field) }
            var footer = Data("APETAGEX".utf8)
            for field: UInt32 in [2_000, tagSize, count, 1 << 31, 0, 0] { appendUInt32LE(&footer, field) }
            try (baseBytes + header + body + footer).write(to: output)
        }

        // Oversized APEv2 tag warns metadataDropped.
        let oversizedWV = folder.appending(path: "big_ape.wv")
        var coverPayload = Data("cover.png".utf8)
        coverPayload.append(0)
        coverPayload.append(Data(repeating: 0x42, count: 17 * 1_024 * 1_024))
        try buildAPEv2File(
            entries: [
                ("Title", 0, Data("Big Tag Title".utf8)),
                ("Artist", 0, Data("Big Tag Artist".utf8)),
                ("Cover Art (Front)", 2, coverPayload),
            ],
            output: oversizedWV)
        let oversizedOriginal = try Data(contentsOf: oversizedWV)
        let oversizedProbe = try await StagedMediaFallback.probe(oversizedWV, tools: tools)
        #expect(try StagedMediaFallback.hasUnreadableAPETag(in: oversizedWV, probe: oversizedProbe))

        let (bigOutcome, bigSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [oversizedWV], mode: .replace)
        guard case .succeeded(let bigOutputs, let bigWarnings) = bigOutcome.outcomes.first, !bigOutputs.isEmpty else {
            Issue.record("expected oversized APEv2 conversion success, got \(String(describing: bigOutcome.outcomes))")
            return
        }
        #expect(bigWarnings.contains(.metadataDropped))
        #expect(bigWarnings.contains(.keptAsNewFileForFormat))
        #expect(try Data(contentsOf: oversizedWV) == oversizedOriginal)
        try assertStagingEmpty(in: bigSupport)

        // Normal APEv2 tag avoids false-positive metadataDropped.
        let smallWV = folder.appending(path: "small_ape.wv")
        try buildAPEv2File(
            entries: [
                ("Title", 0, Data("Small Title".utf8)),
                ("Artist", 0, Data("Small Artist".utf8)),
            ],
            output: smallWV)
        let smallProbe = try await StagedMediaFallback.probe(smallWV, tools: tools)
        #expect(try !StagedMediaFallback.hasUnreadableAPETag(in: smallWV, probe: smallProbe))
        let (smallOutcome, smallSupport) = try await runJob(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [smallWV], mode: .newFile)
        guard case .succeeded(let smallOutputs, let smallWarnings) = smallOutcome.outcomes.first,
            let smallFlac = smallOutputs.first
        else {
            Issue.record("expected small APEv2 conversion success, got \(String(describing: smallOutcome.outcomes))")
            return
        }
        #expect(!smallWarnings.contains(.metadataDropped))
        let tags = try FLACMetadata.tags(in: smallFlac)
        #expect(tags.title == "Small Title")
        #expect(tags.artist == "Small Artist")
        try assertStagingEmpty(in: smallSupport)
    }

    @Test func corruptAttachedCoverIsDroppedWithMetadataWarningOnBothALACAndCAFRoutes() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        let corruptGIF = folder.appending(path: "corrupt.gif")
        try (Data("GIF89a".utf8) + Data(repeating: 0xFF, count: 256)).write(to: corruptGIF)

        let routeCases: [(name: String, codecArgs: [String], expectedProfile: StagedMediaFallback.AudioProfile)] = [
            ("corrupt_caf.mka", ["-c:a", "pcm_f32le"], .cafPCMFloat32),
            ("corrupt_alac.mka", ["-c:a", "wavpack", "-sample_fmt", "s16p"], .alacM4A),
        ]

        for routeCase in routeCases {
            let source = folder.appending(path: routeCase.name)
            try await FallbackFixtures.runFFmpeg(
                [
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                    "-metadata", "title=Kept Title",
                    "-attach", corruptGIF.path, "-metadata:s:t", "mimetype=image/gif",
                ] + routeCase.codecArgs + [source.path],
                in: folder, tools: tools)
            let originalBytes = try Data(contentsOf: source)
            let probed = try await StagedMediaFallback.probe(source, tools: tools)
            let audioStream = try #require(probed.audioStreams.first)
            #expect(StagedMediaFallback.selectAudioOnlyProfile(for: audioStream) == routeCase.expectedProfile)

            let (outcome, support) = try await runJob(
                op: .audioConvert, options: .audio(.convert(.flac)), inputs: [source], mode: .replace)
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first, let flac = outputs.first else {
                Issue.record(
                    "expected \(routeCase.name) conversion success, got \(String(describing: outcome.outcomes))")
                continue
            }
            #expect(warnings.contains(.metadataDropped))
            #expect(warnings.contains(.keptAsNewFileForFormat))
            let tags = try FLACMetadata.tags(in: flac)
            #expect(tags.title == "Kept Title")
            #expect(tags.artwork == nil)
            #expect(try Data(contentsOf: source) == originalBytes)
            try assertStagingEmpty(in: support)
        }
    }

    @Test func fallbackExportsAcceptSecondAudioTrackWhileTransformsStillRefuse() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()

        let dualAudioMKV = folder.appending(path: "dual_audio.mkv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.5",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=0.5",
                "-map", "0:v", "-map", "1:a", "-map", "2:a",
                "-c:v", "ffv1", "-c:a", "pcm_s16le", dualAudioMKV.path,
            ], in: folder, tools: tools)
        let originalBytes = try Data(contentsOf: dualAudioMKV)

        // Transform still refuses multiple tracks.
        let (convertOutcome, convertSupport) = try await runJob(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [dualAudioMKV], mode: .newFile)
        #expect(convertOutcome.outcomes == [.failed(.invalidInput(.multipleTracks))])
        #expect(try Data(contentsOf: dualAudioMKV) == originalBytes)
        try assertStagingEmpty(in: convertSupport)

        // Extract Audio reports omitted audio track.
        let (extractOutcome, extractSupport) = try await runJob(
            op: .videoExtractAudio, options: .video(.extractAudio(.m4aAAC, kilobits: 128)),
            inputs: [dualAudioMKV], mode: .replace)
        guard case .succeeded(let audioOutputs, let audioWarnings) = extractOutcome.outcomes.first,
            !audioOutputs.isEmpty
        else {
            Issue.record("expected dual-audio extractAudio success, got \(String(describing: extractOutcome.outcomes))")
            return
        }
        #expect(audioWarnings.contains(.streamsOmitted([.audio])))
        #expect(try Data(contentsOf: dualAudioMKV) == originalBytes)
        try assertStagingEmpty(in: extractSupport)

        // Save Frame reports omitted audio track.
        let (stillOutcome, stillSupport) = try await runJob(
            op: .videoThumbnail, options: .video(.still(.first)), inputs: [dualAudioMKV], mode: .newFile)
        guard case .succeeded(let stillOutputs, let stillWarnings) = stillOutcome.outcomes.first,
            !stillOutputs.isEmpty
        else {
            Issue.record("expected dual-audio still export success, got \(String(describing: stillOutcome.outcomes))")
            return
        }
        #expect(stillWarnings.contains(.streamsOmitted([.audio])))
        #expect(try Data(contentsOf: dualAudioMKV) == originalBytes)
        try assertStagingEmpty(in: stillSupport)
    }
}
