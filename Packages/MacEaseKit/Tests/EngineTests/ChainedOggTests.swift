import Foundation
import MenuCatalog
import Testing

@testable import Engine
@testable import Formats

@Suite struct ChainedOggTests {
    @Test(arguments: [Settings.OutputMode.replace, .newFile])
    func rejectsMultiplexedStreamBeforeWriting(mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.ogg")
        let second = folder.appending(path: "second.ogg")
        let samples = AudioSignals.music(seconds: 0.5, sampleRate: 48_000)
        try await AudioSignals.write(samples, to: first, format: .ogg, sampleRate: 48_000)
        let firstBytes = try Data(contentsOf: first)
        var secondBytes = Data()
        repeat {
            try await AudioSignals.write(samples, to: second, format: .ogg, sampleRate: 48_000)
            secondBytes = try Data(contentsOf: second)
            if firstBytes[14..<18] == secondBytes[14..<18] { try FileManager.default.removeItem(at: second) }
        } while firstBytes[14..<18] == secondBytes[14..<18]
        let headerBytes = 27
        let segmentCount = Int(firstBytes[26])
        let firstPageBytes =
            headerBytes + segmentCount
            + firstBytes[headerBytes..<(headerBytes + segmentCount)].reduce(0) {
                $0 + Int($1)
            }
        let mixed = folder.appending(path: "mixed.ogg")
        let original = firstBytes.prefix(firstPageBytes) + secondBytes + firstBytes.dropFirst(firstPageBytes)
        try original.write(to: mixed)
        let support = folder.appending(path: "support", directoryHint: .isDirectory)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        var settings = Settings()
        settings.outputMode = mode
        let request = OperationRequest(
            op: .audioConvert, options: .audio(.convert(.wav)), inputs: [mixed])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.audio])))])
        #expect(try Data(contentsOf: mixed) == original)
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "mixed.wav").path))

        let mismatched = OperationRequest(
            op: .audioConvert, options: .audio(.convert(.wav)), inputs: [mixed], omittedStreams: [.data])
        let mismatchedOutcome = await engine.run(
            OperationPlanner.batch(for: mismatched, settings: settings), settings: settings
        ) { _ in }
        #expect(mismatchedOutcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.audio])))])
        #expect(try Data(contentsOf: mixed) == original)

        let consented = OperationRequest(
            op: .audioConvert, options: .audio(.convert(.wav)), inputs: [mixed], omittedStreams: [.audio])
        let consentedOutcome = await engine.run(
            OperationPlanner.batch(for: consented, settings: settings), settings: settings
        ) { _ in }
        guard case .succeeded(let outputs, let warnings) = consentedOutcome.outcomes.first else {
            Issue.record("expected consented Ogg conversion to succeed, got \(consentedOutcome.outcomes)")
            return
        }
        #expect(outputs.first?.pathExtension == "wav")
        #expect(try !AudioSignals.decode(try #require(outputs.first)).samples.isEmpty)
        #expect(warnings == [.streamsOmitted([.audio])])
    }

    private static let identificationCases: [(Data, UnpreservedStream)] = [
        (Data([1]) + Data("vorbis".utf8), .audio),
        (Data("OpusHead".utf8), .audio),
        (Data([0x7F]) + Data("FLAC".utf8), .audio),
        (Data("Speex   ".utf8), .audio),
        (Data([0x80]) + Data("theora".utf8), .video),
        (Data("BBCD".utf8), .video),
        (Data("OVP80".utf8), .video),
        (Data("fishead\0".utf8), .data),
    ]

    @Test(arguments: identificationCases)
    func classifiesMultiplexedIdentificationHeaders(header: Data, expected: UnpreservedStream) async throws {
        let mixed = try await multiplexedOgg(headers: [header])
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: mixed.deletingLastPathComponent()),
            progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([expected]))) {
            try await AudioJob.run(.convert(.wav), on: mixed, context: context)
        }
        let probed = try AudioInput(url: mixed, allowsMultiplexedOgg: true)
        #expect(MediaInput.unpreservedStreams(from: probed.multiplexedOggStreams) == [expected])
    }

    @Test func mixedMultiplexedKindsRequireSeparateConsent() async throws {
        let mixed = try await multiplexedOgg(headers: [Data("OpusHead".utf8), Data("fishead\0".utf8)])
        let original = try Data(contentsOf: mixed)
        let folder = mixed.deletingLastPathComponent()
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        for consent: Set<UnpreservedStream> in [[], [.data], [.audio], [.audio, .data]] {
            let request = OperationRequest(
                op: .audioConvert, options: .audio(.convert(.wav)), inputs: [mixed], omittedStreams: consent)
            let outcome = await engine.run(
                OperationPlanner.batch(for: request, settings: Settings()), settings: Settings()
            ) { _ in }
            if consent == [.audio, .data] {
                guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first else {
                    Issue.record("expected conversion: \(outcome.outcomes)")
                    return
                }
                #expect(warnings == [.streamsOmitted([.audio, .data])])
                #expect(try !AudioSignals.decode(try #require(outputs.first)).samples.isEmpty)
            } else {
                let missing: [UnpreservedStream] = [.audio, .data].filter { !consent.contains($0) }
                #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams(missing)))])
                #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "mixed.wav").path))
            }
            #expect(try Data(contentsOf: mixed) == original)
        }
    }

    @Test(arguments: [AudioFormat.ogg, .opus], [false, true])
    func rejectsChainsBeforeWritingAndKeepsOriginal(format: AudioFormat, trims: Bool) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sampleRate = 48_000.0
        let samples = AudioSignals.music(seconds: 0.5, sampleRate: sampleRate)
        let first = folder.appending(path: "first.\(format.fileExtension)")
        let second = folder.appending(path: "second.\(format.fileExtension)")
        for fixture in [first, second] {
            try await AudioSignals.write(samples, to: fixture, format: format, sampleRate: sampleRate)
            #expect(try !AudioSignals.decode(fixture).samples.isEmpty)
        }
        let chained = folder.appending(path: "chained.\(format.fileExtension)")
        let original = try Data(contentsOf: first) + Data(contentsOf: second)
        try original.write(to: chained)
        let support = folder.appending(path: "support", directoryHint: .isDirectory)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let op: OperationID = trims ? .audioTrim : .audioConvert
        let operation: AudioOperation = trims ? .trim(start: 0, end: 0.1) : .convert(.wav)
        let request = OperationRequest(op: op, options: .audio(operation), inputs: [chained])

        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        {
            _ in
        }

        #expect(outcome.outcomes == [.failed(.invalidInput(.chainedStream))])
        #expect(try Data(contentsOf: chained) == original)
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "chained.wav").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == [
                    chained.lastPathComponent, first.lastPathComponent, second.lastPathComponent, "support",
                ].sorted())
    }
}
