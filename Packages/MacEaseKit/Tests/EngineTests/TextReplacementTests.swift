import Foundation
import Testing

@testable import Engine

@Suite(.serialized)
struct TextReplacementTests {
    private func engine() throws -> JobEngine {
        let support = FileManager.default.temporaryDirectory.appending(path: "TextEditSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        return try JobEngine(supportDirectory: support, concurrency: 1)
    }

    private func original(_ bytes: Data) throws -> URL {
        let url = try TestVolume.makeFolder().appending(path: "note.txt")
        try bytes.write(to: url)
        return url
    }

    @Test(arguments: [
        Data([0x41, 0x0D, 0x0A]),
        Data([0xEF, 0xBB, 0xBF, 0x41, 0x0D, 0x0A]),
        Data([0xFF, 0xFE, 0x41, 0, 0x0D, 0, 0x0A, 0]),
        Data([0xFE, 0xFF, 0, 0x41, 0, 0x0D, 0, 0x0A]),
        Data([0x93, 0xFA, 0x96, 0x7B, 0x0D, 0x0A]),
    ])
    func preservesEncodingBOMAndCRLFAndUndoRestoresExactBytes(bytes: Data) async throws {
        let url = try original(bytes)
        let stamp = try FileStamp(of: url)
        let document = try TextEditDocument(bytes: bytes)
        #expect(document.lineEnding == "\r\n")
        let batch = TextReplacement.batch(
            original: url, stamp: stamp, text: document.text + "B\r\n", document: document)
        let engine = try engine()
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        #expect(outcome.outcomes == [.succeeded(outputs: [url], warnings: [])])
        let suffix: [UInt8]
        if bytes.starts(with: [0xFF, 0xFE]) {
            suffix = [0x42, 0, 0x0D, 0, 0x0A, 0]
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            suffix = [0, 0x42, 0, 0x0D, 0, 0x0A]
        } else {
            suffix = [0x42, 0x0D, 0x0A]
        }
        #expect(try Data(contentsOf: url) == bytes + Data(suffix))
        #expect(!outcome.historyFailed)
        _ = try await engine.undo(batch.id)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test(arguments: [true, false])
    func refusesIncompleteUTF16BeforeEditing(littleEndian: Bool) {
        let mark: [UInt8] = littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
        let body = Data(littleEndian ? [0x41, 0, 0xBC] : [0, 0x41, 0xBC])
        let encoding: String.Encoding = littleEndian ? .utf16LittleEndian : .utf16BigEndian
        let failure = EngineError.invalidInput(.textEncodingUndetected)
        #expect(throws: failure) { try TextEditDocument(bytes: Data(mark) + body) }
        #expect(throws: failure) { try TextEditDocument(bytes: body, encoding: encoding) }
    }

    @Test(arguments: [false, true])
    func refusesChangesAfterLoadingEvenBeforeJobStarts(changeDuringJob: Bool) async throws {
        let url = try original(Data("loaded".utf8))
        let stamp = try FileStamp(of: url)
        let document = try TextEditDocument(bytes: Data("loaded".utf8))
        let batch = TextReplacement.batch(original: url, stamp: stamp, text: "edited", document: document)
        let replacement = try #require(batch.items.first)
        let external = Data("external change".utf8)
        let work: WorkItem
        if changeDuringJob {
            var delayed = WorkItem(inputs: [url]) { context in
                let result = try await replacement.body(context)
                try external.write(to: url)
                return result
            }
            delayed.replacementInputStamps = replacement.replacementInputStamps
            work = delayed
        } else {
            try external.write(to: url)
            work = replacement
        }
        let outcome = await (try engine()).run(Batch(operation: .textEdit, items: [work]), settings: Settings()) { _ in
        }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: url) == external)
    }

    @Test func refusesUnrepresentableTextUntilUTF8IsExplicit() async throws {
        let bytes = Data([0x93, 0xFA, 0x96, 0x7B])
        let url = try original(bytes)
        let stamp = try FileStamp(of: url)
        let document = try TextEditDocument(bytes: bytes)
        let engine = try engine()
        let refused = await engine.run(
            TextReplacement.batch(original: url, stamp: stamp, text: "日本😀", document: document),
            settings: Settings()
        ) { _ in }
        #expect(refused.outcomes == [.failed(.invalidInput(.textEditUnrepresentable))])
        #expect(refused.record == nil)
        #expect(try Data(contentsOf: url) == bytes)
        let accepted = await engine.run(
            TextReplacement.batch(original: url, stamp: stamp, text: "日本😀", document: document, asUTF8: true),
            settings: Settings()
        ) { _ in }
        #expect(accepted.outcomes == [.succeeded(outputs: [url], warnings: [])])
        #expect(try Data(contentsOf: url) == Data("日本😀".utf8))
    }

    @Test func emptyBufferIsRefusedEvenWhenOriginalHasBOM() async throws {
        let bytes = Data([0xFF, 0xFE, 0x41, 0])
        let url = try original(bytes)
        let batch = TextReplacement.batch(
            original: url, stamp: try FileStamp(of: url), text: "", document: try TextEditDocument(bytes: bytes))
        let outcome = await (try engine()).run(batch, settings: Settings()) { _ in }
        #expect(outcome.outcomes == [.failed(.invalidInput(.emptyTextEdit))])
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func verifierRefusesDifferentDecodableStagedText() async throws {
        let url = try original(Data("other".utf8))
        let output = StagedFile(
            url: url, name: "note.txt", check: .textReplacement(encoding: .utf8, byteOrderMark: Data(), text: "buffer"))
        await #expect(throws: EngineError.encodeFailed("edited text did not round-trip")) {
            try await OutputVerifier.verify(output)
        }
    }
}
