import AVFoundation
import CoreMedia
import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct NativeTimecodeTests {
    private func fixture(_ name: String) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
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
            ?? FileManager.default.temporaryDirectory.appending(path: "MacEaseTimecodeTest-\(UUID().uuidString)")
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
        let resolved = try mediaFixtureTools()
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
        #expect(try await timecodeStart(compressed) == 89_356)
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
        #expect(try await timecodeStart(rotated) == 89_356)
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

    @Test func targetSizeTimecodeConsentPrecedesEveryEncodingAttempt() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try await highFrameRateTimecodedClip(in: folder)
        let encodes = Mutex(0)
        let support = folder.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: support),
            phase: { if $0 == .encoding { encodes.withLock { $0 += 1 } } }
        ) { _ in }
        defer { context.removeStaging() }
        let compression = VideoCompression(goal: .bytes(20_000), allowsFrameRateReduction: true)
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoCompressor.run(compression, url: source, context: context)
        }
        #expect(encodes.withLock { $0 } == 0)
        let consented = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: support),
            omittedStreams: [.timecode]
        ) { _ in }
        defer { consented.removeStaging() }
        let result = try await VideoCompressor.run(compression, url: source, context: consented)
        guard case .replace(_, let output) = result else { Issue.record("expected consented compression"); return }
        #expect(try await AVURLAsset(url: output.url).loadTracks(withMediaType: .timecode).isEmpty)
        #expect(consented.warnings == [.streamsOmitted([.timecode])])
    }

    @Test func unsupportedTimecodeAsksOnceThenConsentExcludesIt() async throws {
        let source = try await makeTimecodedMOV()
        var bytes = try Data(contentsOf: source)
        let description = try #require(bytes.range(of: Data("stsd".utf8), options: .backwards)).lowerBound
        let subtype = (description + 16)..<(description + 20)
        try #require(bytes[subtype] == Data("tmcd".utf8))
        bytes.replaceSubrange(subtype, with: Data("tc64".utf8))
        try bytes.write(to: source)
        let opened = try await MediaInput.open(source)
        #expect(MediaInput.unpreservedStreams(from: opened.skippedStreams) == [.timecode])
        let asset = AVURLAsset(url: source)
        let timecode = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
        #expect(
            CMFormatDescriptionGetMediaSubType(try #require(try await timecode.load(.formatDescriptions).first))
                == kCMTimeCodeFormatType_TimeCode64)
        let original = try Data(contentsOf: source)
        let plan = try await NativeTimecodePlan.make(for: opened, destination: .mov, preservesTiming: true)
        #expect(!plan.carriesTimecode)
        let (refused, _, _) = try await runPreset(.videoRotate, preset: "right-90", on: source, outputMode: .newFile)
        #expect(refused == .failed(.invalidInput(.unpreservedStreams([.timecode]))))
        let (continued, _, _) = try await runPreset(
            .videoRotate, preset: "right-90", on: source,
            omittedStreams: [.timecode], outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = continued, let output = outputs.first else {
            Issue.record("expected one consent to resolve unsupported timecode: \(continued)")
            return
        }
        #expect(warnings == [.streamsOmitted([.timecode])])
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .timecode).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func failedTimecodeVerificationUsesConsentAndRetryHonoursIt() async throws {
        let source = try await makeTimecodedMOV(timecode: "01:02:03:04")
        let different = try await makeTimecodedMOV(timecode: "02:03:04:05")
        let opened = try await MediaInput.open(source)
        let plan = try await NativeTimecodePlan.make(for: opened, destination: .mov, preservesTiming: true)
        #expect(plan.carriesTimecode)
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            try await plan.verify(original: source, output: different)
        }
        let consented = try await NativeTimecodePlan.make(
            for: opened, destination: .mov, preservesTiming: true,
            omitting: [.timecode])
        #expect(!consented.carriesTimecode)
        let (outcome, _, _) = try await runPreset(
            .videoRotate, preset: "right-90", on: source,
            omittedStreams: [.timecode], outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = outcome, let output = outputs.first else {
            Issue.record("expected consented retry: \(outcome)")
            return
        }
        #expect(warnings == [.streamsOmitted([.timecode])])
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .timecode).isEmpty)
    }

    private func timecodeStart(_ url: URL) async throws -> Int32 {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .packets)
        while let sample = try await reader.nextSample() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var frame: Int32 = 0
            try #require(
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: MemoryLayout<Int32>.size, destination: &frame) == noErr)
            return frame.bigEndian
        }
        throw EngineError.decodeFailed("timecode samples missing")
    }
}
