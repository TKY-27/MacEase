import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct ConversionPlanningTests {
    @Test(arguments: [
        (OperationID.imageHDRToSDR, OperationOptions.image(.hdrToSDR), "webp"),
        (.videoHDRToSDR, .video(.hdrToSDR), "webm"),
        (.videoHDRToSDR, .video(.hdrToSDR), "mkv"),
        (.videoHDRToSDR, .video(.hdrToSDR), "avi"),
        (.videoHDRToSDR, .video(.hdrToSDR), "flv"),
    ])
    func staleHDRRequestsRejectNonCandidateFormats(op: OperationID, options: OperationOptions, suffix: String)
        async throws
    {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseHDRPlanning-\(UUID().uuidString)")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: support) } }
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let source = support.appending(path: "source.\(suffix)")
        let original = Data("unsupported input".utf8)
        try original.write(to: source)
        let request = OperationRequest(op: op, options: options, inputs: [source])
        let settings = Settings()
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func hdrMenuOperationsMapToExistingConverters() {
        #expect(OperationPlanner.options(for: .imageHDRToSDR, preset: nil, settings: Settings()) == .image(.hdrToSDR))
        #expect(OperationPlanner.options(for: .videoHDRToSDR, preset: nil, settings: Settings()) == .video(.hdrToSDR))
        #expect(OperationPlanner.options(for: .imageHDRToSDR, preset: "unknown", settings: Settings()) == nil)
        #expect(OperationPlanner.options(for: .videoHDRToSDR, preset: "unknown", settings: Settings()) == nil)
    }

    @Test func audioAndVideoUseSharedSubtitleSettings() {
        var settings = Settings()
        settings.intelligence.subtitleLanguage = "ja-JP"
        settings.intelligence.translationTarget = "fr"
        for format in SubtitleFormat.allCases {
            let request = SubtitleRequest(format: format, language: "ja-JP", translation: nil)
            #expect(
                OperationPlanner.options(for: .audioSubtitles, preset: format.rawValue, settings: settings)
                    == .audio(.subtitles(request)))
            #expect(
                OperationPlanner.options(for: .videoSubtitles, preset: format.rawValue, settings: settings)
                    == .video(.subtitles(request)))
        }
        let translated = SubtitleRequest(format: .srt, language: "ja-JP", translation: "fr")
        #expect(
            OperationPlanner.options(for: .audioSubtitles, preset: "translated-srt", settings: settings)
                == .audio(.subtitles(translated)))
        #expect(OperationPlanner.options(for: .audioSubtitles, preset: "unknown", settings: settings) == nil)
        #expect(NewFileNaming(options: .audio(.subtitles(translated))) == nil)
    }

    @Test func newSettingsMigrateAndRoundTrip() throws {
        let defaults = try Settings.decode(Data(#"{"text":{"jsonIndent":"four"}}"#.utf8))
        #expect(defaults.text.jsonIndent == .four)
        #expect(defaults.text.jsonKeyComparison == .ordinal)
        #expect(!defaults.text.jsonDescending)
        #expect(defaults.text.jsonPinnedKeys.isEmpty)
        #expect(!defaults.text.jsonSortPrimitiveArrays)
        #expect(!defaults.folder.treeFoldersOnly)
        #expect(defaults.folder.analysisExportFormat == .csv)
        var changed = defaults
        changed.text.jsonKeyComparison = .natural
        changed.text.jsonDescending = true
        changed.text.jsonPinnedKeys = ["id", "name"]
        changed.text.jsonSortPrimitiveArrays = true
        changed.folder.treeFoldersOnly = true
        changed.folder.analysisExportFormat = .html
        #expect(try Settings.decode(JSONEncoder().encode(changed)) == changed)
    }
}
