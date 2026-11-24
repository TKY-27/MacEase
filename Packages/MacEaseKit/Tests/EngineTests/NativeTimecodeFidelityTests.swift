import AVFoundation
import CoreMedia
import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct NativeTimecodeFidelityTests {
    private func encodedSource(rate: String = "24", frames: Int = 10) async throws -> URL {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "timecoded.mov")
        let tools = try mediaFixtureTools()
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                "testsrc2=size=160x96:rate=\(rate)", "-frames:v", String(frames), "-c:v",
                "h264_videotoolbox",
            ] + ["-timecode", "01:02:03:04", source.path],
            directory: folder, tools: tools, captureOutput: false)
        return source
    }

    private func movCompression(target: Int64? = nil) throws -> VideoCompression {
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = ["mov"]
        preset.video?.videoCodec = "hevc"
        preset.video?.maxBytes = target
        return VideoCompression(goal: .platform(preset), allowsFrameRateReduction: false)
    }

    private func materialSamples(_ url: URL) async throws -> [[CMSampleBuffer]] {
        let asset = AVURLAsset(url: url)
        var samples: [[CMSampleBuffer]] = []
        for track in try await asset.loadTracks(withMediaType: .timecode) {
            guard try await track.load(.totalSampleDataLength) > 0,
                !(try await track.load(.canProvideSampleCursors))
                    || track.makeSampleCursorAtFirstSampleInDecodeOrder() != nil
            else {
                samples.append([])
                continue
            }
            let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .packets)
            var trackSamples: [CMSampleBuffer] = []
            while let sample = try await reader.nextSample() {
                if sample.numSamples > 0 { trackSamples.append(sample) }
            }
            samples.append(trackSamples)
        }
        return samples
    }

    private func bytes(_ sample: CMSampleBuffer) throws -> Data {
        let block = try #require(sample.dataBuffer)
        var payload = Data(count: block.dataLength)
        let status = try payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: $0.count, destination: try #require($0.baseAddress))
        }
        try #require(status == noErr)
        return payload
    }

    private func expectExactSamples(_ source: URL, _ output: URL) async throws {
        let original = try await materialSamples(source)
        let written = try await materialSamples(output)
        try #require(original.count == written.count)
        for (first, second) in zip(original, written) {
            try #require(first.count == second.count)
            for (left, right) in zip(first, second) {
                #expect(try bytes(left) == bytes(right))
                #expect(CMTimeCompare(left.presentationTimeStamp, right.presentationTimeStamp) == 0)
                #expect(CMTimeCompare(left.outputPresentationTimeStamp, right.outputPresentationTimeStamp) == 0)
                #expect(CMTimeCompare(left.duration, right.duration) == 0)
                #expect(CMTimeCompare(left.outputDuration, right.outputDuration) == 0)
                #expect(
                    CMFormatDescriptionEqual(
                        left.formatDescription,
                        otherFormatDescription: right.formatDescription))
            }
        }
    }

    private func compress(_ source: URL, target: Int64? = nil) async throws -> URL {
        var settings = Settings()
        settings.outputMode = .newFile
        let folder = source.deletingLastPathComponent()
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let batch = OperationPlanner.batch(
            for: OperationRequest(
                op: .videoCompress, options: .video(.compress(try movCompression(target: target))), inputs: [source]),
            settings: settings)
        let outcome = await engine.run(batch, settings: settings) { _ in }
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first else {
            Issue.record("expected native timecode compression: \(outcome.outcomes)")
            throw EngineError.encodeFailed("compression failed")
        }
        #expect(warnings.isEmpty)
        return try #require(outputs.first)
    }

    @Test(arguments: [(24, 10), (30, 31)])
    func roundedMovieDurationCarriesThroughFinderAndRecipe(rate: Int, frames: Int) async throws {
        let source = try await encodedSource(rate: String(rate), frames: frames)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        #expect(duration.timescale == 1000)
        #expect(duration.value == Int64(ceil(Double(frames) * 1000 / Double(rate))))
        let original = try Data(contentsOf: source)
        let output = try await compress(source)
        try await expectExactSamples(source, output)
        let outputAsset = AVURLAsset(url: output)
        let track = try #require(try await outputAsset.loadTracks(withMediaType: .timecode).first)
        #expect(
            CMTimeCompare(
                try await track.load(.timeRange).duration, CMTime(value: Int64(frames), timescale: Int32(rate))) == 0)
        let recipe = Recipe(name: "Native Delivery", variants: [OutputVariant(output: .videoMOV)])
        #expect(try await RecipePlanner.streamOmissions(recipe: recipe, inputs: [source]).isEmpty)
        let batch = try RecipePlanner.batch(recipe: recipe, inputs: [source], settings: Settings())
        let engine = try JobEngine(
            supportDirectory: source.deletingLastPathComponent().appending(path: "recipe-engine"), concurrency: 1)
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let packages, let warnings) = outcome.outcomes.first else {
            Issue.record("expected native MOV recipe: \(outcome.outcomes)")
            return
        }
        #expect(warnings.isEmpty)
        let package = try #require(packages.first)
        let delivered = try #require(
            try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil).first {
                $0.pathExtension == "mov"
            })
        try await expectExactSamples(source, delivered)
        #expect(try Data(contentsOf: source) == original)
    }

    private func customTimecode(
        frameDuration: CMTime = CMTime(value: 1, timescale: 24), quanta: UInt32 = 24,
        flags: UInt32 = 0, wide: Bool = false, frames: [Int64] = [0], tracks: Int = 1,
        malformedSecond: Bool = false, changedSecondFormat: Bool = false, trimmed: Bool = false, sourceURL: URL? = nil
    ) async throws -> URL {
        let source = if let sourceURL { sourceURL } else { try await encodedSource(frames: 48) }
        let asset = AVURLAsset(url: source)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AssetTrackReader(asset: asset, track: video, number: 1, mode: .packets)
        let destination = try TestVolume.makeFolder().appending(path: "custom.mov")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.movieTimeScale = 1000
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: try await video.load(.formatDescriptions).first)
        writer.add(input)
        var pairs: [(AVAssetWriterInput, CMTimeCodeFormatDescription)] = []
        for _ in 0..<tracks {
            var format: CMTimeCodeFormatDescription?
            try #require(
                CMTimeCodeFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    timeCodeFormatType: wide ? kCMTimeCodeFormatType_TimeCode64 : kCMTimeCodeFormatType_TimeCode32,
                    frameDuration: frameDuration, frameQuanta: quanta, flags: flags, extensions: nil,
                    formatDescriptionOut: &format) == noErr)
            let description = try #require(format)
            let timecode = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: description)
            timecode.mediaTimeScale = frameDuration.timescale
            writer.add(timecode)
            input.addTrackAssociation(withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue)
            pairs.append((timecode, description))
        }
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: trimmed ? CMTime(value: 1, timescale: 2) : .zero)
        for (timecode, format) in pairs {
            for (index, frame) in frames.enumerated() {
                var value = frame.bigEndian
                var payload = withUnsafeBytes(of: &value) { Data($0) }
                if !wide { payload = Data(payload.suffix(MemoryLayout<Int32>.size)) }
                if malformedSecond && index == 1 { payload = Data(payload.prefix(MemoryLayout<Int16>.size)) }
                var sampleFormat = format
                if changedSecondFormat && index == 1 {
                    var changed: CMTimeCodeFormatDescription?
                    try #require(
                        CMTimeCodeFormatDescriptionCreate(
                            allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                            frameDuration: CMTime(value: 1, timescale: 30), frameQuanta: 30, flags: 0, extensions: nil,
                            formatDescriptionOut: &changed) == noErr)
                    sampleFormat = try #require(changed)
                }
                var block: CMBlockBuffer?
                try #require(
                    CMBlockBufferCreateWithMemoryBlock(
                        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                        dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr)
                let buffer = try #require(block)
                try payload.withUnsafeBytes {
                    try #require(
                        CMBlockBufferReplaceDataBytes(
                            with: try #require($0.baseAddress), blockBuffer: buffer, offsetIntoDestination: 0,
                            dataLength: $0.count) == noErr)
                }
                let sampleDuration = CMTime(value: 2, timescale: Int32(max(1, frames.count)))
                var timing = CMSampleTimingInfo(
                    duration: sampleDuration,
                    presentationTimeStamp: CMTimeMultiply(sampleDuration, multiplier: Int32(index)),
                    decodeTimeStamp: .invalid)
                var size = payload.count
                var sample: CMSampleBuffer?
                try #require(
                    CMSampleBufferCreate(
                        allocator: kCFAllocatorDefault, dataBuffer: buffer, dataReady: true, makeDataReadyCallback: nil,
                        refcon: nil,
                        formatDescription: sampleFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                        sampleBufferOut: &sample) == noErr)
                while !timecode.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                try #require(timecode.append(try #require(sample)))
            }
            timecode.markAsFinished()
        }
        while let sample = try await reader.nextSample() {
            guard sample.numSamples > 0 else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            try #require(input.append(sample))
        }
        input.markAsFinished()
        if trimmed { writer.endSession(atSourceTime: CMTime(value: 3, timescale: 2)) }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return destination
    }

    @Test(arguments: [
        (1001, 24000, 24, false), (1001, 30000, 30, true), (1001, 60000, 60, true),
        (1, 25, 25, false), (1, 50, 50, false), (1, 60, 60, false),
    ])
    func ratesAndDropFrameFlagsRemainExact(numerator: Int, denominator: Int, quanta: Int, drop: Bool) async throws {
        let source = try await customTimecode(
            frameDuration: CMTime(value: Int64(numerator), timescale: Int32(denominator)), quanta: UInt32(quanta),
            flags: drop ? kCMTimeCodeFlag_DropFrame : 0)
        try await expectExactSamples(source, try await compress(source))
    }

    @Test func wideDiscontinuousSamplesAndTwoTracksRemainExact() async throws {
        let source = try await customTimecode(wide: true, frames: [Int64(Int32.max) + 100, -200, 900], tracks: 2)
        try await expectExactSamples(source, try await compress(source))
    }

    @Test(arguments: [true, false])
    func invalidLaterSampleAsksBeforeEncoding(malformedPayload: Bool) async throws {
        let source = try await customTimecode(
            frames: [0, 24], malformedSecond: malformedPayload, changedSecondFormat: !malformedPayload)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
        if malformedPayload {
            let samples = try await materialSamples(source)
            #expect(samples.first?.last?.totalSampleSize == MemoryLayout<Int16>.size)
        } else {
            #expect(try await track.load(.formatDescriptions).count == 2)
        }
        let encodes = Mutex(0)
        let support = source.deletingLastPathComponent().appending(path: "unsupported-engine")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: support),
            phase: { if $0 == .encoding { encodes.withLock { $0 += 1 } } }
        ) { _ in }
        defer { context.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoCompressor.run(try movCompression(), url: source, context: context)
        }
        #expect(encodes.withLock { $0 } == 0)
    }

    @Test func fixedFrameRateTargetSizeKeepsTimecode() async throws {
        let source = try await encodedSource(frames: 96)
        let targetBytes: Int64 = 25_000
        let output = try await compress(source, target: targetBytes)
        try await expectExactSamples(source, output)
        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.nominalFrameRate) == 24)
        #expect(Int64(try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)) <= targetBytes)
    }
    @Test(arguments: [1, 2])
    func trimmedTimecodeAsksBeforeFinderAndRecipeEncoding(sampleCount: Int) async throws {
        let source = try await customTimecode(frames: sampleCount == 1 ? [0] : [0, 24], trimmed: true)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
        let segment = try #require(try await track.load(.segments).first { !$0.isEmpty })
        #expect(segment.timeMapping.source.start.seconds == 0.5)
        #expect(try await materialSamples(source).first?.count == sampleCount)
        let plan = try await NativeTimecodePlan.make(
            for: MediaInput.open(source), destination: .mov, preservesTiming: true)
        #expect(!plan.carriesTimecode)
        #expect(plan.omittedKinds == [.timecode])
        let recipe = Recipe(name: "Edited Timecode", variants: [OutputVariant(output: .videoMOV)])
        #expect(
            try await RecipePlanner.streamOmissions(recipe: recipe, inputs: [source])[source]?.streams == [.timecode])
        let encodes = Mutex(0)
        let support = try TestVolume.makeFolder().appending(path: "edited-support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: support),
            phase: { if $0 == .encoding { encodes.withLock { $0 += 1 } } }
        ) { _ in }
        defer { context.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoCompressor.run(try movCompression(), url: source, context: context)
        }
        #expect(encodes.withLock { $0 } == 0)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = try RecipePlanner.batch(recipe: recipe, inputs: [source], settings: Settings())
        let refused = await engine.run(batch, settings: Settings()) { progress in
            if progress.itemPhases.contains(.encoding) { encodes.withLock { $0 += 1 } }
        }
        #expect(refused.outcomes == [.failed(.invalidInput(.unpreservedStreams([.timecode])))])
        #expect(encodes.withLock { $0 } == 0)
        let required = try await RecipePlanner.streamOmissions(recipe: recipe, inputs: [source])
        let approved = try RecipePlanner.batch(
            recipe: recipe, inputs: [source], settings: Settings(), omissions: required)
        let result = await engine.run(approved, settings: Settings()) { _ in }
        guard case .succeeded(_, let warnings) = result.outcomes.first else {
            Issue.record("expected edited timecode omission to finish recipe: \(result.outcomes)")
            return
        }
        #expect(warnings == [.streamsOmitted([.timecode])])

    }

    @Test func sourceReplacementAndDeletionStayDistinctFromTimecodeConsent() async throws {
        let source = try await encodedSource()
        let output = try await compress(source)
        let plan = try await NativeTimecodePlan.make(
            for: MediaInput.open(source), destination: .mov, preservesTiming: true)
        let replacement = try await encodedSource(rate: "30", frames: 31)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: replacement, to: source)
        for deleted in [false, true] {
            if deleted { try FileManager.default.removeItem(at: source) }
            do {
                try await plan.verify(original: source, output: output)
                Issue.record("expected changed source failure")
            } catch EngineError.invalidInput(.malformed(let message)) {
                #expect(message.contains("original changed"))
            }
        }
    }

    @Test func cancelledNativeWriterReportsWriterFailure() async throws {
        let source = try await encodedSource()
        let asset = AVURLAsset(url: source)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let timecode = try await NativeTimecode(asset: asset)
        let writer = try AVAssetWriter(
            outputURL: source.deletingLastPathComponent().appending(path: "cancelled.mov"), fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: try await video.load(.formatDescriptions).first)
        writer.add(input)
        try timecode.attach(to: writer, video: input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        writer.cancelWriting()
        do {
            try timecode.appendReady(writer: writer)
            Issue.record("expected writer failure")
        } catch EngineError.encodeFailed(let reason) {
            #expect(!reason.isEmpty)
        }
    }

    @Test func HDRToSDRKeepsNativeTimecode() async throws {
        let hdr = try #require(
            Bundle.module.url(forResource: "x265-pq", withExtension: "mp4", subdirectory: "Resources"))
        let source = try await customTimecode(sourceURL: hdr)
        #expect(try await VideoSDR.classification(source) != .sdr)
        let support = source.deletingLastPathComponent().appending(path: "sdr-support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(settings: Settings(), staging: StagingArea(supportDirectory: support)) { _ in }
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try await VideoSDR.run(url: source, context: context) else {
            Issue.record("expected HDR to SDR output")
            return
        }
        #expect(try await VideoSDR.classification(output.url) == .sdr)
        try await expectExactSamples(source, output.url)
    }

    @Test func timecodeAndSubtitlesAskOnlyAboutSubtitles() async throws {
        let source = try await encodedSource(frames: 48)
        let folder = source.deletingLastPathComponent()
        let subtitle = folder.appending(path: "subtitles.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nA plain cue\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let combined = folder.appending(path: "subtitled.mov")
        let tools = try mediaFixtureTools()
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-hide_banner", "-nostdin", "-v", "error", "-y", "-i", source.path, "-i", subtitle.path,
                "-map", "0:v", "-map", "1:s", "-c:v", "copy", "-c:s", "mov_text", "-timecode", "01:02:03:04",
                combined.path,
            ],
            directory: folder, tools: tools, captureOutput: false)
        let plan = try await NativeTimecodePlan.make(
            for: MediaInput.open(combined), destination: .mov, preservesTiming: true)
        #expect(plan.carriesTimecode)
        #expect(plan.omittedKinds == [.subtitle])
        var settings = Settings()
        settings.outputMode = .newFile
        let engine = try JobEngine(supportDirectory: folder.appending(path: "combined-engine"), concurrency: 1)
        for consent in [Set<UnpreservedStream>(), [.subtitle]] {
            let batch = OperationPlanner.batch(
                for: OperationRequest(
                    op: .videoFlip, options: .video(.flip(horizontally: true)), inputs: [combined],
                    omittedStreams: consent), settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            if consent.isEmpty {
                #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.subtitle])))])
            } else if case .succeeded(let outputs, let warnings) = outcome.outcomes.first {
                #expect(warnings == [.streamsOmitted([.subtitle])])
                try await expectExactSamples(combined, try #require(outputs.first))
            } else {
                Issue.record("expected native timecode with consented subtitle omission: \(outcome.outcomes)")
            }
        }
    }

    @Test func emptyTimecodeTrackAsksBeforeEncoding() async throws {
        let source = try await customTimecode()
        var content = try Data(contentsOf: source)
        for (atom, offset) in [("stsz", 12), ("stts", 8), ("stsc", 8), ("stco", 8)] {
            let position = try #require(content.range(of: Data(atom.utf8), options: .backwards)).lowerBound + offset
            content.replaceSubrange(
                position..<(position + MemoryLayout<UInt32>.size),
                with: Data(repeating: 0, count: MemoryLayout<UInt32>.size))
        }
        try content.write(to: source)
        #expect(try await AVURLAsset(url: source).loadTracks(withMediaType: .timecode).count == 1)
        #expect(try await materialSamples(source).first?.isEmpty == true)
        let plan = try await NativeTimecodePlan.make(
            for: MediaInput.open(source), destination: .mov, preservesTiming: true)
        #expect(!plan.carriesTimecode)
        #expect(plan.omittedKinds == [.timecode])
    }

    @Test func movieDurationDifferenceAtOneSourceTickIsRejected() async throws {
        let source = try await encodedSource()
        let output = try await compress(source)
        let originalAsset = AVURLAsset(url: source)
        let originalTrack = try #require(try await originalAsset.loadTracks(withMediaType: .timecode).first)
        let duration = try await originalTrack.load(.timeRange).duration
        let sourceMovieScale = try await originalAsset.load(.duration).timescale
        let outputMovieScale = try await AVURLAsset(url: output).load(.duration).timescale
        let changedDuration = CMTimeConvertScale(
            duration + CMTime(value: 1, timescale: sourceMovieScale), timescale: outputMovieScale, method: .default)
        var content = try Data(contentsOf: output)
        let edit = try #require(content.range(of: Data("elst".utf8), options: .backwards)).lowerBound
        try #require(content[edit + MemoryLayout<UInt32>.size] == 0)
        let position = edit + 3 * MemoryLayout<UInt32>.size
        var changed = try #require(UInt32(exactly: changedDuration.value)).bigEndian
        withUnsafeBytes(of: &changed) {
            content.replaceSubrange(position..<(position + MemoryLayout<UInt32>.size), with: $0)
        }
        try content.write(to: output)
        let plan = try await NativeTimecodePlan.make(
            for: MediaInput.open(source), destination: .mov, preservesTiming: true)
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            try await plan.verify(original: source, output: output)
        }
    }

    @Test func sourceChangeDuringEncodingIsNotAStreamQuestion() async throws {
        let source = try await encodedSource(frames: 48)
        let replacement = try await encodedSource(rate: "30", frames: 31)
        let input = try await MediaInput.open(source)
        let carry = try await NativeTimecodePlan.make(for: input, destination: .mov, preservesTiming: true)
        let video = try #require(input.video)
        var plan = try VideoEdits.plan(
            .flip(horizontally: true), input: input, source: video, settings: Settings().video)
        plan.carriesTimecode = true
        let changed = Mutex(false)
        let mutationFailures = Mutex<[String]>([])
        let output = source.deletingLastPathComponent().appending(path: "source-change.mov")
        do {
            try await carry.write(input, plan: plan, to: output) { _ in
                let replace = changed.withLock { flag in
                    if flag { return false }
                    flag = true
                    return true
                }
                if replace {
                    do {
                        try FileManager.default.removeItem(at: source)
                        try FileManager.default.copyItem(at: replacement, to: source)
                    } catch { mutationFailures.withLock { $0.append(error.localizedDescription) } }
                }
            }
            Issue.record("expected source-change failure")
        } catch EngineError.invalidInput(.malformed(let message)) {
            #expect(message.contains("original changed"))
        }
        #expect(changed.withLock { $0 })
        #expect(mutationFailures.withLock { $0.isEmpty })
    }

    @Test func emptyTimecodeTrackIsDeterministicConcurrentlyAndUnreadableTrackStillFails() async throws {
        let valid = try await customTimecode()
        let empty = valid.deletingLastPathComponent().appending(path: "empty-concurrent.mov")
        var content = try Data(contentsOf: valid)
        for (atom, offset) in [("stsz", 12), ("stts", 8), ("stsc", 8), ("stco", 8)] {
            let position = try #require(content.range(of: Data(atom.utf8), options: .backwards)).lowerBound + offset
            content.replaceSubrange(
                position..<(position + MemoryLayout<UInt32>.size),
                with: Data(repeating: 0, count: MemoryLayout<UInt32>.size))
        }
        try content.write(to: empty)
        let concurrentReads = 50
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentReads {
                group.addTask {
                    let asset = UntrustedMediaAsset.make(empty)
                    let track = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
                    #expect(try await NativeTimecode.materialSamples(in: asset, track: track).isEmpty)
                    let plan = try await NativeTimecodePlan.make(
                        for: MediaInput.open(empty), destination: .mov, preservesTiming: true)
                    #expect(!plan.carriesTimecode)
                    #expect(plan.omittedKinds == [.timecode])
                }
            }
            try await group.waitForAll()
        }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            try await NativeTimecode.verify(original: valid, output: empty)
        }

        let validAsset = UntrustedMediaAsset.make(valid)
        let validTrack = try #require(try await validAsset.loadTracks(withMediaType: .timecode).first)
        let unrelatedAsset = UntrustedMediaAsset.make(empty)
        do {
            _ = try await NativeTimecode.materialSamples(in: unrelatedAsset, track: validTrack)
            Issue.record("expected decode failure for unreadable timecode track")
        } catch EngineError.decodeFailed {
        }
    }

}
