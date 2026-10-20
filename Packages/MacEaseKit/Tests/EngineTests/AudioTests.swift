import AVFoundation
import Formats
import Foundation
import MenuCatalog
import Testing

@testable import Engine

private struct AudioRun {
    let outcome: BatchOutcome
    let folder: URL

    var output: URL? {
        guard case .succeeded(let outputs, _) = outcome.outcomes.first else { return nil }
        return outputs.first
    }

    var warnings: [ItemWarning] {
        guard case .succeeded(_, let warnings) = outcome.outcomes.first else { return [] }
        return warnings
    }
}

private func run(_ op: OperationID, _ operation: AudioOperation, on input: URL, settings: Settings = Settings())
    async throws -> AudioRun
{
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
    let engine = try JobEngine(supportDirectory: support, concurrency: 2)
    let batch = OperationPlanner.batch(
        for: OperationRequest(op: op, options: .audio(operation), inputs: [input]), settings: settings)
    let outcome = await engine.run(batch, settings: settings) { _ in }
    return AudioRun(outcome: outcome, folder: input.deletingLastPathComponent())
}

/// Originals must trash on the test volume.
private func source(
    _ name: String, format: AudioFormat, samples: [Float] = AudioSignals.music(), sampleRate: Double = 44_100,
    channels: Int = 2, kilobits: Int = 192, tags: AudioTags = AudioTags()
) async throws -> URL {
    let url = try TestVolume.makeFolder().appending(path: name)
    try await AudioSignals.write(
        samples, to: url, format: format, sampleRate: sampleRate, channels: channels, kilobits: kilobits, tags: tags)
    return url
}

private func measure(_ url: URL) throws -> LoudnessMeter {
    let (input, samples) = try AudioSignals.decode(url)
    let meter = try LoudnessMeter(sampleRate: input.sampleRate, channels: input.channels)
    meter.add(samples)
    return meter
}

private func tone(decibels: Double, seconds: Double = 6, rate: Double = 48_000) -> [Float] {
    let amplitude = pow(10, decibels / 20)
    return (0..<Int(seconds * rate)).flatMap { frame -> [Float] in
        let value = Float(amplitude * sin(2 * Double.pi * 1_000 * Double(frame) / rate))
        return [value, value]
    }
}

private func fileSize(_ url: URL) throws -> Int64 {
    Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
}

@Suite struct AudioPlanningTests {
    @Test func everyMenuPresetMaps() {
        let settings = Settings()
        let converts = OperationID.audioConvert.presets.compactMap {
            OperationPlanner.options(for: .audioConvert, preset: $0, settings: settings)
        }
        #expect(
            converts == [.mp3, .m4aAAC, .m4aALAC, .aac, .wav, .aiff, .flac, .ogg, .opus].map { .audio(.convert($0)) })
        let compressions = OperationID.audioCompress.presets.compactMap {
            OperationPlanner.options(for: .audioCompress, preset: $0, settings: settings)
        }
        #expect(compressions == [64, 96, 128, 192].map { .audio(.compress(.kilobits($0))) })
        let loudness = OperationID.audioNormalize.presets.compactMap {
            OperationPlanner.options(for: .audioNormalize, preset: $0, settings: settings)
        }
        #expect(loudness == [-14.0, -16, -23].map { .audio(.normalize(targetLoudness: $0)) })
    }

    @Test func panelsAndUnknownPresetsDefer() {
        let settings = Settings()
        #expect(OperationPlanner.options(for: .audioConvert, preset: nil, settings: settings) == nil)
        #expect(OperationPlanner.options(for: .audioConvert, preset: "caf-pcm", settings: settings) == nil)
        #expect(OperationPlanner.options(for: .audioTrim, preset: nil, settings: settings) == nil)
        #expect(OperationPlanner.options(for: .audioCompress, preset: "5", settings: settings) == nil)
    }

    @Test func targetSizePicksTheLargestFittingBitrate() {
        #expect(AudioTargetSize.kilobits(forBytes: 1_000_000, seconds: 60, supported: [64, 96, 128, 192]) == 128)
        #expect(AudioTargetSize.kilobits(forBytes: 100_000, seconds: 60, supported: [64, 96]) == nil)
    }
}

@Suite struct AudioConvertTests {
    @Test(arguments: AudioFormat.allCases.filter { !$0.rawValue.hasPrefix("caf") })
    func convertsFLACWithTags(format: AudioFormat) async throws {
        let tags = AudioTags(title: "Song", artist: "Band", album: "Record", artwork: AudioSignals.pngArtwork())
        let input = try await source("song.flac", format: .flac, tags: tags)
        guard format != .flac else {
            let result = try await run(.audioConvert, .convert(format), on: input)
            #expect(result.outcome.outcomes == [.skipped(.alreadyDone)])
            return
        }

        let result = try await run(.audioConvert, .convert(format), on: input)

        let output = try #require(result.output, "\(result.outcome.outcomes)")
        #expect(output.lastPathComponent == "song.\(format.fileExtension)")
        #expect(!FileManager.default.fileExists(atPath: input.path))
        let (decoded, samples) = try AudioSignals.decode(output)
        #expect(decoded.channels == 2)
        let seconds = Double(samples.count / 2) / decoded.sampleRate
        #expect(abs(seconds - 2) < 0.1)
        if format.holdsTags {
            #expect(try await decoded.tags() == tags)
        } else {
            #expect(result.warnings == [.metadataDropped])
        }
        let record = try #require(result.outcome.record)
        #expect(record.outputPaths == [output.path])
    }

    @Test func cafAACConvertsToM4A() async throws {
        let input = try TestVolume.makeFolder().appending(path: "memo.caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
        ]
        let file = try AVAudioFile(
            forWriting: input, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try PCMFormat.buffer(AudioSignals.music(), format: file.processingFormat)
        try file.write(from: buffer)
        file.close()

        let result = try await run(.audioConvert, .convert(.m4aAAC), on: input)

        let output = try #require(result.output, "\(result.outcome.outcomes)")
        #expect(output.lastPathComponent == "memo.m4a")
        #expect(try AudioInput(url: output).container == .mpeg4)
    }

    @Test func undoRestoresTheOriginal() async throws {
        let input = try await source("undo.wav", format: .wav)
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .audioConvert, options: .audio(.convert(.mp3)), inputs: [input]),
            settings: Settings())

        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        let record = try #require(outcome.record)
        #expect(try await engine.history.undo(record.id) == [.restored])

        #expect(FileManager.default.fileExists(atPath: input.path))
        #expect(
            !FileManager.default.fileExists(atPath: input.deletingPathExtension().appendingPathExtension("mp3").path))
    }

    @Test func wmaFailsWithTheCodecName() async throws {
        let input = try TestVolume.makeFolder().appending(path: "voice.mp3")
        try Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0, 0xAA, 0, 0x62, 0xCE, 0x6C]).write(
            to: input)

        let result = try await run(.audioConvert, .convert(.wav), on: input)

        #expect(result.outcome.outcomes == [.failed(.unsupportedCodec("Windows Media Audio"))])
        #expect(FileManager.default.fileExists(atPath: input.path))
    }
}

@Suite struct AudioCompressTests {
    @Test func losslessSourcesBecomeAACInM4A() async throws {
        let input = try await source("raw.wav", format: .wav)
        let result = try await run(.audioCompress, .compress(.kilobits(96)), on: input)

        let output = try #require(result.output)
        #expect(output.lastPathComponent == "raw.m4a")
        #expect(try AudioInput(url: output).codec == .aac)
    }

    @Test func lossySourcesKeepTheirFormat() async throws {
        let input = try await source("voice.opus", format: .opus, kilobits: 192)
        let result = try await run(.audioCompress, .compress(.kilobits(64)), on: input)

        let output = try #require(result.output)
        #expect(output.lastPathComponent == "voice.opus")
        #expect(try fileSize(output) < 2 * 64_000 / 8 * 12 / 10)
    }

    @Test func mp3BelowItsLowestBitrateBecomesAAC() async throws {
        let input = try await source("talk.mp3", format: .mp3, kilobits: 192)
        let result = try await run(.audioCompress, .compress(.kilobits(64)), on: input)

        #expect(try AudioInput(url: try #require(result.output)).codec == .aac)
    }

    @Test func largerOutputsAreSkipped() async throws {
        let input = try await source("small.ogg", format: .ogg, kilobits: 64)
        let result = try await run(.audioCompress, .compress(.kilobits(192)), on: input)

        #expect(result.outcome.outcomes == [.skipped(.outputNotSmaller)])
    }

    @Test(arguments: [(AudioFormat.wav, 128), (.opus, 96)])
    func targetSizeLandsWithinEightPercent(format: AudioFormat, nominalKilobits: Int) async throws {
        let seconds = 10.0
        let input = try await source(
            "long.\(format.fileExtension)", format: format, samples: AudioSignals.music(seconds: seconds),
            kilobits: 256)
        let target = Int64(Double(nominalKilobits) * 1_000 / 8 * seconds * 1.03)

        let result = try await run(.audioCompress, .compress(.targetBytes(target)), on: input)

        let size = try fileSize(try #require(result.output, "\(result.outcome.outcomes)"))
        #expect(size <= target)
        #expect(Double(size) >= 0.92 * Double(target), "\(size) of \(target)")
    }

    @Test func unreachableTargetsReportTheSmallestSize() async throws {
        let input = try await source("big.wav", format: .wav)
        let result = try await run(.audioCompress, .compress(.targetBytes(1_000)), on: input)

        guard case .failed(.targetUnreachable(let smallest)) = result.outcome.outcomes.first else {
            Issue.record("expected an unreachable target, got \(result.outcome.outcomes)")
            return
        }
        #expect(smallest > 1_000)
        #expect(FileManager.default.fileExists(atPath: input.path))
    }
}

@Suite struct AudioNormalizeTests {
    @Test(arguments: [AudioFormat.wav, .flac, .mp3, .opus])
    func reachesTheTargetLoudness(format: AudioFormat) async throws {
        let input = try await source(
            "quiet.\(format.fileExtension)", format: format, samples: tone(decibels: -30), sampleRate: 48_000,
            kilobits: 256)

        let result = try await run(.audioNormalize, .normalize(targetLoudness: -16), on: input)

        let output = try #require(result.output, "\(result.outcome.outcomes)")
        let loudness = try #require(try measure(output).integratedLoudness)
        #expect(abs(loudness + 16) <= (format.isLossy ? 0.3 : 0.1), "\(format): \(loudness)")
        #expect(result.warnings.isEmpty)
    }

    @Test func truePeakCapsTheGain() async throws {
        var samples = tone(decibels: -30)
        for index in stride(from: 0, to: samples.count, by: 24_000) { samples[index] = 0.5 }
        let input = try await source("peaky.wav", format: .wav, samples: samples, sampleRate: 48_000)
        let before = try measure(input)

        let result = try await run(.audioNormalize, .normalize(targetLoudness: -14), on: input)

        let after = try measure(try #require(result.output))
        let reached = try #require(after.integratedLoudness)
        #expect(after.truePeak <= -1 + 0.01)
        guard case .loudnessLimitedByPeak(let reported) = try #require(result.warnings.first) else {
            Issue.record("expected a peak warning, got \(result.warnings)")
            return
        }
        #expect(abs(reported - reached) <= 0.1)
        #expect(reached < -14)
        #expect(try #require(before.integratedLoudness) < reached)
    }

    @Test func silenceIsLeftAlone() async throws {
        let input = try await source("silence.wav", format: .wav, samples: [Float](repeating: 0, count: 88_200))
        let result = try await run(.audioNormalize, .normalize(targetLoudness: -14), on: input)
        #expect(result.outcome.outcomes == [.skipped(.alreadyDone)])
    }
}

@Suite struct AudioTrimTests {
    @Test(arguments: [AudioFormat.wav, .flac, .aiff, .m4aALAC])
    func losslessTrimIsSampleExact(format: AudioFormat) async throws {
        let quantized = AudioSignals.music().map { ($0 * 32_768).rounded() / 32_768 }
        let input = try await source("clip.\(format.fileExtension)", format: format, samples: quantized)

        let result = try await run(.audioTrim, .trim(start: 0.5, end: 1.25), on: input)

        let samples = try AudioSignals.decode(try #require(result.output)).samples
        #expect(samples == Array(quantized[22_050 * 2..<55_125 * 2]))
    }

    @Test(arguments: [AudioFormat.mp3, .m4aAAC, .ogg, .opus])
    func lossyTrimReencodesTheRange(format: AudioFormat) async throws {
        let input = try await source("clip.\(format.fileExtension)", format: format)

        let result = try await run(.audioTrim, .trim(start: 0.5, end: 1.25), on: input)

        let (decoded, samples) = try AudioSignals.decode(try #require(result.output))
        let seconds = Double(samples.count / decoded.channels) / decoded.sampleRate
        #expect(abs(seconds - 0.75) < (format == .mp3 ? 0.08 : 0.01), "\(format): \(seconds)")
    }

    @Test func emptyRangesFail() async throws {
        let input = try await source("clip.wav", format: .wav)
        let result = try await run(.audioTrim, .trim(start: 3, end: 4), on: input)
        #expect(result.outcome.outcomes == [.failed(.invalidInput(.malformed("the trim range is empty")))])
    }
}

@Suite struct AudioVerificationTests {
    @Test func undecodableAudioIsRejected() async throws {
        let original = try TestVolume.makeFolder().appending(path: "song.ogg")
        try Data("OggS but not really".utf8).write(to: original)
        let staged = try TestVolume.makeFolder().appending(path: "song.ogg")
        try Data("OggS garbage".utf8).write(to: staged)

        await #expect(throws: EngineError.self) {
            try await OutputVerifier.verify(StagedFile(url: staged, name: "song.ogg", check: .audio))
        }
    }
}
