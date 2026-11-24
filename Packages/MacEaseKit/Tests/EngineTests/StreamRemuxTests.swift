import AVFoundation
import CoreMedia
import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct StreamRemuxTests {
    private func tools() throws -> MediaDownloadTools {
        try MediaDownloadTools.resolved()
    }

    private func fixture(_ name: String, inFormats: Bool = false) throws -> URL {
        let source: URL
        if inFormats {
            source = URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "../FormatsTests/Resources/\(name)")
        } else {
            source = try #require(
                Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        }
        let copy = try TestVolume.makeFolder().appending(path: name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func runEngine(
        _ op: OperationID, options: OperationOptions, on url: URL,
        omittedStreams: Set<UnpreservedStream> = [], outputMode: Settings.OutputMode = .replace,
        support: URL? = nil
    ) async throws -> (outcome: ItemOutcome, engine: JobEngine, batchOutcome: BatchOutcome) {
        let supportDir =
            support
            ?? FileManager.default.temporaryDirectory.appending(path: "MacEaseRemuxTest-\(UUID().uuidString)")
        TestTemporaryFolders.register(supportDir)
        let engine = try JobEngine(supportDirectory: supportDir, concurrency: 1)
        var settings = Settings()
        settings.outputMode = outputMode
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: op, options: options, inputs: [url], omittedStreams: omittedStreams),
            settings: settings)
        let batchOutcome = await engine.run(batch, settings: settings) { _ in }
        return (try #require(batchOutcome.outcomes.first), engine, batchOutcome)
    }

    private func runPreset(
        _ op: OperationID, preset: String?, on url: URL, omittedStreams: Set<UnpreservedStream> = [],
        outputMode: Settings.OutputMode = .replace, support: URL? = nil
    ) async throws -> (outcome: ItemOutcome, engine: JobEngine, batchOutcome: BatchOutcome) {
        let options = try #require(OperationPlanner.options(for: op, preset: preset, settings: Settings()))
        return try await runEngine(
            op, options: options, on: url, omittedStreams: omittedStreams, outputMode: outputMode, support: support)
    }

    private func runFFmpeg(_ arguments: [String], directory: URL) async throws {
        let resolved = try tools()
        _ = try await MediaToolProcess().run(
            executable: resolved.ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error", "-y"] + arguments,
            directory: directory, tools: resolved, captureOutput: false)
    }

    private func makeTimecodedMOV(
        name: String = "timecoded.mov", timecode: String = "01:02:03:04"
    ) async throws -> URL {
        let source = try fixture("ffmpeg-h264-aac.mp4")
        let folder = source.deletingLastPathComponent()
        let output = folder.appending(path: name)
        try await runFFmpeg(
            ["-i", source.path, "-c", "copy", "-timecode", timecode, output.path], directory: folder)
        try FileManager.default.removeItem(at: source)
        return output
    }

    @Test(arguments: [Settings.OutputMode.replace, .newFile])
    func movTimecodeCarriesAndMP4RequestsConsent(mode: Settings.OutputMode) async throws {
        let resolved = try tools()
        let compressClip = try await makeTimecodedMOV(name: "clip-compress.mov", timecode: "01:02:03:04")
        let compressOriginal = try Data(contentsOf: compressClip)
        let (compressOutcome, compressEngine, compressBatch) = try await runPreset(
            .videoCompress, preset: "quality-medium", on: compressClip, outputMode: mode)
        guard case .succeeded(let compressOutputs, let compressWarnings) = compressOutcome else {
            Issue.record("expected compress without consent, got \(compressOutcome)")
            return
        }
        #expect(compressWarnings.isEmpty)
        let compressed = try #require(compressOutputs.first)
        #expect(compressed.pathExtension == "mov")
        let compressedProbe = try await StreamRemuxer.probe(compressed, tools: resolved, countPackets: false)
        let compressedTC = compressedProbe.streams.filter(\.isTimecode)
        #expect(compressedTC.count == 1)
        #expect(compressedTC.first?.timecodeTag == "01:02:03:04")
        #expect(try await AVURLAsset(url: compressed).loadTracks(withMediaType: .timecode).count == 1)
        if mode == .newFile {
            #expect(try Data(contentsOf: compressClip) == compressOriginal)
        } else if let record = compressBatch.record {
            let undone = try await compressEngine.undo(record.id)
            #expect(undone == [.restored])
            #expect(try Data(contentsOf: compressClip) == compressOriginal)
        }

        let convertClip = try await makeTimecodedMOV(name: "clip-convert.mov", timecode: "02:03:04:05")
        let convertOriginal = try Data(contentsOf: convertClip)
        let (convertOutcome, _, _) = try await runPreset(
            .videoConvert, preset: "mp4", on: convertClip, outputMode: mode)
        #expect(convertOutcome == .failed(.invalidInput(.unpreservedStreams([.timecode]))))
        #expect(try Data(contentsOf: convertClip) == convertOriginal)
        let (consented, _, _) = try await runPreset(
            .videoConvert, preset: "mp4", on: convertClip, omittedStreams: [.timecode], outputMode: mode)
        guard case .succeeded(let outputs, let warnings) = consented, let output = outputs.first else {
            Issue.record("expected explicit MP4 omission: \(consented)")
            return
        }
        #expect(warnings == [.streamsOmitted([.timecode])])
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .timecode).isEmpty)
    }

    @Test func quickTimeMetadataAndTrackPropertiesSurviveNativeCarry() async throws {
        let source = try fixture("ffmpeg-h264-aac.mp4")
        let folder = source.deletingLastPathComponent()
        let rich = folder.appending(path: "rich.mov")
        let asset = AVURLAsset(url: source)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let duration = try await asset.load(.duration)

        let writer = try AVAssetWriter(outputURL: rich, fileType: .mov)
        let title = AVMutableMetadataItem()
        title.identifier = .quickTimeMetadataTitle
        title.value = "Remuxed Title" as NSString
        let custom = AVMutableMetadataItem()
        custom.keySpace = .quickTimeMetadata
        custom.key = "com.apple.quicktime.full-frame-rate-playback-intent" as NSString
        custom.value = 1 as NSNumber
        let artwork = AVMutableMetadataItem()
        artwork.identifier = .iTunesMetadataCoverArt
        artwork.value = AudioSignals.pngArtwork().data as NSData
        writer.metadata = [title, custom, artwork]

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(videoOut)
        reader.add(audioOut)
        let videoIn = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
        let audioIn = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil,
            sourceFormatHint: try await audioTrack.load(.formatDescriptions).first)
        audioIn.languageCode = "jpn"
        audioIn.extendedLanguageTag = "ja-JP"
        audioIn.preferredVolume = 0.5
        audioIn.marksOutputTrackAsEnabled = false
        let trackName = AVMutableMetadataItem()
        trackName.identifier = .commonIdentifierTitle
        trackName.value = "Japanese Audio" as NSString
        audioIn.metadata = [trackName]
        writer.add(videoIn)
        writer.add(audioIn)

        var tcFormat: CMTimeCodeFormatDescription?
        try #require(
            CMTimeCodeFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: CMTime(value: 1, timescale: 24), frameQuanta: 24, flags: 0, extensions: nil,
                formatDescriptionOut: &tcFormat) == noErr)
        let timecodeFormat = try #require(tcFormat)
        let timecodeIn = AVAssetWriterInput(
            mediaType: .timecode, outputSettings: nil, sourceFormatHint: timecodeFormat)
        writer.add(timecodeIn)

        try #require(reader.startReading())
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var frameNumber = Int32(89_356).bigEndian
        var blockBuffer: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: MemoryLayout<Int32>.size,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: MemoryLayout<Int32>.size, flags: 0, blockBufferOut: &blockBuffer) == noErr)
        let block = try #require(blockBuffer)
        try #require(
            CMBlockBufferReplaceDataBytes(
                with: &frameNumber, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: MemoryLayout<Int32>.size) == noErr)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = MemoryLayout<Int32>.size
        var tcSample: CMSampleBuffer?
        try #require(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: timecodeFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &tcSample) == noErr)
        while !timecodeIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        try #require(timecodeIn.append(try #require(tcSample)))
        timecodeIn.markAsFinished()

        var videoDone = false
        var audioDone = false
        while !videoDone || !audioDone {
            if !videoDone, videoIn.isReadyForMoreMediaData {
                if let sample = videoOut.copyNextSampleBuffer() {
                    try #require(videoIn.append(sample))
                } else {
                    videoIn.markAsFinished()
                    videoDone = true
                }
            }
            if !audioDone, audioIn.isReadyForMoreMediaData {
                if let sample = audioOut.copyNextSampleBuffer() {
                    try #require(audioIn.append(sample))
                } else {
                    audioIn.markAsFinished()
                    audioDone = true
                }
            }
        }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        try FileManager.default.removeItem(at: source)

        let (outcome, _, _) = try await runPreset(.videoRotate, preset: "right-90", on: rich, outputMode: .replace)
        guard case .succeeded(let outputs, let warnings) = outcome else {
            Issue.record("expected rich MOV rotate without consent or metadata loss, got \(outcome)")
            return
        }
        #expect(warnings.isEmpty)
        let rotated = try #require(outputs.first)
        let outAsset = AVURLAsset(url: rotated)
        let outMeta = try await outAsset.load(.metadata)
        #expect(outMeta.contains { $0.identifier == .quickTimeMetadataTitle })
        #expect(outMeta.contains { $0.identifier == .iTunesMetadataCoverArt })
        #expect(
            outMeta.contains {
                $0.identifier?.rawValue == "mdta/com.apple.quicktime.full-frame-rate-playback-intent"
            })
        let outAudio = try #require(try await outAsset.loadTracks(withMediaType: .audio).first)
        #expect(try await outAudio.load(.languageCode) == "jpn")
        #expect(try await outAudio.load(.extendedLanguageTag) == "ja-JP")
        #expect(try await outAudio.load(.preferredVolume) == 0.5)
        #expect(try await outAudio.load(.isEnabled) == false)
        #expect(try await !outAudio.load(.metadata).isEmpty)
        let probed = try await StreamRemuxer.probe(rotated, tools: try tools(), countPackets: false)
        #expect(probed.streams.filter(\.isTimecode).first?.timecodeTag == "01:02:03:04")
    }

    @Test func nativeSubtitleCopyKeepsRepresentationAndConversionsAsk() async throws {
        for preset in ["mp4", "mov", "webm", "avi"] {
            let source = try fixture("ffmpeg-mpeg4-ac3-srt.mkv", inFormats: true)
            let (outcome, _, _) = try await runPreset(.videoConvert, preset: preset, on: source, outputMode: .newFile)
            #expect(outcome == .failed(.invalidInput(.unpreservedStreams([.subtitle]))))
        }
        let source = try fixture("ffmpeg-mpeg4-ac3-srt.mkv", inFormats: true)
        let (outcome, _, _) = try await runPreset(.videoRemoveAudio, preset: nil, on: source, outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = outcome, let output = outputs.first else {
            Issue.record("expected native SRT carry: \(outcome)")
            return
        }
        #expect(warnings.isEmpty)
        let probed = try await StreamRemuxer.probe(output, tools: tools(), countPackets: true)
        #expect(probed.streams.filter { $0.codecType == "subtitle" }.first?.codecName == "subrip")
        #expect((probed.streams.filter { $0.codecType == "subtitle" }.first?.parsedReadPackets ?? 0) > 0)
    }

    @Test func styledASSConversionAsksForSubtitleConsent() async throws {
        let source = try fixture("ffmpeg-h264-aac.mp4")
        let folder = source.deletingLastPathComponent()
        let subtitle = folder.appending(path: "styled.ass")
        try """
        [Script Info]
        ScriptType: v4.00+
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,7,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\pos(100,80)\\frz45}Positioned
        """.write(to: subtitle, atomically: true, encoding: .utf8)
        let mkv = folder.appending(path: "styled.mkv")
        try await runFFmpeg(
            [
                "-i", source.path, "-i", subtitle.path, "-map", "0", "-map", "1", "-map_metadata", "-1", "-c", "copy",
                mkv.path,
            ],
            directory: folder)
        let (outcome, _, _) = try await runPreset(.videoConvert, preset: "mp4", on: mkv, outputMode: .newFile)
        #expect(outcome == .failed(.invalidInput(.unpreservedStreams([.subtitle]))))
        let (copied, _, _) = try await runPreset(.videoRemoveAudio, preset: nil, on: mkv, outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = copied, let output = outputs.first else {
            Issue.record("expected ASS representation copy: \(copied)")
            return
        }
        #expect(warnings.isEmpty)
        let restored = folder.appending(path: "restored.ass")
        try await runFFmpeg(["-i", output.path, "-map", "0:s", "-c", "copy", restored.path], directory: folder)
        let text = try String(contentsOf: restored, encoding: .utf8)
        #expect(text.contains("\\pos(100,80)\\frz45"))
        #expect(text.contains(",7,10,10,10,1"))
    }

    @Test func webVTTCopyPreservesCueIdentifierAndPositioningSideData() async throws {
        let source = try fixture("ffmpeg-h264-aac.mp4")
        let folder = source.deletingLastPathComponent()
        let subtitle = folder.appending(path: "positioned.vtt")
        try "WEBVTT\n\ncue-one\n00:00:00.000 --> 00:00:01.000 position:20% align:start\nPositioned caption\n"
            .write(to: subtitle, atomically: true, encoding: .utf8)
        let mkv = folder.appending(path: "positioned.mkv")
        try await runFFmpeg(
            [
                "-i", source.path, "-i", subtitle.path, "-map", "0", "-map", "1",
                "-map_metadata", "-1", "-c", "copy", mkv.path,
            ], directory: folder)
        let (outcome, _, _) = try await runPreset(.videoRemoveAudio, preset: nil, on: mkv, outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = outcome, let output = outputs.first else {
            Issue.record("expected WebVTT representation copy: \(outcome)")
            return
        }
        #expect(warnings.isEmpty)
        let restored = folder.appending(path: "restored.vtt")
        try await runFFmpeg(["-i", output.path, "-map", "0:s", "-c", "copy", restored.path], directory: folder)
        let text = try String(contentsOf: restored, encoding: .utf8)
        #expect(text.contains("cue-one"))
        #expect(text.contains("position:20% align:start"))
    }

    @Test func chaptersAndAttachmentsCarryWhereSupportedAndAskOnlyForUncarriableKinds() async throws {
        let resolved = try tools()
        let base = try fixture("ffmpeg-h264-aac.mp4")
        let folder = base.deletingLastPathComponent()
        let chaptersFile = folder.appending(path: "chapters.txt")
        let chapterMetadata = """
            ;FFMETADATA1
            [CHAPTER]
            TIMEBASE=1/1000
            START=0
            END=1000
            title=Intro
            [CHAPTER]
            TIMEBASE=1/1000
            START=1000
            END=2000
            title=Part 2
            """
        try chapterMetadata.write(to: chaptersFile, atomically: true, encoding: .utf8)
        let attachmentFile = folder.appending(path: "notes.txt")
        try "font-or-attachment".write(to: attachmentFile, atomically: true, encoding: .utf8)

        let richMKV = folder.appending(path: "rich.mkv")
        try await runFFmpeg(
            [
                "-i", base.path, "-i", chaptersFile.path,
                "-map", "0:v", "-map", "0:a", "-map_metadata:g", "-1", "-map_chapters", "1", "-c", "copy",
                "-attach", attachmentFile.path, "-metadata:s:t", "mimetype=text/plain",
                richMKV.path,
            ], directory: folder)

        for preset in ["mp4", "avi"] {
            let (outcome, _, _) = try await runPreset(.videoConvert, preset: preset, on: richMKV, outputMode: .newFile)
            #expect(outcome == .failed(.invalidInput(.unpreservedStreams([.chapter, .attachment]))))
        }
        let (outcome, _, _) = try await runPreset(
            .videoRemoveAudio, preset: nil, on: richMKV, omittedStreams: [.chapter, .attachment], outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = outcome, let output = outputs.first else {
            Issue.record("expected explicit omission: \(outcome)")
            return
        }
        #expect(warnings == [.streamsOmitted([.chapter, .attachment])])
        let probed = try await StreamRemuxer.probe(output, tools: resolved, countPackets: false)
        #expect(probed.chapters?.isEmpty != false)
        #expect(!probed.streams.contains { $0.codecType == "attachment" })
    }

    @Test func audioChaptersCarryIntoSupportedContainersAndAskForWAVAndTrim() async throws {
        let folder = try TestVolume.makeFolder()
        let baseM4A = folder.appending(path: "base.m4a")
        try await AudioSignals.write(AudioSignals.music(seconds: 1.0), to: baseM4A, format: .m4aAAC)
        let chaptersFile = folder.appending(path: "chapters.txt")
        let chapterMetadata = """
            ;FFMETADATA1
            [CHAPTER]
            TIMEBASE=1/1000
            START=0
            END=500
            title=First
            [CHAPTER]
            TIMEBASE=1/1000
            START=500
            END=1000
            title=Second
            """
        try chapterMetadata.write(to: chaptersFile, atomically: true, encoding: .utf8)
        let chapteredM4A = folder.appending(path: "chaptered.m4a")
        try await runFFmpeg(
            [
                "-i", baseM4A.path, "-i", chaptersFile.path, "-map", "0:a", "-map_metadata:g", "-1",
                "-map_chapters", "1", "-c", "copy", chapteredM4A.path,
            ], directory: folder)

        let (mp3Outcome, _, _) = try await runEngine(
            .audioConvert, options: .audio(.convert(.mp3)), on: chapteredM4A, outputMode: .newFile)
        #expect(mp3Outcome == .failed(.invalidInput(.unpreservedStreams([.chapter]))))

        let (wavOutcome, _, _) = try await runEngine(
            .audioConvert, options: .audio(.convert(.wav)), on: chapteredM4A, outputMode: .newFile)
        #expect(wavOutcome == .failed(.invalidInput(.unpreservedStreams([.chapter]))))

        let (trimOutcome, _, _) = try await runEngine(
            .audioTrim, options: .audio(.trim(start: 0.1, end: 0.8, fadeIn: 0, fadeOut: 0)),
            on: chapteredM4A, outputMode: .newFile)
        #expect(trimOutcome == .failed(.invalidInput(.unpreservedStreams([.chapter]))))
    }

    @Test func timingChangingVideoOperationsStillRequireConsent() async throws {
        let clip = try await makeTimecodedMOV(name: "timing.mov", timecode: "01:02:03:04")
        let trimExact = OperationOptions.video(.trim(start: 0.2, end: 1.5, mode: .exact))
        let trimKey = OperationOptions.video(.trim(start: 0.2, end: 1.5, mode: .keyframe))
        let speed = OperationOptions.video(.speed(2))
        let fps = OperationOptions.video(.frameRate(30))
        for (op, options) in [
            (OperationID.videoEdit, trimExact), (.videoEdit, trimKey), (.videoSpeed, speed), (.videoFPS, fps),
        ] {
            let (outcome, _, _) = try await runEngine(op, options: options, on: clip, outputMode: .newFile)
            #expect(outcome == .failed(.invalidInput(.unpreservedStreams([.timecode]))))
        }
    }

    @Test func nativeCarryVerificationLeavesEncodedStreamsUntouched() async throws {
        let resolved = try tools()
        let timecoded = try await makeTimecodedMOV(name: "source-tc.mov", timecode: "03:04:05:06")
        let input = try await MediaInput.open(timecoded)
        var plan = TranscodePlan(container: .mov, video: .copy, audio: .copy)
        plan.carriesTimecode = true
        let support = try TestVolume.makeFolder().appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(settings: Settings(), staging: StagingArea(supportDirectory: support)) { _ in }
        defer { context.removeStaging() }
        let staged = try context.stagingURL(for: timecoded, name: "staged.mov")
        try await Transcoder.run(input, plan: plan, to: staged) { _ in }

        let beforeHash = try await streamHash(of: staged, tools: resolved)
        let beforeProbe = try await StreamRemuxer.probe(staged, tools: resolved, countPackets: true)
        let beforeVideoPackets = beforeProbe.streams.first { $0.codecType == "video" }?.parsedReadPackets
        let beforeAudioPackets = beforeProbe.streams.first { $0.codecType == "audio" }?.parsedReadPackets

        let carryPlan = try await StreamRemuxer.plan(for: input, destination: .mov, preservesTiming: true)
        #expect(carryPlan.carriedKinds == [.timecode])
        try await StreamRemuxer.apply(
            carryPlan, to: staged, original: timecoded, hasVideo: true, hasAudio: true, context: context)

        let afterHash = try await streamHash(of: staged, tools: resolved)
        let afterProbe = try await StreamRemuxer.probe(staged, tools: resolved, countPackets: true)
        #expect(afterHash == beforeHash)
        #expect(afterProbe.streams.first { $0.codecType == "video" }?.parsedReadPackets == beforeVideoPackets)
        #expect(afterProbe.streams.first { $0.codecType == "audio" }?.parsedReadPackets == beforeAudioPackets)
        #expect(afterProbe.streams.filter(\.isTimecode).first?.timecodeTag == "03:04:05:06")
    }

    @Test func leadingDashAndColonFilenamesRemuxSafely() async throws {
        let source = try fixture("ffmpeg-mpeg4-ac3-srt.mkv", inFormats: true)
        let clip = source.deletingLastPathComponent().appending(path: "-clip:1 (test).mkv")
        try FileManager.default.moveItem(at: source, to: clip)
        let (outcome, _, _) = try await runPreset(.videoRemoveAudio, preset: nil, on: clip, outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = outcome, let output = outputs.first else {
            Issue.record("expected leading-dash filename to remux safely: \(outcome)")
            return
        }
        #expect(warnings.isEmpty)
        let probed = try await StreamRemuxer.probe(output, tools: tools(), countPackets: false)
        #expect(probed.streams.filter { $0.codecType == "subtitle" }.first?.codecName == "subrip")
    }

    @Test(arguments: ["exit 1", "kill -9 $$"])
    func failingOrKilledFFmpegFallsBackToConsentAndCleansStaging(scriptBody: String) async throws {
        let clip = try fixture("ffmpeg-mpeg4-ac3-srt.mkv", inFormats: true)
        let original = try Data(contentsOf: clip)
        let folder = clip.deletingLastPathComponent()
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseFallback-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)

        let fakeTools = try makeFakeToolsDirectory(ffmpegScript: "#!/bin/sh\n\(scriptBody)\n")
        let previousTools = ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"]
        setenv("MACEASE_MEDIA_TOOLS", fakeTools.path, 1)
        defer {
            if let previousTools {
                setenv("MACEASE_MEDIA_TOOLS", previousTools, 1)
            } else {
                unsetenv("MACEASE_MEDIA_TOOLS")
            }
        }

        let (refused, _, _) = try await runPreset(
            .videoRemoveAudio, preset: nil, on: clip, outputMode: .replace, support: support)
        #expect(refused == .failed(.invalidInput(.unpreservedStreams([.subtitle]))))
        #expect(try Data(contentsOf: clip) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [clip.lastPathComponent])
        #expect(try trackedStagingPaths(in: support).isEmpty)

        let (consented, _, _) = try await runPreset(
            .videoRemoveAudio, preset: nil, on: clip, omittedStreams: [.subtitle], outputMode: .newFile,
            support: support)
        guard case .succeeded(let outputs, let warnings) = consented, let output = outputs.first else {
            Issue.record("expected consented fallback to succeed: \(consented)")
            return
        }
        #expect(warnings == [.streamsOmitted([.subtitle])])
        #expect(try await MediaInput.open(output).skippedStreams.isEmpty)
        #expect(try Data(contentsOf: clip) == original)
    }

    @Test func cancellationDuringRemuxKillsFFmpegAndCleansStaging() async throws {
        let clip = try fixture("ffmpeg-mpeg4-ac3-srt.mkv", inFormats: true)
        let original = try Data(contentsOf: clip)
        let folder = clip.deletingLastPathComponent()
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseCancel-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let marker = support.appending(path: "started")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let fakeTools = try makeFakeToolsDirectory(
            ffmpegScript: """
                #!/bin/sh
                touch "\(marker.path)"
                exec sleep 30
                """)
        let previousTools = ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"]
        setenv("MACEASE_MEDIA_TOOLS", fakeTools.path, 1)
        defer {
            if let previousTools {
                setenv("MACEASE_MEDIA_TOOLS", previousTools, 1)
            } else {
                unsetenv("MACEASE_MEDIA_TOOLS")
            }
        }

        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let options = try #require(OperationPlanner.options(for: .videoRemoveAudio, preset: nil, settings: Settings()))
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .videoRemoveAudio, options: options, inputs: [clip]), settings: Settings())
        let task = Task {
            await engine.run(batch, settings: Settings()) { _ in }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        task.cancel()
        let result = await task.value
        #expect(result.outcomes == [.failed(.cancelled)])
        #expect(try Data(contentsOf: clip) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [clip.lastPathComponent])
        #expect(try trackedStagingPaths(in: support).isEmpty)
    }

    @Test func MP4TimecodeConsentPrecedesEncoding() async throws {
        let source = try await makeTimecodedMOV()
        let support = try TestVolume.makeFolder().appending(path: "support")
        let encodes = Mutex(0)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: support),
            phase: { if $0 == .encoding { encodes.withLock { $0 += 1 } } }
        ) { _ in }
        defer { context.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoEdits.run(.convert(.mp4), url: source, context: context)
        }
        #expect(encodes.withLock { $0 } == 0)
    }

    @Test func targetSearchRemuxesOnlyFinalCandidate() async throws {
        let source = try fixture("ffmpeg-mpeg4-ac3-srt.mkv", inFormats: true)
        let resolved = try tools()
        let marker = source.deletingLastPathComponent().appending(path: "remux-invocations")
        let fake = try makeFakeToolsDirectory(
            ffmpegScript: """
                #!/bin/sh
                echo remux >> '\(marker.path)'
                exec '\(resolved.ffmpeg.path)' "$@"
                """)
        let previous = ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"]
        setenv("MACEASE_MEDIA_TOOLS", fake.path, 1)
        defer {
            if let previous { setenv("MACEASE_MEDIA_TOOLS", previous, 1) } else { unsetenv("MACEASE_MEDIA_TOOLS") }
        }
        var preset = try #require(
            PresetLibrary(supportDirectory: source.deletingLastPathComponent()).bundled.first { $0.id == "discord" })
        preset.video?.formats = ["mkv"]
        preset.video?.maxBytes = 26_000
        let encodes = Mutex(0)
        let support = source.deletingLastPathComponent().appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: support),
            phase: { if $0 == .encoding { encodes.withLock { $0 += 1 } } }
        ) { _ in }
        defer { context.removeStaging() }
        let result = try await VideoCompressor.run(
            VideoCompression(goal: .platform(preset)), url: source, context: context)
        guard case .replace(_, let staged) = result else { Issue.record("expected final compressed candidate"); return }
        #expect(encodes.withLock { $0 } > 1)
        #expect(try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count == 1)
        #expect(try await MediaInput.open(staged.url).skippedStreams.contains(.track(3, kind: .subtitle)))
        #expect(try #require(try staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) <= 25_220)
    }

    private func streamHash(of url: URL, tools: MediaDownloadTools) async throws -> String {
        let result = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-hide_banner", "-nostdin", "-v", "error",
                "-protocol_whitelist", "file", "-i", "file:" + url.path,
                "-map", "0:V?", "-map", "0:a?", "-c", "copy",
                "-f", "streamhash", "-hash", "sha256", "-",
            ],
            directory: url.deletingLastPathComponent(), tools: tools)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trackedStagingPaths(in support: URL) throws -> [String] {
        let registry = support.appending(path: "staging.json")
        guard FileManager.default.fileExists(atPath: registry.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
    }

    private func makeFakeToolsDirectory(ffmpegScript: String) throws -> URL {
        let real = try tools()
        let directory = FileManager.default.temporaryDirectory.appending(path: "FakeTools-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["python3", "qjs", "ffprobe"] {
            try FileManager.default.createSymbolicLink(
                at: directory.appending(path: name), withDestinationURL: real.directory.appending(path: name))
        }
        let fakeFFmpeg = directory.appending(path: "ffmpeg")
        try ffmpegScript.write(to: fakeFFmpeg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpeg.path)
        return directory
    }
}
