import AVFoundation
import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing

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
            var data = Data()
            appendUInt32BE(&data, UInt32(8 + payload.count))
            data.append(contentsOf: type.utf8)
            data.append(payload)
            return data
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
        let mkvDTS = try await FallbackFixtures.makeMKVDTS(in: folder)
        let wma = try await FallbackFixtures.makeWMA(in: folder)
        let wavpack = try await FallbackFixtures.makeWavPack(in: folder)
        let oggFlac = try await FallbackFixtures.makeOggFLAC(in: folder)

        for video in [wmv, mpg, mkvDTS] {
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
            #expect(staged.sourceIsLossy == expectedLossy)
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
            width: 1920, height: 1080, pixelFormat: "yuv422p10le", bitsPerRawSample: "10",
            colorPrimaries: nil, colorTransfer: nil, colorSpace: nil, colorRange: nil,
            channels: nil, sampleFormat: nil, sampleRate: nil, duration: "1.0", disposition: nil, tags: nil)
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

        let dts51 = folder.appending(path: "surround51.dts")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4,aformat=channel_layouts=5.1",
                "-c:a", "dca", "-strict", "-2", dts51.path,
            ], in: folder, tools: tools)
        let context51 = FallbackFixtures.context(in: support)
        defer { context51.removeStaging() }
        let staged51 = try await StagedMediaFallback.prepareAudio(dts51, context: context51)
        #expect(staged51.profile == .alacM4A)
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

        let unconsented = FallbackFixtures.context(in: support)
        defer { unconsented.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.subtitle]))) {
            _ = try await StagedMediaFallback.prepareVideo(subtitled, context: unconsented)
        }
        let stagingDirs = try FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
        #expect(!stagingDirs.contains { $0.lastPathComponent.hasSuffix(".mov") })

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
        let longClip = folder.appending(path: "long.wmv")
        try await FallbackFixtures.runFFmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=12",
                "-c:v", "wmv2", longClip.path,
            ], in: folder, tools: tools)

        let started = Mutex(false)
        let context = FallbackFixtures.context(
            in: support,
            phase: { phase in
                if phase == .convertingInput { started.withLock { $0 = true } }
            })
        let task = Task {
            try await StagedMediaFallback.prepareVideo(longClip, context: context)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected cancellation.
        } catch EngineError.cancelled {
            // Expected cancellation.
        }
        context.removeStaging()
        let registryURL = support.appending(path: "staging.json")
        if FileManager.default.fileExists(atPath: registryURL.path) {
            let remaining = try JSONDecoder().decode([String].self, from: Data(contentsOf: registryURL))
            #expect(remaining.isEmpty)
        }
    }
}
