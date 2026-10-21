import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct AudioContainerInterchangeTests {
    @Test func aifcPCMDecodesKnownSamples() throws {
        let source = try aifcPCMFixture()
        let (input, samples) = try AudioSignals.decode(source)
        #expect(input.container == .aiff && input.codec == .pcm)
        #expect(input.sampleRate == 48_000 && input.channels == 2)
        #expect(samples.count == 1_024)
        #expect(samples.first == -0.25)
        #expect(try ContentSniffer.matches(source, kind: .audio))
    }

    @Test func cafPCMStagesLosslessAIFCConversion() async throws {
        let source = try aifcPCMFixture()
        let original = try AudioSignals.decode(source).samples
        let folder = source.deletingLastPathComponent()
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await AudioJob.run(.convert(.cafPCM), on: source, context: context)
        guard case .replace(_, let output) = result else {
            Issue.record("expected staged CAF conversion")
            return
        }
        let (input, samples) = try AudioSignals.decode(output.url)
        #expect(input.container == .caf && input.codec == .pcm)
        #expect(samples == original)
    }

    @Test(arguments: [(AudioFormat.cafPCM, Engine.AudioCodec.pcm), (.cafALAC, .alac)])
    func convertsAIFCPCMThroughCAF(format: AudioFormat, codec: Engine.AudioCodec) async throws {
        let source = try aifcPCMFixture()
        let originalSamples = try AudioSignals.decode(source).samples
        var settings = Settings()
        settings.outputMode = .newFile
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .audioConvert, options: .audio(.convert(format)), inputs: [source]),
            settings: settings)

        let outcome = await engine.run(batch, settings: settings) { _ in }

        guard case .succeeded(let outputs, _) = outcome.outcomes.first else {
            Issue.record("AIFC conversion failed: \(outcome.outcomes)")
            return
        }
        let output = try #require(outputs.first)
        let (decoded, samples) = try AudioSignals.decode(output)
        #expect(decoded.container == .caf)
        #expect(decoded.codec == codec)
        #expect(samples == originalSamples)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func rejectsUnsupportedAIFCCodecBeforeCreatingOutput() async throws {
        let source = try aifcPCMFixture()
        var bytes = try Data(contentsOf: source)
        let common = try #require(bytes.range(of: Data("COMM".utf8))).lowerBound
        bytes.replaceSubrange((common + 26)..<(common + 30), with: Data("zzzz".utf8))
        try bytes.write(to: source)
        var settings = Settings()
        settings.outputMode = .newFile
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .audioConvert, options: .audio(.convert(.cafPCM)), inputs: [source]),
            settings: settings)

        let outcome = await engine.run(batch, settings: settings) { _ in }

        guard case .failed(.decodeFailed) = outcome.outcomes.first else {
            Issue.record("Unsupported AIFC must fail decoding: \(outcome.outcomes)")
            return
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(
            !FileManager.default.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("caf").path))
        #expect(outcome.record == nil)
    }

    private func aifcPCMFixture() throws -> URL {
        let url = try AudioSignals.temporaryFolder().appending(path: "tone.aifc")
        let frameCount = 512
        var samples = Data()
        for index in 0..<frameCount {
            let value = Int16(index * 32 - 8_192)
            samples.append(bigEndian(value))
            samples.append(bigEndian(value))
        }
        var chunks = Data("FVER".utf8)
        chunks.append(bigEndian(UInt32(4)))
        chunks.append(bigEndian(UInt32(0xA280_5140)))
        chunks.append(Data("COMM".utf8))
        chunks.append(bigEndian(UInt32(24)))
        chunks.append(bigEndian(UInt16(2)))
        chunks.append(bigEndian(UInt32(frameCount)))
        chunks.append(bigEndian(UInt16(16)))
        chunks.append(contentsOf: [0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])
        chunks.append(Data("NONE".utf8))
        chunks.append(contentsOf: [0, 0])
        chunks.append(Data("SSND".utf8))
        chunks.append(bigEndian(UInt32(samples.count + 8)))
        chunks.append(bigEndian(UInt32(0)))
        chunks.append(bigEndian(UInt32(0)))
        chunks.append(samples)
        var container = Data("FORM".utf8)
        container.append(bigEndian(UInt32(chunks.count + 4)))
        container.append(Data("AIFC".utf8))
        container.append(chunks)
        try container.write(to: url)
        return url
    }

    private func bigEndian<Integer: FixedWidthInteger>(_ value: Integer) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
