import Foundation
import MenuCatalog
import Speech
import Testing

@testable import Engine

@Suite(.serialized) struct ParityIntegrationTests {
    @Test func treePlannerReadsFoldersOnlySetting() async throws {
        let folder = try TestVolume.makeFolder()
        let root = folder.appending(path: "root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "child"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: root.appending(path: "notes.txt"))
        var settings = Settings()
        settings.folder.treeFoldersOnly = true
        let options = try #require(OperationPlanner.options(for: .folderTree, preset: "copy", settings: settings))
        let request = OperationRequest(op: .folderTree, options: options, inputs: [root])
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        #expect(outcome.clipboardText == "root\n└── child")
    }

    @Test(arguments: AnalysisExportFormat.allCases)
    func analysisSavesWithoutOverwritingAndCanUndo(format: AnalysisExportFormat) async throws {
        let folder = try TestVolume.makeFolder()
        let root = folder.appending(path: "root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let report = try FolderAnalysis.scan([root], settings: FolderSettings()) { _ in }
        let destination = folder.appending(path: "report.\(format.pathExtension)")
        try Data("original".utf8).write(to: destination)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let outcome = try await engine.saveReport(report, as: format, to: destination)
        let output = folder.appending(path: "report (2).\(format.pathExtension)")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(try Data(contentsOf: output).starts(with: [0xEF, 0xBB, 0xBF]) == (format == .csv))
        let record = try #require(outcome.record)
        #expect(try await engine.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }

    @Test(
        .requires(.speechAssets) {
            guard SpeechTranscriber.isAvailable,
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            else { return false }
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            return try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil
        }, arguments: SubtitleFormat.allCases)
    func audioSubtitlesDeriveEachFormat(format: SubtitleFormat) async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "spoken.aiff")
        let synthesizer = Process()
        synthesizer.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        synthesizer.arguments = ["-v", "Samantha", "-o", source.path, "The weather is nice today."]
        try synthesizer.run()
        synthesizer.waitUntilExit()
        #expect(synthesizer.terminationStatus == 0)
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = .replace
        settings.intelligence.subtitleLanguage = "en-US"
        let options = try #require(
            OperationPlanner.options(for: .audioSubtitles, preset: format.rawValue, settings: settings))
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(op: .audioSubtitles, options: options, inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = folder.appending(path: "spoken.\(format.rawValue)")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try Data(contentsOf: source) == original)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.lowercased().contains("weather"))
        if format == .vtt { #expect(text.hasPrefix("WEBVTT\n")) }
        if format == .srt { #expect(text.contains(" --> ")) }
        let record = try #require(outcome.record)
        #expect(try await engine.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: source) == original)
    }
}
