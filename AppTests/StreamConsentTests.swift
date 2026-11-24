import AVFoundation
import AppKit
import CoreMedia
import XCTest

@testable import Engine
@testable import MacEase

@MainActor
final class StreamConsentTests: XCTestCase {
    func testActivityOffersConsentOnlyForAffectedFilesAndResubmitsExactlyThoseKinds() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let plain = directory.appending(path: "plain.mp4")
        try FileManager.default.copyItem(at: try fixture(), to: plain)
        let original = try Data(contentsOf: timecoded)
        let (jobs, activity, store) = try makeActivity(in: directory)
        store.activityClosesAfterFailure = true

        let options = try XCTUnwrap(
            OperationPlanner.options(for: .videoRotate, preset: "right-90", settings: store.planning))
        let request = OperationRequest(op: .videoRotate, options: options, inputs: [timecoded, plain])
        let started = await jobs.run(request).value
        let first = try XCTUnwrap(started)
        guard case .failed(.invalidInput(.unpreservedStreams([.timecode]))) = first.outcomes[0],
            case .succeeded = first.outcomes[1]
        else { return XCTFail("unexpected outcomes \(first.outcomes)") }

        let problem = try XCTUnwrap(ActivityResult(first).problems.first)
        XCTAssertTrue(problem.message.contains(timecoded.lastPathComponent))
        XCTAssertTrue(problem.message.contains(String(localized: "timecode tracks")))
        XCTAssertTrue(jobs.canContinueWithoutStreams(first.batchID))
        XCTAssertFalse(jobs.canRetry(first.batchID), "a plain retry would only fail again")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == String(localized: "MacEase Activity") })
        XCTAssertTrue(panel.isVisible, "a pending choice stays visible despite closing after failure")

        XCTAssertEqual(try Data(contentsOf: timecoded), original)
        let declined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("timecoded") }
        XCTAssertEqual(declined, [timecoded.lastPathComponent], "nothing is written before consent")

        let known = Set(jobs.sessions.keys)
        jobs.continueWithoutStreams(first.batchID)
        try await eventually { jobs.sessions.keys.contains { !known.contains($0) } }
        let retried = try XCTUnwrap(jobs.sessions.first { !known.contains($0.key) }?.value)
        XCTAssertEqual(retried.request.inputs, [timecoded])
        XCTAssertEqual(retried.request.omittedStreams, [.timecode])
        guard case .succeeded(let outputs, let warnings) = retried.outcome.outcomes.first else {
            return XCTFail("consented retry failed: \(retried.outcome.outcomes)")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.timecode])])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try Data(contentsOf: timecoded), original)
        XCTAssertFalse(jobs.canContinueWithoutStreams(first.batchID), "one consent runs once")
        XCTAssertTrue(jobs.continuedWithoutStreams.contains(first.batchID))
        activity.dismissBatch(first.batchID)
    }

    func testConsequenceNamesTheFilesKindsAndOriginalsFate() {
        let timecode = String(localized: "timecode tracks")
        let replaced = UserMessages.streamOmissionConsequence([.timecode], files: ["a.mov"], replacesOriginals: true)
        let kept = UserMessages.streamOmissionConsequence([.timecode], files: ["a.mov"], replacesOriginals: false)
        for text in [replaced, kept] {
            XCTAssertTrue(text.contains("a.mov"))
            XCTAssertTrue(text.contains(timecode))
        }
        XCTAssertNotEqual(replaced, kept)
        let batch = UserMessages.streamOmissionConsequence(
            [.timecode, .chapter], files: ["a.mov", "b.mov"], replacesOriginals: false)
        XCTAssertTrue(batch.contains("2"))
        XCTAssertTrue(batch.contains(UserMessages.unpreservedStreams([.timecode, .chapter], joinedBy: .or)))
        let action = UserMessages.continueWithout([.timecode, .chapter])
        XCTAssertTrue(action.contains(timecode.localizedCapitalized))
        XCTAssertTrue(action.contains(String(localized: "chapters").localizedCapitalized))
    }

    func testEditorAsksBeforeOpeningAndSavesWithTheSameConsent() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let model = MediaEditorModel(
            urls: [timecoded], isVideo: true, settings: Engine.Settings(), staging: try staging(in: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.streamConsent != nil || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.ready)
        let request = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(request.purpose, .open)
        XCTAssertEqual(request.files, [StreamConsentRequest.File(url: timecoded, streams: [.timecode])])
        XCTAssertTrue(request.title.contains(timecoded.lastPathComponent))
        XCTAssertTrue(request.actionTitle.contains(String(localized: "timecode tracks").localizedCapitalized))

        model.continueWithoutStreams(request)
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertNil(model.streamConsent, "the same file is not asked about twice")
        XCTAssertNotNil(model.omittedStreamsNote)
        model.change { $0.photo.geometry.quarterTurns = 1 }
        let planned = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(planned.batch.items.map(\.omittedStreams), [[.timecode]])
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let saved = await engine.run(planned.batch, settings: planned.settings) { _ in }
        guard case .succeeded(_, let warnings) = saved.outcomes.first else {
            return XCTFail("editor save failed: \(saved.outcomes)")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.timecode])])
    }

    func testEditorAsksBeforeAddingAVideoThatLosesStreams() async throws {
        let directory = try workspace()
        let plain = directory.appending(path: "plain.mp4")
        try FileManager.default.copyItem(at: try fixture(), to: plain)
        let timecoded = try await timecodedClip(in: directory)
        let model = MediaEditorModel(
            urls: [plain], isVideo: true, settings: Engine.Settings(), staging: try staging(in: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.omittedStreamsNote)

        model.importVideos([timecoded])
        try await eventually { model.streamConsent != nil || model.failure != nil }
        let request = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(request.purpose, .add([timecoded]))
        XCTAssertEqual(model.values.sources.count, 1, "declining leaves the timeline unchanged")

        model.continueWithoutStreams(request)
        try await eventually { model.values.sources.count == 2 || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertEqual(try model.makeSave(replacingOriginal: false).batch.items.map(\.omittedStreams), [[.timecode]])
    }

    func testAudioTrimAsksBeforeOpeningAndTrimsWithTheSameConsent() async throws {
        let directory = try workspace()
        let audio = try waveWithCuePoints(in: directory)
        let model = AudioTrimModel(url: audio, staging: try staging(in: directory), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.ready)
        let request = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(request.files, [StreamConsentRequest.File(url: audio, streams: [.data])])

        model.continueWithoutStreams(request)
        try await eventually { model.ready || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.omittedStreams, [.data])
        let trim = OperationRequest(
            op: .audioTrim, options: .audio(.trim(start: 0, end: model.duration / 2, fadeIn: 0, fadeOut: 0)),
            inputs: [audio], omittedStreams: model.omittedStreams)
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let settings = Engine.Settings()
        let outcome = await engine.run(OperationPlanner.batch(for: trim, settings: settings), settings: settings) {
            _ in
        }
        guard case .succeeded(_, let warnings) = outcome.outcomes.first else {
            return XCTFail("trim failed: \(outcome.outcomes)")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.data])])
    }

    private func makeActivity(in directory: URL) throws -> (JobCenter, ActivityWindow, SettingsStore) {
        let suite = "MacEaseStreamConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let notifier = BatchNotifier(settings: store)
        let jobs = JobCenter(engine: engine, settings: store, notifier: notifier)
        let activity = ActivityWindow(jobs: jobs, settings: store, notifier: notifier)
        jobs.onStart = { [weak activity] in activity?.started($0) }
        jobs.showsFinished = { [weak activity] in activity?.finished($0, outcome: $1) ?? false }
        return (jobs, activity, store)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4"))
    }

    private func staging(in directory: URL) throws -> StagingArea {
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        return StagingArea(supportDirectory: support)
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the consent flow")
    }

    /// A trim cannot keep cue chunks.
    private func waveWithCuePoints(in directory: URL) throws -> URL {
        let sampleRate: UInt32 = 8_000
        let samples = (0..<Int(sampleRate)).map { Int16(sin(Double($0) / 4) * 8_000) }
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var format = little(UInt16(1)) + little(UInt16(1)) + little(sampleRate) + little(sampleRate * 2)
        format += little(UInt16(2)) + little(UInt16(16))
        let audio = samples.reduce(into: Data()) { $0 += little($1) }
        let chunks = [("fmt ", format), ("data", audio), ("cue ", little(UInt32(0)))]
            .reduce(into: Data()) { $0 += Data($1.0.utf8) + little(UInt32($1.1.count)) + $1.1 }
        let url = directory.appending(path: "cues.wav")
        try (Data("RIFF".utf8) + little(UInt32(4 + chunks.count)) + Data("WAVE".utf8) + chunks).write(to: url)
        return url
    }

    private func timecodedClip(in directory: URL) async throws -> URL {
        let asset = AVURLAsset(url: try fixture())
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let duration = try await asset.load(.duration)
        let destination = directory.appending(path: "timecoded.mov")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
        var format: CMTimeCodeFormatDescription?
        XCTAssertEqual(
            CMTimeCodeFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: CMTime(value: 1, timescale: 24), frameQuanta: 24, flags: 0, extensions: nil,
                formatDescriptionOut: &format), noErr)
        let timecodeFormat = try XCTUnwrap(format)
        let timecodeIn = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: timecodeFormat)
        writer.add(videoIn)
        writer.add(timecodeIn)
        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var frameNumber = Int32(0).bigEndian
        var block: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: MemoryLayout<Int32>.size,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: MemoryLayout<Int32>.size, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        XCTAssertEqual(
            CMBlockBufferReplaceDataBytes(
                with: &frameNumber, blockBuffer: buffer, offsetIntoDestination: 0,
                dataLength: MemoryLayout<Int32>.size), noErr)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = MemoryLayout<Int32>.size
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: buffer, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: timecodeFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample), noErr)
        while !timecodeIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(timecodeIn.append(try XCTUnwrap(sample)))
        timecodeIn.markAsFinished()
        while true {
            guard videoIn.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            guard let videoSample = videoOut.copyNextSampleBuffer() else {
                videoIn.markAsFinished()
                break
            }
            XCTAssertTrue(videoIn.append(videoSample))
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return destination
    }
}
