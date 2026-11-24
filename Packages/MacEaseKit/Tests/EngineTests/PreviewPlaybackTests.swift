import AVFoundation
import Foundation
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
            _ = try await VideoEditorSource.open(url, staging: staging, omittedStreams: Set(UnpreservedStream.allCases))
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ value: Double) { lock.withLock { recorded.append(value) } }

    var values: [Double] { lock.withLock { recorded } }
}
