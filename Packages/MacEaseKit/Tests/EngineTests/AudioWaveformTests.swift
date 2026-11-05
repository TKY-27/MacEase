import Foundation
import Testing

@testable import Engine

@Suite struct AudioWaveformTests {
    @Test func peaksKeepQuietIntervalsAndBothChannels() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let url = folder.appending(path: "wave.wav")
        let rate = 48_000.0
        var samples = [Float](repeating: 0, count: 96_000)
        samples[12_000 * 2] = 0.75
        samples[36_000 * 2 + 1] = -0.5
        try await AudioSignals.write(samples, to: url, format: .wav, sampleRate: rate)
        let summary = try await AudioWaveform.load(url: url, bins: 4)
        #expect(summary.sampleRate == rate)
        #expect(summary.duration == 1)
        #expect(summary.peaks == [0, 0.75, 0, 0.5])
        let detail = try await AudioWaveform.load(url: url, range: 0.5..<1, bins: 2)
        #expect(detail.start == 0.5)
        #expect(detail.peaks == [0, 0.5])
    }

    @Test func previewSourceRefusesChangedOriginal() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let url = folder.appending(path: "wave.wav")
        try await AudioSignals.write(AudioSignals.music(), to: url, format: .wav)
        let preview = try await AudioPreviewSource.open(url, staging: StagingArea(supportDirectory: folder))
        #expect(try await preview.playbackURL() == url)
        try Data([0]).write(to: url)
        await #expect(throws: EngineError.self) { try await preview.playbackURL() }
        await preview.close()
    }
}
