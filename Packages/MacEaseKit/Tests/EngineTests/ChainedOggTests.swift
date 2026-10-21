import Formats
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct ChainedOggTests {
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
