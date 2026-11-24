import Formats
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct ArchiveExtractionRoutingTests {
    private var executable: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Vendor/build/macease-hatchzip")
    }

    private func fixture(
        in folder: URL, format: String = "zip", encoding: String = "cp932", encryption: String = "none",
        variant: String = "nested", size: Int = 0
    ) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appending(path: "bundle.\(format)")
        let script = try #require(
            Bundle.module.url(forResource: "legacy-archive-fixtures", withExtension: "py", subdirectory: "Resources"))
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [script.path, source.path, format, encoding, encryption, variant, String(size)]
        try python.run()
        python.waitUntilExit()
        try #require(python.terminationStatus == 0)
        return variant == "split" ? source.appendingPathExtension("001") : source
    }

    private func run(
        _ source: URL, in folder: URL, settings: Settings = Settings(), password: String? = nil,
        native: Bool = false, prefersJapanese: Bool = true, executable: URL? = nil, sessionID: UUID? = nil,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async throws -> (BatchOutcome, JobEngine, HatchExtractionStore, Batch) {
        let support = folder.appending(path: "support")
        let store = HatchExtractionStore(supportDirectory: support, executableURL: executable ?? self.executable)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1, hatchExtractions: store)
        let operation: ArchiveOperation =
            native ? .extract(password: password) : .hatchExtract(password: password, sessionID: sessionID)
        let batch = OperationPlanner.batch(
            for: OperationRequest(
                op: native ? .archiveExtract : .archiveHatchExtract, options: .archive(operation), inputs: [source]),
            settings: settings, prefersJapaneseArchiveNames: prefersJapanese)
        let outcome = await engine.run(batch, settings: settings, progress: progress)
        return (outcome, engine, store, batch)
    }

    private func output(_ outcome: BatchOutcome) throws -> URL {
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first) else {
            Issue.record("Archive extraction failed: \(outcome.outcomes)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return try #require(outputs.first)
    }

    private func tree(_ root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        let walker = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        var result: [String: Data] = [:]
        while let child = walker.nextObject() as? URL {
            let child = child.resolvingSymlinksInPath()
            try #require(child.pathComponents.starts(with: root.pathComponents))
            let relative = child.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result[relative + "/"] = Data()
            } else {
                result[relative] = try Data(contentsOf: child)
            }
        }
        return result
    }

    @Test(arguments: ["cp437", "western-valid", "mixed-invalid", "nested"], [false, true])
    func ZIPLanguagePolicyMatchesTheRealHelperBaseline(variant: String, prefersJapanese: Bool) async throws {
        let root = try TestVolume.makeFolder()
        let baselineFolder = root.appending(path: "baseline")
        let currentFolder = root.appending(path: "current")
        let encoding = variant == "cp437" ? "cp437" : "cp932"
        let baseline = try fixture(in: baselineFolder, encoding: encoding, variant: variant)
        let current = try fixture(in: currentFolder, encoding: encoding, variant: variant)
        let baselineSession = baselineFolder.appending(path: "session")
        let execution = Process()
        let input = Pipe()
        let output = Pipe()
        execution.executableURL = executable
        execution.standardInput = input
        execution.standardOutput = output
        let request =
            try JSONSerialization.data(withJSONObject: [
                "action": "start", "directory": baselineSession.path, "input": baseline.path,
            ]) + Data([10])
        try execution.run()
        try input.fileHandleForWriting.write(contentsOf: request)
        let response = output.fileHandleForReading.readDataToEndOfFile()
        execution.waitUntilExit()
        try input.fileHandleForWriting.close()
        #expect(execution.terminationStatus == 0)
        let events = try String(decoding: response, as: UTF8.self).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let baselinePath = try #require(events.first { $0["event"] as? String == "finished" }?["output"] as? String)
        let baselineTree = try tree(URL(fileURLWithPath: baselinePath, isDirectory: true))
        let (outcome, _, store, _) = try await run(current, in: currentFolder, prefersJapanese: prefersJapanese)
        let extracted = try self.output(outcome)
        let native = prefersJapanese && ["western-valid", "nested"].contains(variant)
        if native {
            #expect(outcome.record?.canUndo == true)
            #expect(FileManager.default.fileExists(atPath: current.path))
            #expect(try store.sessions().isEmpty)
            let expected =
                variant == "western-valid"
                ? ["K罵n.txt", "M〕ler.txt", "na久e.txt"] : ["資料/日本語.txt", "表.txt", "ascii.txt"]
            let actualNames = Set(try tree(extracted).filter { !$0.key.hasSuffix("/") }.keys)
            #expect(actualNames == Set(expected))
        } else {
            #expect(try tree(extracted) == baselineTree)
            #expect(outcome.record?.canUndo == false)
            #expect(!FileManager.default.fileExists(atPath: current.path))
        }
        #expect(!FileManager.default.fileExists(atPath: baseline.path))
    }

    @Test(arguments: ["flat", "nested"], Settings.OutputMode.allCases)
    func legacyZIPMatchesNativeUTF8CommitCollisionAndUndo(variant: String, mode: Settings.OutputMode) async throws {
        let root = try TestVolume.makeFolder()
        var settings = Settings()
        settings.outputMode = mode
        let legacyFolder = root.appending(path: "legacy")
        let utf8Folder = root.appending(path: "utf8")
        let legacy = try fixture(in: legacyFolder, variant: variant)
        let utf8 = try fixture(in: utf8Folder, encoding: "utf8", variant: variant)
        for folder in [legacyFolder, utf8Folder] {
            try FileManager.default.createDirectory(
                at: folder.appending(path: "bundle"), withIntermediateDirectories: false)
            try Data("keep existing output".utf8).write(to: folder.appending(path: "bundle/existing.txt"))
        }
        let original = try Data(contentsOf: legacy)
        let (legacyOutcome, engine, store, batch) = try await run(legacy, in: legacyFolder, settings: settings)
        let (utf8Outcome, _, _, _) = try await run(utf8, in: utf8Folder, settings: settings, native: true)
        let extracted = try output(legacyOutcome)
        let equivalent = try output(utf8Outcome)
        #expect(extracted.lastPathComponent == "bundle (2)")
        #expect(equivalent.lastPathComponent == extracted.lastPathComponent)
        #expect(try tree(extracted) == tree(equivalent))
        #expect(try Data(contentsOf: legacy) == original)
        #expect(FileManager.default.fileExists(atPath: utf8.path))
        #expect(legacyOutcome.record?.canUndo == true)
        #expect(try store.sessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(try await engine.undo(batch.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: extracted.path))
        #expect(try Data(contentsOf: legacy) == original)
        #expect(
            try Data(contentsOf: legacyFolder.appending(path: "bundle/existing.txt"))
                == Data("keep existing output".utf8))
    }

    @Test(arguments: ["tar", "tar.gz"])
    func legacyTARMatchesItsUTF8NativeEquivalent(_ format: String) async throws {
        let root = try TestVolume.makeFolder()
        let legacyFolder = root.appending(path: "legacy")
        let utf8Folder = root.appending(path: "utf8")
        let legacy = try fixture(in: legacyFolder, format: format)
        let utf8 = try fixture(in: utf8Folder, format: format, encoding: "utf8")
        let original = try Data(contentsOf: legacy)
        let (legacyOutcome, _, store, _) = try await run(legacy, in: legacyFolder)
        let (utf8Outcome, _, _, _) = try await run(utf8, in: utf8Folder, native: true)
        #expect(try tree(output(legacyOutcome)) == tree(output(utf8Outcome)))
        #expect(try Data(contentsOf: legacy) == original)
        #expect(legacyOutcome.record?.canUndo == true)
        #expect(try store.sessions().isEmpty)
    }

    @Test(arguments: ["zipcrypto", "aes128", "aes192", "aes256"])
    func encryptedLegacyZIPUsesTheTypedPassword(_ encryption: String) async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encryption: encryption)
        let original = try Data(contentsOf: source)
        for (password, expected) in [(nil, InvalidInput.passwordRequired), ("incorrect", .wrongPassword)] {
            let (outcome, _, _, _) = try await run(source, in: root, password: password)
            #expect(outcome.outcomes == [.failed(.invalidInput(expected))])
            #expect(try Data(contentsOf: source) == original)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
        }
        let (outcome, _, store, _) = try await run(source, in: root, password: "fixture-password")
        let extracted = try output(outcome)
        #expect(
            try Data(contentsOf: extracted.appending(path: "表.txt")) == Data("independent legacy archive payload".utf8))
        #expect(
            try Data(contentsOf: extracted.appending(path: "資料/日本語.txt"))
                == Data("independent legacy archive payload".utf8))
        #expect(try Data(contentsOf: source) == original)
        #expect(outcome.record?.canUndo == true)
        #expect(try store.sessions().isEmpty)
    }

    @Test(arguments: ["tar", "tar.gz"])
    func legacyTARWithoutJapanesePreferenceRefusesBeforeMutation(_ format: String) async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, format: format)
        let original = try Data(contentsOf: source)
        let (outcome, _, store, _) = try await run(source, in: root, prefersJapanese: false)
        #expect(outcome.outcomes == [.failed(.invalidInput(.archiveNameEncodingUnsupported))])
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test(arguments: ["split", "unsupported-method", "backslash"])
    func unsupportedLegacyCombinationsRefuseBeforeMutation(_ variant: String) async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, variant: variant)
        let original = try Data(contentsOf: source)
        let (outcome, _, store, _) = try await run(source, in: root)
        let feature: ArchiveExtractionFeature
        switch variant {
        case "split": feature = .splitVolumes
        case "backslash": feature = .zipBackslashSeparators
        default: feature = .zipCompression(9)
        }
        #expect(outcome.outcomes == [.failed(.invalidInput(.archiveLegacyFeatureUnsupported(feature)))])
        #expect(try Data(contentsOf: source) == original)
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func cancellationDuringLegacyExtractionLeavesOnlyTheOriginal() async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, size: 8 * 1024 * 1024)
        let original = try Data(contentsOf: source)
        let cancelled = Mutex(false)
        let (outcome, _, store, _) = try await run(source, in: root) { progress in
            if let fraction = progress.currentFileFraction, fraction > 0, fraction < 1 {
                cancelled.withLock { $0 = true }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        #expect(cancelled.withLock { $0 })
        #expect(outcome.outcomes == [.failed(.cancelled)])
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
        #expect(try store.sessions().isEmpty)
    }

    private func protocolExecutable(
        in root: URL, output: URL, marker: URL, legacy: Bool = false, resuming: Bool = false
    ) throws -> URL {
        let script = root.appending(path: "protocol.py")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let quotedOutput = String(decoding: try encoder.encode(output.path), as: UTF8.self)
        let quotedMarker = String(decoding: try encoder.encode(marker.path), as: UTF8.self)
        try """
        #!/usr/bin/python3
        import json, pathlib, sys
        request = json.loads(sys.stdin.readline())
        proof = pathlib.Path(request['directory'] + '.filenames.json')
        assert proof.exists() == \(legacy ? "False" : "True")
        assert request['action'] == '\(legacy || resuming ? "resume" : "start")'
        pathlib.Path(\(quotedMarker)).write_text('helper invoked')
        print(json.dumps({'event': 'finished', 'output': \(quotedOutput)}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    @Test(arguments: ["utf8", "unflagged", "ambiguous"], [false, true])
    func UTF8StillInvokesTheHelperWithProofAlreadyPresent(_ encoding: String, prefersJapanese: Bool) async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(
            in: root, encoding: encoding, variant: encoding == "ambiguous" ? "ambiguous" : "nested")
        let output = root.appending(path: "helper-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let marker = root.appending(path: "invoked")
        let executable = try protocolExecutable(in: root, output: output, marker: marker)
        let (outcome, _, store, _) = try await run(
            source, in: root, prefersJapanese: prefersJapanese, executable: executable)
        let extracted = try self.output(outcome)
        #expect(extracted == output)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(outcome.record?.canUndo == false)
        let proofs = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        let proof = try #require(proofs.first { $0.pathExtension == "json" })
        let contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: proof)) as? [String: Any])
        #expect(contents["version"] as? Int == 2)
        #expect(contents["input"] as? String == source.path)
        #expect(contents["prefersJapanese"] as? Bool == prefersJapanese)
        #expect(contents["route"] as? String == "hatchzip")
        #expect(try FileManager.default.attributesOfItem(atPath: proof.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test(arguments: [false, true])
    func pausedSessionsKeepTheirStartedRouteWhenLanguagesChange(_ hasProof: Bool) async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encoding: "utf8")
        let output = root.appending(path: "legacy-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("already extracted".utf8).write(to: output.appending(path: "existing.txt"))
        let sessionID = UUID()
        let session = root.appending(path: "support/HatchExtractions/\(sessionID.uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "input": source.path, "output": output.path, "state": "paused",
        ])
        try manifest.write(to: session.appending(path: "manifest.json"))
        if hasProof {
            let proof = try JSONSerialization.data(withJSONObject: [
                "version": 2, "input": source.path, "prefersJapanese": false, "route": "hatchzip",
            ])
            try proof.write(to: URL(fileURLWithPath: session.path + ".filenames.json"))
        }
        let marker = root.appending(path: "resumed")
        let executable = try protocolExecutable(
            in: root, output: output, marker: marker, legacy: !hasProof, resuming: true)
        let (outcome, _, _, _) = try await run(source, in: root, executable: executable, sessionID: sessionID)
        let extracted = try self.output(outcome)
        #expect(extracted == output)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: output.appending(path: "existing.txt")) == Data("already extracted".utf8))
        #expect(outcome.record?.canUndo == false)
    }

    @Test(arguments: ["none", "aes256"], Settings.OutputMode.allCases)
    func UTF8RealHelperKeepsItsInPlaceCommit(encryption: String, mode: Settings.OutputMode) async throws {
        let root = try TestVolume.makeFolder()
        var settings = Settings()
        settings.outputMode = mode
        let source = try fixture(in: root, encoding: "utf8", encryption: encryption)
        let (outcome, engine, store, batch) = try await run(
            source, in: root, settings: settings, password: "fixture-password")
        let extracted = try output(outcome)
        #expect(
            try Data(contentsOf: extracted.appending(path: "表.txt")) == Data("independent legacy archive payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(outcome.record?.canUndo == false)
        #expect(try await engine.undo(batch.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        let session = try #require(store.sessions().first)
        #expect(
            FileManager.default.fileExists(
                atPath: store.directory.appending(path: session.id.uuidString + ".filenames.json").path))
    }

    @Test func legacyZIP64KeepsNativeExtraction() async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, variant: "zip64")
        let original = try Data(contentsOf: source)
        let (outcome, _, _, _) = try await run(source, in: root)
        let extracted = try output(outcome)
        #expect(
            try Data(contentsOf: extracted.appending(path: "資料/日本語.txt"))
                == Data("independent legacy archive payload".utf8))
        #expect(try Data(contentsOf: source) == original)
        #expect(outcome.record?.canUndo == true)
    }

    @Test func legacyZIPLinkTargetsRemainReadable() async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, variant: "legacy-link")
        let original = try Data(contentsOf: source)
        let (outcome, _, _, _) = try await run(source, in: root)
        let extracted = try output(outcome)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: extracted.appending(path: "別名").path) == "資料.txt")
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: ["zipcrypto", "aes128", "aes192", "aes256"])
    func encryptedLegacyZIPLinksRefuseTheUnsupportedFeature(_ encryption: String) async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encryption: encryption, variant: "legacy-link")
        let original = try Data(contentsOf: source)
        let (outcome, _, store, _) = try await run(source, in: root, password: "fixture-password")
        #expect(outcome.outcomes == [.failed(.invalidInput(.archiveLegacyFeatureUnsupported(.zipEncryptedLinks)))])
        #expect(try Data(contentsOf: source) == original)
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func nameBudgetRefusalPrecedesHelperStartup() async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encoding: "utf8", variant: "over-budget")
        let original = try Data(contentsOf: source)
        let (outcome, _, store, _) = try await run(source, in: root)
        #expect(outcome.outcomes == [.failed(.invalidInput(.archiveNameInspectionLimit))])
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func cancellationStopsCentralDirectoryInspection() throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encoding: "utf8", variant: "benchmark")
        let original = try Data(contentsOf: source)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ArchiveNameInspection.inspect(source, prefersJapanese: true) {
                checks += 1
                if checks == 1000 { throw CancellationError() }
            }
        }
        #expect(checks == 1000)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func ZIPNameInspectionCostFor100000Entries() throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encoding: "utf8", variant: "benchmark")
        let clock = ContinuousClock()
        let started = clock.now
        let inspection = try ArchiveNameInspection.inspect(source, prefersJapanese: true)
        let elapsed = started.duration(to: clock.now)
        #expect(!inspection.needsLegacyDecoder)
        #expect(elapsed < ArchiveNameInspection.maximumDuration)
        print("100000-entry ZIP name pre-check: \(elapsed)")
    }
}
