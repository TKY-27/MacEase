import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized)
struct AudioEnhancementTests {
    private var repository: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func enhancement(directory: URL? = nil) throws -> AudioEnhancement {
        try AudioEnhancement(
            directory: directory ?? repository.appending(path: "Vendor/build/ai-audio"),
            tools: MediaDownloadTools(directory: repository.appending(path: "Vendor/build/media-tools/bin")))
    }

    private func execute(_ source: URL, mode: AudioEnhancementMode) async throws -> BatchOutcome {
        let engine = try JobEngine(
            supportDirectory: source.deletingLastPathComponent().appending(path: "support"), concurrency: 1)
        var settings = Settings()
        settings.outputMode = .replace
        return await engine.run(try enhancement().makeBatch(source: source, mode: mode), settings: settings) { _ in }
    }

    @Test func speechExportsMonoFloatWAVAndKeepsStereoOriginal() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "speech.wav")
        let seconds = 1.25
        try await AudioSignals.write(AudioSignals.music(seconds: seconds), to: source, format: .wav)
        let original = try Data(contentsOf: source)
        let outcome = try await execute(source, mode: .speech)
        guard case .succeeded(let outputs, _) = outcome.outcomes.first else {
            Issue.record("Speech enhancement failed: \(outcome.outcomes)")
            return
        }
        let output = try #require(outputs.first)
        #expect(outputs.count == 1)
        #expect(output != source)
        #expect(try Data(contentsOf: source) == original)
        let (input, samples) = try AudioSignals.decode(output)
        #expect(input.channels == 1)
        #expect(input.sampleRate == 16_000)
        #expect(input.isFloat && input.bitDepth == 32)
        #expect(samples.count == 20_000)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples.contains { abs($0) > 0.0001 })
        #expect(outcome.record != nil)
    }

    @Test func separationRetainsBothStereoStemsWithCorrectTimingAndPitch() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "music.wav")
        let seconds = 12.25
        try await AudioSignals.write(AudioSignals.music(seconds: seconds), to: source, format: .wav)
        let original = try Data(contentsOf: source)
        let outcome = try await execute(source, mode: .stems)
        guard case .succeeded(let outputs, _) = outcome.outcomes.first else {
            Issue.record("Source separation failed: \(outcome.outcomes)")
            return
        }
        #expect(outputs.count == 2)
        #expect(Set(outputs.map(\.lastPathComponent)) == ["music-vocals.wav", "music-instrumental.wav"])
        #expect(try Data(contentsOf: source) == original)
        var stems: [[Float]] = []
        for output in outputs {
            let (input, samples) = try AudioSignals.decode(output)
            #expect(input.sampleRate == 44_100)
            #expect(input.channels == 2)
            #expect(input.isFloat && input.bitDepth == 32)
            #expect(samples.count == 1_080_450)
            #expect(samples.allSatisfy { $0.isFinite })
            stems.append(samples)
        }
        guard stems.count == 2, stems[0].count == stems[1].count else { return }
        let mixture = zip(stems[0], stems[1]).map(+)
        for (channel, frequency) in [(0, 220.0), (1, 277.18)] {
            let samples = stride(from: channel, to: mixture.count, by: 2).map { mixture[$0] }
            let start = 44_100
            let count = 44_100
            let energy = spectralEnergy(samples, frequency: frequency, start: start, count: count)
            let shifted = spectralEnergy(samples, frequency: frequency * 41_000 / 44_100, start: start, count: count)
            #expect(energy > shifted * 10)
        }
    }

    @Test(arguments: [AudioEnhancementMode.speech, .stems])
    func overDurationLimitFailsBeforeInferenceAndLeavesNoOutputs(mode: AudioEnhancementMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "long.wav")
        try sparseWave(at: source, seconds: mode.maximumDuration + 0.25)
        let original = try FileStamp(of: source, includingIdentity: true)
        let outcome = try await execute(source, mode: mode)
        #expect(outcome.outcomes == [.failed(.invalidInput(.tooLong(limitSeconds: mode.maximumDuration)))])
        #expect(try FileStamp(of: source, includingIdentity: true) == original)
        #expect(outcome.record == nil)
        let waves = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        #expect(waves.map { $0.resolvingSymlinksInPath() } == [source.resolvingSymlinksInPath()])
    }

    @Test func cancellingNativeInferenceRemovesStagingAndRetainsOriginal() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "cancel.wav")
        try await AudioSignals.write(AudioSignals.music(seconds: 30), to: source, format: .wav)
        let original = try Data(contentsOf: source)
        let support = folder.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = try enhancement().makeBatch(source: source, mode: .stems)
        let running = Mutex<Task<BatchOutcome, Never>?>(nil)
        let reachedInference = Mutex(false)
        let task = Task {
            await engine.run(batch, settings: Settings()) { progress in
                if progress.itemPhases.contains(.optimizing) {
                    reachedInference.withLock { $0 = true }
                    running.withLock { $0?.cancel() }
                }
            }
        }
        running.withLock { $0 = task }
        let outcome = await task.value
        #expect(reachedInference.withLock { $0 })
        #expect(outcome.wasCancelled)
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: source) == original)
        let registry = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: support.appending(path: "staging.json")))
        #expect(registry.isEmpty)
        let waves = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        #expect(waves.map { $0.resolvingSymlinksInPath() } == [source.resolvingSymlinksInPath()])
    }

    @Test func unavailableModelFailsExplicitly() throws {
        let folder = try AudioSignals.temporaryFolder()
        let missing = try enhancement(directory: folder)
        #expect(throws: EngineError.unsupportedCodec("Install the bundled audio AI runtime")) {
            try missing.makeBatch(source: folder.appending(path: "speech.wav"), mode: .speech)
        }
    }

    private func spectralEnergy(_ samples: [Float], frequency: Double, start: Int, count: Int) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / 44_100
            real += Double(samples[start + index]) * cos(phase)
            imaginary += Double(samples[start + index]) * sin(phase)
        }
        return real * real + imaginary * imaginary
    }

    private func sparseWave(at url: URL, seconds: Double) throws {
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            var encoded = value.littleEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }
        let rate: UInt32 = 16_000
        let bytes = UInt32((seconds * Double(rate)).rounded()) * 2
        var header = Data("RIFF".utf8) + little(bytes + 36) + Data("WAVEfmt ".utf8)
        header += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1))
        header += little(rate) + little(rate * 2) + little(UInt16(2)) + little(UInt16(16))
        header += Data("data".utf8) + little(bytes)
        try header.write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.truncate(atOffset: UInt64(bytes) + 44)
    }
}
