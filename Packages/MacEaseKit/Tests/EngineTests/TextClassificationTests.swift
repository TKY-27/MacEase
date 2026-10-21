import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct TextClassificationTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MacEaseTextInput-\(UUID().uuidString)")
        TestTemporaryFolders.register(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func convert(_ conversion: TextConversion, source: URL) async throws -> BatchOutcome {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseTextSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let settings = Settings()
        let request = OperationRequest(op: .textConvert, options: .text(.convert(conversion)), inputs: [source])
        return await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) { _ in }
    }

    @Test func genericTextDerivesDecodedTXTWithoutChangingSource() async throws {
        let folder = try folder()
        let source = folder.appending(path: "sample.swift")
        let content = "let greeting = \"é\"\r\n"
        let original = Data([0xFF, 0xFE] + content.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        try original.write(to: source)

        let outcome = try await convert(.toTXT, source: source)
        let derived = folder.appending(path: "sample.txt")

        #expect(outcome.outcomes == [.succeeded(outputs: [derived], warnings: [])])
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: derived) == Data(content.utf8))
    }

    @Test func structuralConversionRejectsOtherTextFormats() async throws {
        let folder = try folder()
        let source = folder.appending(path: "records.swift")
        try Data("name\nAlice\n".utf8).write(to: source)

        let outcome = try await convert(.csvToJSON, source: source)

        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(try String(contentsOf: source, encoding: .utf8) == "name\nAlice\n")
    }

    @Test func textAliasDoesNotOfferRedundantTXTDerivation() async throws {
        let folder = try folder()
        let source = folder.appending(path: "note.text")
        try Data("message".utf8).write(to: source)

        let outcome = try await convert(.toTXT, source: source)

        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "note.txt").path))
    }
}
