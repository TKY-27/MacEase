import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct DocumentConversionRoutingTests {
    @Test(arguments: ["docx", "odt", "rtf", "rtfd"])
    func documentsReachBothConversions(_ suffix: String) throws {
        let source = URL(fileURLWithPath: "/samples/source.\(suffix)", isDirectory: suffix == "rtfd")
        #expect(FileKind(fileURL: source) == .document)
        for target in ["pdf", "txt"] {
            let entry = MenuEntry(op: .documentConvert, preset: target, path: ["Convert", target])
            #expect(MenuLayout.isApplicable(entry, selection: [source]))
            let options = try #require(
                OperationPlanner.options(for: .documentConvert, preset: target, settings: Settings()))
            let request = OperationRequest(op: .documentConvert, options: options, inputs: [source])
            #expect(OperationPlanner.batch(for: request, settings: Settings()).items.count == 1)
        }
    }

    @Test(arguments: [
        ("html", "html-pdf"), ("htm", "html-txt"), ("json", "json-plist-xml"),
        ("json", "json-plist-binary"), ("srt", "srt-vtt"), ("vtt", "vtt-srt"), ("md", "md-html"),
        ("markdown", "md-pdf"), ("yaml", "yaml-json"), ("yml", "yaml-json"), ("json", "json-yaml"),
        ("toml", "toml-json"), ("json", "json-toml"),
    ])
    func textLeavesRequireTheirSource(suffix: String, preset: String) throws {
        let source = URL(fileURLWithPath: "/samples/source.\(suffix)")
        let entry = MenuEntry(op: .textConvert, preset: preset, path: ["Convert", preset])
        #expect(MenuLayout.isApplicable(entry, selection: [source]))
        #expect(!MenuLayout.isApplicable(entry, selection: [source, URL(fileURLWithPath: "/samples/other.csv")]))
        #expect(OperationPlanner.options(for: .textConvert, preset: preset, settings: Settings()) != nil)
    }

    @Test func propertyListsReachJSONWithoutTextEdits() {
        let source = URL(fileURLWithPath: "/samples/source.plist")
        #expect(FileKind(fileURL: source) == .plist)
        #expect(MenuLayout.isApplicable(MenuEntry(op: .plistConvert, preset: "json", path: []), selection: [source]))
        #expect(!MenuLayout.isApplicable(MenuEntry(op: .textEncoding, preset: "utf-8", path: []), selection: [source]))
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func structuredConversionsKeepSourcesAndResolveCollisions(_ mode: Settings.OutputMode) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseConversion-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "source.json")
        let original = Data(#"{"enabled":true,"count":9223372036854775807}"#.utf8)
        try original.write(to: source)
        let occupied = directory.appending(path: "source.plist")
        let sentinel = Data("keep occupied destination".utf8)
        try sentinel.write(to: occupied)
        var settings = Settings()
        settings.outputMode = mode
        let support = directory.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let request = OperationRequest(op: .textConvert, options: .text(.convert(.jsonToBinaryPlist)), inputs: [source])
        let result = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        guard case .succeeded(let outputs, let warnings) = try #require(result.outcomes.first) else {
            Issue.record("Conversion failed: \(result.outcomes)")
            return
        }
        #expect(warnings == [.structuredTextFormattingLost])
        let output = try #require(outputs.first)
        #expect(output.lastPathComponent == "source (2).plist")
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: occupied) == sentinel)
        let decoded = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: output), options: [], format: nil) as? [String: Any])
        #expect((decoded["count"] as? NSNumber)?.int64Value == Int64.max)
        try FileManager.default.removeItem(at: directory)
    }
}
