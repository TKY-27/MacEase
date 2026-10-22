import AVFoundation
import CoreMedia
import Formats
import Foundation
import Testing

@testable import Engine

@Suite(.serialized) struct VideoMetadataPreservationTests {
    private static let title = "A preserved title"
    private static let description = "A preserved description"
    private static let location = "+35.6895+139.6917/"
    private static let normalizedLocation = "+35.6895+139.6917+000.000/"
    private static let creationDate = "2026-10-22T12:00:00+09:00"
    private static let trackTitle = "Japanese audio"
    private static let videoTitle = "Camera picture"
    private static let audioVolume: Float = 0.5
    private static let videoVolume: Float = 0.25
    private static let readinessTimeout = Duration.seconds(30)

    @Test(arguments: [OutputContainer.webm, .avi])
    func encodingTagsAndSingletonGroupsDoNotCountAsLoss(container: OutputContainer) async throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let asset = AVURLAsset(url: fixtureURL)
        #expect(try await asset.load(.metadata).contains { $0.identifier == .iTunesMetadataEncodingTool })
        #expect(try await asset.load(.trackGroups).contains { $0.trackIDs.count == 1 })
        let source = try await MediaInput.open(fixtureURL)
        let metadata = try await VideoMetadata.load(from: source)
        #expect(metadata.losses(for: container, includingAudio: true).isEmpty)
    }

    @Test func outputCheckIgnoresSingletonGroupAndEncodingTag() async throws {
        let folder = try folder()
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let source = try await MediaInput.open(fixtureURL)
        let metadata = try await VideoMetadata.load(from: source)
        let outputURL = folder.appending(path: "remuxed.mov")
        try await Transcoder.run(
            source, plan: TranscodePlan(container: .mov, video: .copy, audio: .copy), to: outputURL
        ) { _ in }
        #expect(try await metadata.losses(in: outputURL, container: .mov, includingAudio: true).isEmpty)
    }

    @Test func derivedExportReportsSelectedTrackProperties() async throws {
        let sourceURL = try await source(in: folder(), disabledAudio: true)
        let source = try await MediaInput.open(sourceURL)
        let metadata = try await VideoMetadata.load(from: source)
        #expect(
            metadata.losses(for: nil, includingVideo: true, includingAudio: false)
                == [.descriptiveMetadata, .trackMetadata, .language, .volume])
        #expect(
            metadata.losses(for: nil, includingVideo: false, includingAudio: true)
                == [.descriptiveMetadata, .trackMetadata, .language, .volume, .enabledState])
    }

    @Test func audioExtractionWarnsUnderReplaceSetting() async throws {
        let folder = try folder()
        let sourceURL = try await source(in: folder)
        let original = try Data(contentsOf: sourceURL)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(.m4aAAC, url: sourceURL, context: context)
        guard case .derived(let nextTo, let outputs) = result, let output = outputs.first else {
            Issue.record("expected derived audio")
            return
        }
        #expect(nextTo == sourceURL)
        #expect(
            context.warnings == [.videoMetadataDropped([.descriptiveMetadata, .trackMetadata, .language, .volume])])
        #expect(try await AVURLAsset(url: output.url).loadTracks(withMediaType: .audio).count == 1)
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test func metadataPolicyUsesDerivedPlanBeforeAndAfterWriting() async throws {
        let folder = try folder()
        let sourceURL = try await source(in: folder)
        let original = try Data(contentsOf: sourceURL)
        let source = try await MediaInput.open(sourceURL)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        var plan = TranscodePlan(container: .mkv, video: .copy, audio: .copy)
        let losses: [VideoMetadataProperty] = [.descriptiveMetadata, .trackMetadata, .language, .volume]
        await #expect(throws: EngineError.videoMetadataUnsupported(losses)) {
            _ = try await VideoProperties.prepare(plan, input: source, context: context)
        }
        plan.derived = true
        let prepared = try await VideoProperties.prepare(plan, input: source, context: context)
        let output = folder.appending(path: "derived.mkv")
        try await Transcoder.run(source, plan: prepared, to: output) { _ in }
        try await VideoProperties.verify(prepared, output: output, context: context)
        #expect(context.warnings == [.videoMetadataDropped(losses)])
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test(arguments: [OutputContainer.mov, .mp4, .m4v])
    func nativeRemuxPreservesMetadata(container: OutputContainer) async throws {
        let folder = try folder()
        let sourceURL = try await source(in: folder)
        let source = try await MediaInput.open(sourceURL)
        let metadata = try await VideoMetadata.load(from: source)
        let nativeLosses: [VideoMetadataProperty] = container == .mov ? [] : [.descriptiveMetadata]
        #expect(metadata.losses(for: container, includingAudio: true) == nativeLosses)
        #expect(
            metadata.losses(for: .mkv, includingAudio: true)
                == [.descriptiveMetadata, .trackMetadata, .language, .volume])
        let outputURL = folder.appending(path: "output.\(container.fileExtension)")
        let plan = TranscodePlan(container: container, video: .copy, audio: .copy)
        try await Transcoder.run(source, plan: plan, to: outputURL) { _ in }
        let output = AVURLAsset(url: outputURL)
        try await assertMetadata(
            in: output, location: container == .mov ? Self.location : Self.normalizedLocation)
        let writtenLosses = try await metadata.losses(in: outputURL, container: container, includingAudio: true)
        #expect(writtenLosses == nativeLosses)
    }

    @Test func detectsMetadataMissingFromWrittenMovie() async throws {
        let folder = try folder()
        let sourceURL = try await source(in: folder, disabledAudio: true)
        let source = try await MediaInput.open(sourceURL)
        let metadata = try await VideoMetadata.load(from: source)
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let fixture = try await MediaInput.open(fixtureURL)
        var plan = TranscodePlan(container: .mov, video: .copy, audio: .copy)
        plan.metadata = try await VideoMetadata.load(from: fixture)
        let outputURL = folder.appending(path: "missing-metadata.mov")
        try await Transcoder.run(source, plan: plan, to: outputURL) { _ in }
        #expect(
            try await metadata.losses(in: outputURL, container: .mov, includingAudio: true)
                == [.descriptiveMetadata, .trackMetadata, .language, .volume, .enabledState])
    }

    @Test func omittedAlternateAudioGroupIsDetected() async throws {
        let sourceURL = try await source(in: folder(), withAlternateAudio: true)
        let source = try await MediaInput.open(sourceURL)
        #expect(source.hasMultipleTracks)
        let asset = AVURLAsset(url: sourceURL)
        #expect(try await asset.load(.trackGroups).contains { $0.trackIDs.count == 2 })
        let metadata = try await VideoMetadata.load(from: source)
        #expect(metadata.losses(for: .mov, includingAudio: true) == [.alternateGroups])
    }

    @Test(arguments: [OutputContainer.mov, .mp4, .m4v])
    func disabledAudioRemainsDisabled(container: OutputContainer) async throws {
        let folder = try folder()
        let sourceURL = try await source(in: folder, disabledAudio: true)
        let source = try await MediaInput.open(sourceURL)
        let metadata = try await VideoMetadata.load(from: source)
        #expect(metadata.losses(for: .mkv, includingAudio: true).contains(.enabledState))
        let outputURL = folder.appending(path: "disabled.\(container.fileExtension)")
        try await Transcoder.run(
            source, plan: TranscodePlan(container: container, video: .copy, audio: .copy), to: outputURL
        ) { _ in }
        let audio = try #require(try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio).first)
        #expect(try await audio.load(.isEnabled) == false)
    }

    @Test func matroskaLanguageSurvivesRebuiltTrack() async throws {
        let folder = try folder()
        let sourceURL = folder.appending(path: "language-source.mkv")
        var sourceTrack = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .vp9)
        sourceTrack.language = "jpn"
        var sourceMuxer = try MatroskaMuxer(url: sourceURL, tracks: [sourceTrack], webm: false)
        let packet = MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data([1]))
        try sourceMuxer.write(packet)
        try sourceMuxer.finish()
        let source = try await MediaInput.open(sourceURL)
        let metadata = try await VideoMetadata.load(from: source)
        #expect(metadata.losses(for: .mkv, includingAudio: false).isEmpty)
        var rebuiltTrack = sourceTrack
        rebuiltTrack.language = nil
        var outputs = [OutputTrack(track: rebuiltTrack, format: nil)]
        _ = metadata.apply(to: &outputs, container: .mkv)
        let outputURL = folder.appending(path: "language-output.mkv")
        var sink = try Sinks.make(.mkv, url: outputURL, tracks: outputs, transform: .identity)
        try await sink.write(packet)
        try await sink.finish()
        let output = try MatroskaDemuxer(url: outputURL)
        #expect(output.tracks.first?.language == "jpn")
    }

    private func source(
        in folder: URL, withAlternateAudio: Bool = false, disabledAudio: Bool = false
    ) async throws -> URL {
        let sourceURL = folder.appending(path: "source.mov")
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let fixture = AVURLAsset(url: fixtureURL)
        let videoTrack = try #require(try await fixture.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await fixture.loadTracks(withMediaType: .audio).first)
        let videoFormat = try #require(try await videoTrack.load(.formatDescriptions).first)
        let audioFormat = try #require(try await audioTrack.load(.formatDescriptions).first)
        let reader = try AVAssetReader(asset: fixture)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        for output in [videoOutput, audioOutput] {
            guard reader.canAdd(output) else { throw EngineError.decodeFailed("metadata fixture read") }
            reader.add(output)
        }
        guard reader.startReading() else {
            throw reader.error ?? EngineError.decodeFailed("metadata fixture start")
        }
        let writer = try AVAssetWriter(outputURL: sourceURL, fileType: .mov)
        writer.metadata = [
            metadataItem(.commonIdentifierTitle, Self.title),
            metadataItem(.commonIdentifierDescription, Self.description),
            metadataItem(.quickTimeMetadataLocationISO6709, Self.location),
            metadataItem(.commonIdentifierCreationDate, Self.creationDate),
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        videoInput.metadata = [metadataItem(.commonIdentifierTitle, Self.videoTitle)]
        videoInput.languageCode = "eng"
        videoInput.extendedLanguageTag = "en"
        videoInput.preferredVolume = Self.videoVolume
        audioInput.metadata = [metadataItem(.commonIdentifierTitle, Self.trackTitle)]
        audioInput.languageCode = "jpn"
        audioInput.extendedLanguageTag = "ja"
        audioInput.preferredVolume = Self.audioVolume
        audioInput.marksOutputTrackAsEnabled = !disabledAudio
        let alternateInput =
            withAlternateAudio
            ? AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat) : nil
        alternateInput?.languageCode = "eng"
        for input in [videoInput, audioInput, alternateInput].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw EngineError.encodeFailed("metadata fixture track") }
            writer.add(input)
        }
        if let alternateInput {
            let group = AVAssetWriterInputGroup(inputs: [audioInput, alternateInput], defaultInput: audioInput)
            guard writer.canAdd(group) else { throw EngineError.encodeFailed("metadata fixture group") }
            writer.add(group)
        }
        guard writer.startWriting() else {
            throw writer.error ?? EngineError.encodeFailed("metadata fixture writer start")
        }
        writer.startSession(atSourceTime: .zero)
        var nextVideo = await videoOutput.nextSample()
        var nextAudio = await audioOutput.nextSample()
        let deadline = ContinuousClock.now.advanced(by: Self.readinessTimeout)
        while nextVideo != nil || nextAudio != nil {
            let nextIsVideo: Bool
            if let nextVideo, let nextAudio {
                nextIsVideo = CMTimeCompare(nextVideo.presentationTimeStamp, nextAudio.presentationTimeStamp) <= 0
            } else {
                nextIsVideo = nextAudio == nil
            }
            let input = nextIsVideo ? videoInput : audioInput
            guard
                input.isReadyForMoreMediaData
                    && (nextIsVideo || (alternateInput?.isReadyForMoreMediaData ?? true))
            else {
                guard ContinuousClock.now < deadline else {
                    throw EngineError.encodeFailed("metadata fixture writer stalled")
                }
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            let sample = try #require(nextIsVideo ? nextVideo : nextAudio)
            guard input.append(sample) else {
                throw writer.error ?? EngineError.encodeFailed("metadata fixture append")
            }
            if !nextIsVideo, let alternateInput, !alternateInput.append(sample) {
                throw writer.error ?? EngineError.encodeFailed("metadata fixture alternate append")
            }
            if nextIsVideo {
                nextVideo = await videoOutput.nextSample()
            } else {
                nextAudio = await audioOutput.nextSample()
            }
        }
        guard reader.status != .failed else {
            throw reader.error ?? EngineError.decodeFailed("metadata fixture read failed")
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        alternateInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? EngineError.encodeFailed("metadata fixture finish")
        }
        try await assertMetadata(in: AVURLAsset(url: sourceURL))
        return sourceURL
    }

    private func assertMetadata(in asset: AVURLAsset, location: String = Self.location) async throws {
        let metadata = try await asset.load(.metadata)
        let metadataValues = try await values(metadata)
        #expect(try await contains(metadata, value: Self.title))
        #expect(try await contains(metadata, value: Self.description))
        #expect(metadataValues.contains(location), "Available values: \(metadataValues)")
        #expect(try await contains(metadata, value: Self.creationDate))
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await contains(video.load(.metadata), value: Self.videoTitle))
        #expect(try await video.load(.languageCode) == "eng")
        #expect(try await video.load(.extendedLanguageTag) == "en")
        #expect(try await video.load(.preferredVolume) == Self.videoVolume)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(try await contains(audio.load(.metadata), value: Self.trackTitle))
        #expect(try await audio.load(.languageCode) == "jpn")
        #expect(try await audio.load(.extendedLanguageTag) == "ja")
        #expect(try await audio.load(.preferredVolume) == Self.audioVolume)
    }

    private func contains(_ metadata: [AVMetadataItem], value: String) async throws -> Bool {
        for entry in metadata {
            if try await entry.load(.stringValue) == value { return true }
        }
        return false
    }

    private func values(_ metadata: [AVMetadataItem]) async throws -> [String] {
        var values: [String] = []
        for entry in metadata {
            if let value = try await entry.load(.stringValue) { values.append(value) }
        }
        return values
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "VideoMetadata-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let entry = AVMutableMetadataItem()
        entry.identifier = identifier
        entry.value = value as NSString
        return entry
    }
}
