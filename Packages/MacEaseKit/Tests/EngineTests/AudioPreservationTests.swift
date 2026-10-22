import AVFoundation
import Formats
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct AudioPreservationTests {
    @Test(arguments: [AudioFormat.wav, .aiff, .aac, .cafPCM, .cafALAC])
    func replacementRefusesTagLossBeforeStaging(format: AudioFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "tagged.flac")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2), to: source, format: .flac,
            tags: AudioTags(title: "Song", artist: "Artist", album: "Album", artwork: AudioSignals.pngArtwork()))
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        await #expect(throws: EngineError.audioMetadataUnsupported) {
            try await AudioJob.run(.convert(format), on: source, context: context)
        }

        #expect(context.warnings.isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
    }

    @Test func newFileTagLossWarnsAndCommitsDerivedOutput() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "tagged.flac")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2), to: source, format: .flac, tags: AudioTags(title: "Song"))
        let original = try Data(contentsOf: source)
        let settings = Settings()
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(op: .audioConvert, options: .audio(.convert(.wav)), inputs: [source])

        let outcome = await engine.run(
            OperationPlanner.batch(for: request, settings: settings), settings: settings
        ) { _ in }

        let output = folder.appending(path: "tagged.wav")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [.metadataDropped])])
        #expect(try Data(contentsOf: source) == original)
        #expect(try !AudioSignals.decode(output).samples.isEmpty)
        let record = try #require(outcome.record)
        guard case .derived(let path, _) = record.items.first else {
            Issue.record("expected a derived history record")
            return
        }
        #expect(path == output.path)
    }

    @Test(arguments: [Settings.OutputMode.replace, .newFile])
    func unreadableTagsRespectOriginalRetention(mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "unreadable.flac")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2), to: source, format: .flac, tags: AudioTags(title: "Song"))
        var original = try Data(contentsOf: source)
        let commentStart = 4 + 4 + 34 + 4
        original.replaceSubrange(commentStart..<(commentStart + 4), with: [0xFF, 0xFF, 0xFF, 0xFF])
        try original.write(to: source)
        let input = try AudioInput(url: source)
        await #expect(throws: (any Error).self) { try await input.tags() }
        var settings = Settings()
        settings.outputMode = mode
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        if mode == .replace {
            await #expect(throws: EngineError.audioMetadataUnsupported) {
                try await AudioJob.run(.convert(.wav), on: source, context: context)
            }
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
        } else {
            let result = try await AudioJob.run(.convert(.wav), on: source, context: context)
            guard case .replace(_, let output) = result else {
                Issue.record("expected a staged audio output")
                return
            }
            #expect(try !AudioSignals.decode(output.url).samples.isEmpty)
            #expect(context.warnings == [.metadataDropped])
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: ["wav", "aiff", "caf"], [Settings.OutputMode.replace, .newFile])
    func integerPrecisionLossRefusesLosslessOutputBeforeStaging(suffix: String, mode: Settings.OutputMode) async throws
    {
        let folder = try AudioSignals.temporaryFolder()
        let source = try integerSource(in: folder, suffix: suffix)
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = mode
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let pcmTarget: AudioFormat = suffix == "aiff" ? .wav : .aiff
        for format in [pcmTarget, .flac, .m4aALAC, .cafALAC] {
            await #expect(
                throws: EngineError.unsupportedCodec(
                    "audio above 24-bit integer or 32-bit float precision to lossless output")
            ) {
                try await AudioJob.run(.convert(format), on: source, context: context)
            }
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
    }

    @Test(arguments: [AudioOperation.trim(start: 0.1, end: 0.5), .normalize(targetLoudness: -23)])
    func integerPrecisionLossRefusesLosslessEdits(operation: AudioOperation) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = try integerSource(in: folder, suffix: "wav")
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(
            throws: EngineError.unsupportedCodec(
                "audio above 24-bit integer or 32-bit float precision to lossless output")
        ) {
            try await AudioJob.run(operation, on: source, context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
    }

    @Test(arguments: [AudioFormat.mp3, .m4aAAC, .aac, .opus, .ogg])
    func integerSourcesStillConvertToLossyOutput(format: AudioFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = try integerSource(in: folder, suffix: "wav")
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await AudioJob.run(.convert(format), on: source, context: context)
        guard case .replace(_, let output) = result else {
            Issue.record("expected a staged lossy output")
            return
        }
        #expect(try !AudioSignals.decode(output.url).samples.isEmpty)
    }

    @Test(
        arguments: [
            AudioOperation.convert(.cafPCM), .convert(.aiff), .convert(.flac), .convert(.m4aALAC), .convert(.cafALAC),
            .trim(start: 0.1, end: 0.5), .normalize(targetLoudness: -23),
        ], [Settings.OutputMode.replace, .newFile])
    func floatPrecisionLossRefusesLosslessOutputBeforeStaging(
        operation: AudioOperation, mode: Settings.OutputMode
    ) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = try floatSource(in: folder)
        let original = try Data(contentsOf: source)
        let input = try AudioInput(url: source)
        #expect(input.bitDepth == 64 && input.isFloat)
        #expect(try await input.tags().isEmpty)
        #expect(try input.open().read()?.first == 0.5)
        var settings = Settings()
        settings.outputMode = mode
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        await #expect(
            throws: EngineError.unsupportedCodec(
                "audio above 24-bit integer or 32-bit float precision to lossless output")
        ) {
            try await AudioJob.run(operation, on: source, context: context)
        }

        #expect(context.warnings.isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
    }

    @Test(arguments: [AudioFormat.mp3, .m4aAAC, .aac, .opus, .ogg])
    func floatSourcesStillConvertToLossyOutput(format: AudioFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        let source = try floatSource(in: folder)
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        let result = try await AudioJob.run(.convert(format), on: source, context: context)

        guard case .replace(_, let output) = result else {
            Issue.record("expected a staged lossy output")
            return
        }
        #expect(try !AudioSignals.decode(output.url).samples.isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    private func floatSource(in folder: URL) throws -> URL {
        func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
            var encoded = value.littleEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }
        let source = folder.appending(path: "precise.wav")
        let sampleRate: UInt32 = 48_000
        let frameCount = Int(sampleRate)
        let sample = 0.5000000009313226
        #expect(Double(Float(sample)) != sample)
        let bytesPerSample = MemoryLayout<Double>.size
        let formatChunkSize: UInt32 = 16
        let riffHeaderSize: UInt32 = 36
        let payloadSize = UInt32(frameCount * bytesPerSample)
        var wave = Data("RIFF".utf8)
        wave.append(littleEndian(riffHeaderSize + payloadSize))
        wave.append(Data("WAVEfmt ".utf8))
        wave.append(littleEndian(formatChunkSize))
        let ieeeFloatEncoding: UInt16 = 3
        wave.append(littleEndian(ieeeFloatEncoding))
        wave.append(littleEndian(UInt16(1)))
        wave.append(littleEndian(sampleRate))
        wave.append(littleEndian(sampleRate * UInt32(bytesPerSample)))
        wave.append(littleEndian(UInt16(bytesPerSample)))
        wave.append(littleEndian(UInt16(UInt64.bitWidth)))
        wave.append(Data("data".utf8))
        wave.append(littleEndian(payloadSize))
        let period = 96
        for index in 0..<frameCount {
            wave.append(littleEndian((index % period < period / 2 ? sample : -sample).bitPattern))
        }
        try wave.write(to: source)
        return source
    }

    private func integerSource(in folder: URL, suffix: String) throws -> URL {
        let source = folder.appending(path: "precise.\(suffix)")
        let frameCount: AVAudioFrameCount = 48_000
        let sample: Int32 = 1_073_741_825
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: suffix == "aiff",
        ]
        let file = try AVAudioFile(
            forWriting: source, settings: settings, commonFormat: .pcmFormatInt32, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
        let samples = try #require(buffer.int32ChannelData?[0])
        for index in 0..<Int(frameCount) { samples[index] = index % 96 < 48 ? sample : -sample }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        file.close()
        let native = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt32, interleaved: true)
        try native.read(into: buffer)
        #expect(buffer.int32ChannelData?[0][0] == sample)
        let input = try AudioInput(url: source)
        #expect(input.bitDepth == 32 && !input.isFloat)
        return source
    }
}
