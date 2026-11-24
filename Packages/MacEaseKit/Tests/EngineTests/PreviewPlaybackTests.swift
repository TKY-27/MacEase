import AVFoundation
import Foundation
import MenuCatalog
import Testing

@testable import Engine
@testable import Formats

@Suite(.serialized) struct PreviewPlaybackTests {
    private func fixture() throws -> URL {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: "source.mp4")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    // Two Opus tracks; AVFoundation cannot play it.
    private func twoAudioTrackMatroska() async throws -> URL {
        let source = try fixture()
        let single = source.deletingLastPathComponent().appending(path: "single.mkv")
        let plan = TranscodePlan(container: .mkv, video: .copy, audio: .encode(.opus, kilobits: 96))
        try await Transcoder.run(try await MediaInput.open(source), plan: plan, to: single) { _ in }
        var demuxer = try #require(try await MediaInput.open(single).demuxer)
        let audio = try #require(demuxer.tracks.first { !$0.isVideo })
        var duplicate = audio
        duplicate.number = (demuxer.tracks.map(\.number).max() ?? 0) + 1
        let url = source.deletingLastPathComponent().appending(path: "two-audio.mkv")
        var muxer = try MatroskaMuxer(url: url, tracks: demuxer.tracks + [duplicate], webm: false)
        while let packet = try demuxer.nextPacket() {
            try muxer.write(packet)
            if packet.track == audio.number {
                var copy = packet
                copy.track = duplicate.number
                try muxer.write(copy)
            }
        }
        try muxer.finish()
        return url
    }

    @Test func previewPlaybackConvertsInputsTheEditorRefuses() async throws {
        let url = try await twoAudioTrackMatroska()
        let original = try Data(contentsOf: url)
        #expect(try await AVURLAsset(url: url).load(.isPlayable) == false)
        let support = try TestVolume.makeFolder()
        let staging = StagingArea(supportDirectory: support)

        await #expect(throws: EngineError.invalidInput(.multipleTracks)) {
            _ = try await VideoEditorSource.open(url, staging: staging)
        }

        let source = try await VideoEditorSource.openForPreviewPlayback(url, staging: staging)
        let progress = ProgressLog()
        let playback = try await source.playbackURL(sdr: false) { progress.record($0) }
        #expect(playback != url)
        let asset = AVURLAsset(url: playback)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(progress.values.allSatisfy { (0...1).contains($0) })
        #expect(progress.values.max() ?? 0 > 0.9)
        #expect(try Data(contentsOf: url) == original)

        await source.close()
        #expect(!FileManager.default.fileExists(atPath: playback.path))
    }

    @Test func editorStillRefusesWhatPreviewAccepts() async throws {
        let url = try await twoAudioTrackMatroska()
        let support = try TestVolume.makeFolder()
        let staging = StagingArea(supportDirectory: support)
        await #expect(throws: EngineError.invalidInput(.multipleTracks)) {
            _ = try await VideoEditorSource.open(
                url, staging: staging,
                omission: StreamOmission(
                    stamp: try MediaSourceStamp(url: url), streams: Set(UnpreservedStream.allCases)))
        }
    }

    // Mono PCM plus a cue chunk.
    private func waveWithCue() throws -> URL {
        let samples = Data(repeating: 0, count: 8_000)
        func little(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(value >> ($0 * 8) & 0xFF) }) }
        var format = Data("fmt ".utf8) + little(16, 4) + little(1, 2) + little(1, 2)
        format += little(8_000, 4) + little(16_000, 4) + little(2, 2) + little(16, 2)
        let cueBody = little(1, 4) + Data(repeating: 0, count: 8) + Data("data".utf8) + Data(repeating: 0, count: 12)
        let chunks =
            format + Data("data".utf8) + little(samples.count, 4) + samples
            + Data("cue ".utf8) + little(cueBody.count, 4) + cueBody
        let url = try TestVolume.makeFolder().appending(path: "marked.wav")
        try (Data("RIFF".utf8) + little(chunks.count + 4, 4) + Data("WAVE".utf8) + chunks).write(to: url)
        return url
    }

    @Test func audioPreviewPlaybackOpensWhatTrimsRefuse() async throws {
        let url = try waveWithCue()
        let staging = StagingArea(supportDirectory: try TestVolume.makeFolder())
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.data]))) {
            _ = try await AudioPreviewSource.open(url, staging: staging)
        }
        let source = try await AudioPreviewSource.openForPreviewPlayback(url, staging: staging)
        #expect(try await AVURLAsset(url: try await source.playbackURL()).load(.isPlayable))
        await source.close()
    }

    @Test func audioPreviewPlaybackUsesCompactAACInsteadOfFloatWAV() async throws {
        let folder = try TestVolume.makeFolder()
        let flac = folder.appending(path: "clip.flac")
        let rate = 48_000.0
        let channels = 2
        let frames = Int(rate * 2)
        var samples = [Float](repeating: 0, count: frames * channels)
        for index in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(index) / rate) * 0.25)
            samples[index * channels] = value
            samples[index * channels + 1] = value
        }
        let encoder = try AudioFileEncoder(
            url: flac, target: AudioTarget(format: .flac, kilobits: 0), sampleRate: rate, channels: channels,
            bitDepth: 16)
        try await encoder.write(samples)
        try await encoder.finish()

        let support = try TestVolume.makeFolder()
        let staging = StagingArea(supportDirectory: support)
        let source = try await AudioPreviewSource.openForPreviewPlayback(flac, staging: staging)
        let playback = try await source.playbackURL()
        #expect(playback.pathExtension == "m4a")
        #expect(try await AVURLAsset(url: playback).load(.isPlayable))
        let size = try #require(try playback.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let float32WAVBytes = frames * channels * 4
        #expect(size < float32WAVBytes / 4)
        await source.close()
        #expect(!FileManager.default.fileExists(atPath: playback.path))
    }

    @Test func externalMediaReferenceMovieIsRefusedAcrossEngineOperations() async throws {
        let folder = try TestVolume.makeFolder()
        let videoSource = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let secret = folder.appending(path: "secret.mp4")
        try FileManager.default.copyItem(at: videoSource, to: secret)
        let reference = folder.appending(path: "reference.mov")
        try Self.makeQuickTimeReferenceMovie(referencing: "secret.mp4").write(to: reference)

        // Control: unrestricted AVURLAsset resolves the sibling media.
        #expect(try await AVURLAsset(url: reference).load(.isPlayable))

        let support = try TestVolume.makeFolder()
        let staging = StagingArea(supportDirectory: support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        let settings = Settings()

        let operations: [(OperationID, OperationOptions)] = [
            (
                .videoConvert,
                try #require(OperationPlanner.options(for: .videoConvert, preset: "mp4", settings: settings))
            ),
            (
                .videoCompress,
                try #require(OperationPlanner.options(for: .videoCompress, preset: "mb-10", settings: settings))
            ),
            (.videoThumbnail, .video(.still(.first))),
            (.videoToGIF, .video(.gif(AnimationRendering(width: 320, framesPerSecond: 10)))),
        ]
        for (op, options) in operations {
            let batch = OperationPlanner.batch(
                for: OperationRequest(op: op, options: options, inputs: [reference]), settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            #expect(
                outcome.outcomes == [.failed(.invalidInput(.externalMediaReference))],
                "expected externalMediaReference for \(op)")
        }

        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await VideoEditorSource.open(reference, staging: staging)
        }
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await VideoEditorSource.openForPreviewPlayback(reference, staging: staging)
        }
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await AudioPreviewSource.open(reference, staging: staging)
        }
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await AudioPreviewSource.openForPreviewPlayback(reference, staging: staging)
        }
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await AudioWaveform.load(url: reference)
        }

        // Control: ordinary self-contained video still opens cleanly.
        let ordinary = try await VideoEditorSource.open(secret, staging: staging)
        #expect(await ordinary.details.duration > 0)
        await ordinary.close()
    }

    @Test func externalMediaReferenceMovieIsRefusedAcrossEditorTools() async throws {
        let folder = try TestVolume.makeFolder()
        let videoSource = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let secret = folder.appending(path: "secret.mp4")
        try FileManager.default.copyItem(at: videoSource, to: secret)
        let reference = folder.appending(path: "reference.mov")
        try Self.makeQuickTimeReferenceMovie(referencing: "secret.mp4").write(to: reference)

        let support = try TestVolume.makeFolder()
        let staging = StagingArea(supportDirectory: support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        let settings = Settings()

        let segment = VideoSegment(start: 0, end: 1)
        var reverseEdit = VideoEdit()
        reverseEdit.segments = [segment]
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await VideoSegmentReverser.reverse(
                segmentID: segment.id, in: reverseEdit, primaryURL: reference, staging: staging)
        }

        let frameBatch = MediaEditing.frame(
            url: reference, edit: VideoEdit(), outputSeconds: 0, settings: settings)
        let frameOutcome = await engine.run(frameBatch, settings: settings) { _ in }
        #expect(frameOutcome.outcomes == [.failed(.invalidInput(.externalMediaReference))])

        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await BackgroundMusic.load(from: reference)
        }

        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await AudioWaveform.levels(videoAt: reference)
        }
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await AudioWaveform.load(videoURL: reference)
        }

        let ordinary = try await VideoEditorSource.open(secret, staging: staging)
        let duration = await ordinary.details.duration
        var musicEdit = VideoEdit()
        musicEdit.segments = [VideoSegment(start: 0, end: duration)]
        musicEdit.music = BackgroundMusic(
            url: reference, stamp: try MediaSourceStamp(url: reference), duration: duration)
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await ordinary.playback(edit: musicEdit)
        }
        await ordinary.close()

        let musicExportBatch = MediaEditing.video(url: secret, edit: musicEdit, settings: settings)
        let musicExportOutcome = await engine.run(musicExportBatch, settings: settings) { _ in }
        #expect(musicExportOutcome.outcomes == [.failed(.invalidInput(.externalMediaReference))])
    }

    @Test func rejectExternalReferencesPropagatesNonReferenceErrors() async throws {
        let folder = try TestVolume.makeFolder()
        let missing = folder.appending(path: "missing.m4a")
        await #expect(throws: (any Error).self) {
            try await UntrustedMediaAsset.rejectExternalReferences(in: missing)
        }

        let unreadable = folder.appending(path: "unreadable.m4a")
        try Data("data".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        await #expect(throws: (any Error).self) {
            try await UntrustedMediaAsset.rejectExternalReferences(in: unreadable)
        }

        // Non-AVFoundation containers return false without throwing.
        let ogg = folder.appending(path: "sample.ogg")
        try Data("OggS\0\u{02}1234567890".utf8).write(to: ogg)
        try await UntrustedMediaAsset.rejectExternalReferences(in: ogg)
    }

    private static func makeQuickTimeReferenceMovie(referencing relativeTarget: String) -> Data {
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
        ftyp.append(contentsOf: [0x20, 0x05, 0x03, 0x00])
        ftyp.append(contentsOf: "qt  ".utf8)
        return atom("ftyp", ftyp) + moov
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ value: Double) { lock.withLock { recorded.append(value) } }

    var values: [Double] { lock.withLock { recorded } }
}
