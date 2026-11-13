import Foundation
import Testing

@testable import Engine

@Suite(.serialized) struct FileProtectionTests {
    private let password = "correct horse battery staple"

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseProtection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        TestTemporaryFolders.register(folder)
        return folder
    }

    private func protection() throws -> FileProtection {
        let build = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Vendor/build")
            .standardizedFileURL
        return try FileProtection(
            helperURL: build.appending(path: "macease-age"),
            tools: try MediaDownloadTools(directory: build.appending(path: "media-tools/bin")))
    }

    @Test func encryptAndDecryptKeepSourceAndRecordDerivedOutputs() async throws {
        let root = try makeFolder()
        let source = root.appending(path: "sample.txt")
        let payload = Data(String(repeating: "private content\n", count: 2_000).utf8)
        try payload.write(to: source)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let protection = try protection()

        let encrypted = await engine.run(
            try protection.batch(source: source, password: password, decrypt: false), settings: Settings()
        ) { _ in }
        guard case .succeeded(let encryptedURLs, _) = try #require(encrypted.outcomes.first),
            let cipher = encryptedURLs.first
        else {
            Issue.record("encryption failed: \(encrypted.outcomes)")
            return
        }
        #expect(cipher.lastPathComponent == "sample.txt.age")
        #expect(try Data(contentsOf: source) == payload)
        #expect(try Data(contentsOf: cipher) != payload)
        #expect(encrypted.record?.items.count == 1)

        let decrypted = await engine.run(
            try protection.batch(source: cipher, password: password, decrypt: true), settings: Settings()
        ) { _ in }
        guard case .succeeded(let decryptedURLs, _) = try #require(decrypted.outcomes.first),
            let restored = decryptedURLs.first
        else {
            Issue.record("decryption failed")
            return
        }
        #expect(restored.lastPathComponent != source.lastPathComponent)
        #expect(try Data(contentsOf: restored) == payload)
        #expect(try Data(contentsOf: source) == payload)
        #expect(FileManager.default.fileExists(atPath: cipher.path))
        #expect(decrypted.record?.items.count == 1)
    }

    @Test func wrongPasswordAndTamperingPublishNoPlaintext() async throws {
        let root = try makeFolder()
        let source = root.appending(path: "sample.txt")
        try Data("secret content".utf8).write(to: source)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let protection = try protection()
        let encrypted = await engine.run(
            try protection.batch(source: source, password: password, decrypt: false), settings: Settings()
        ) { _ in }
        guard case .succeeded(let outputs, _) = try #require(encrypted.outcomes.first), let cipher = outputs.first
        else {
            Issue.record("encryption failed: \(encrypted.outcomes)")
            return
        }
        let wrong = await engine.run(
            try protection.batch(source: cipher, password: "different long password", decrypt: true),
            settings: Settings()
        ) { _ in }
        #expect(wrong.outcomes == [.failed(.protectionAuthenticationFailed)])
        var corrupted = try Data(contentsOf: cipher)
        corrupted[corrupted.count - 1] ^= 0x80
        let damaged = root.appending(path: "damaged.age")
        try corrupted.write(to: damaged)
        let tampered = await engine.run(
            try protection.batch(source: damaged, password: password, decrypt: true), settings: Settings()
        ) { _ in }
        #expect(tampered.outcomes == [.failed(.protectionAuthenticationFailed)])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "damaged").path))
        let truncated = root.appending(path: "truncated.age")
        try Data(corrupted.dropLast()).write(to: truncated)
        let incomplete = await engine.run(
            try protection.batch(source: truncated, password: password, decrypt: true), settings: Settings()
        ) { _ in }
        #expect(incomplete.outcomes == [.failed(.protectionAuthenticationFailed)])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "truncated").path))
        #expect(try Data(contentsOf: source) == Data("secret content".utf8))
        #expect(FileManager.default.fileExists(atPath: cipher.path))
    }

    @Test func encryptUsesAnotherNameWhenAgeTargetExists() async throws {
        let root = try makeFolder()
        let source = root.appending(path: "sample.txt")
        let occupied = root.appending(path: "sample.txt.age")
        try Data("original".utf8).write(to: source)
        try Data("occupied".utf8).write(to: occupied)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let protection = try protection()

        let outcome = await engine.run(
            try protection.batch(source: source, password: password, decrypt: false), settings: Settings()
        ) { _ in }

        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first), let encrypted = outputs.first
        else {
            Issue.record("encryption failed: \(outcome.outcomes)")
            return
        }
        #expect(encrypted != occupied)
        #expect(try Data(contentsOf: occupied) == Data("occupied".utf8))
        #expect(try Data(contentsOf: source) == Data("original".utf8))
        #expect(FileManager.default.fileExists(atPath: encrypted.path))
    }

    @Test func emptyFileRoundTripsAfterAgeAuthentication() async throws {
        let root = try makeFolder()
        let source = root.appending(path: "empty.bin")
        try Data().write(to: source)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let protection = try protection()

        await #expect(throws: EngineError.self) {
            try await OutputVerifier.verify(StagedFile(url: source, name: "empty.bin", check: .decompressed))
        }
        let linked = root.appending(path: "linked.bin")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        await #expect(throws: EngineError.self) {
            try await OutputVerifier.verify(
                StagedFile(
                    url: linked, name: "linked.bin",
                    check: .ageAuthenticatedPlaintext(AgeAuthenticationProof())))
        }
        let encrypted = await engine.run(
            try protection.batch(source: source, password: password, decrypt: false), settings: Settings()
        ) { _ in }
        guard case .succeeded(let encryptedURLs, _) = try #require(encrypted.outcomes.first),
            let cipher = encryptedURLs.first
        else {
            Issue.record("empty-file encryption failed: \(encrypted.outcomes)")
            return
        }
        let decrypted = await engine.run(
            try protection.batch(source: cipher, password: password, decrypt: true), settings: Settings()
        ) { _ in }
        guard case .succeeded(let decryptedURLs, _) = try #require(decrypted.outcomes.first),
            let restored = decryptedURLs.first
        else {
            Issue.record("empty-file decryption failed: \(decrypted.outcomes)")
            return
        }
        #expect(restored != source)
        #expect(try Data(contentsOf: restored).isEmpty)
        #expect(try Data(contentsOf: source).isEmpty)
        #expect(FileManager.default.fileExists(atPath: cipher.path))
    }

    @Test func rejectsWeakPasswordAndSymbolicLink() throws {
        let root = try makeFolder()
        let source = root.appending(path: "source")
        let link = root.appending(path: "link")
        try Data("secret".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let protection = try protection()
        #expect(throws: EngineError.self) {
            _ = try protection.batch(source: source, password: "short", decrypt: false)
        }
        #expect(throws: EngineError.self) { _ = try protection.batch(source: link, password: password, decrypt: false) }
    }
}
