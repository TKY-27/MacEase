import CoreGraphics
import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct SubtitleCodecReviewTests {
    @Test func singleTimedResultWrapsGraphemesAndDividesTime() throws {
        let spoken = String(repeating: "e\u{301}", count: 99) + "🙂"
        let cues = Subtitles.cues(from: [TimedWord(text: spoken, start: 2, end: 12)])

        #expect(cues.count == 2)
        #expect(cues.map(\.lines.count) == [2, 1])
        #expect(cues.flatMap(\.lines).map(\.count) == [42, 42, 16])
        #expect(cues.flatMap(\.lines).joined() == spoken)
        #expect(cues.first?.start == 2)
        #expect(abs(try #require(cues.first?.end) - 10.4) < 0.001)
        #expect(abs(try #require(cues.last?.start) - 10.4) < 0.001)
        #expect(cues.last?.end == 12)
    }

    @Test(arguments: [
        (MediaCodec.h264, VideoCodecChoice.hevc, VideoEncoding.Codec.h264),
        (.hevc, .h264, .hevc),
        (.vp9, .hevc, .hevc),
        (.vp9, .h264, .h264),
    ])
    func resizePlanPreservesSourceCodecOrUsesPreference(
        sourceCodec: MediaCodec, preference: VideoCodecChoice, expectedCodec: VideoEncoding.Codec
    ) throws {
        let source = MediaTrack(number: 1, kind: .video(width: 160, height: 96), codec: sourceCodec)
        let input = MediaInput(
            url: URL(fileURLWithPath: "source.mkv"), backend: .matroska, video: source, audio: nil,
            hasMultipleTracks: false, skippedStreams: [], duration: 2 * Nanoseconds.perSecond, transform: .identity)
        var settings = VideoSettings()
        settings.codec = preference

        let plan = try VideoEdits.plan(.resize(.percent(50)), input: input, source: source, settings: settings)
        guard case .encode(let encoding, _) = plan.video else {
            Issue.record("resize must encode video")
            return
        }
        #expect(encoding.codec == expectedCodec)
    }
}
