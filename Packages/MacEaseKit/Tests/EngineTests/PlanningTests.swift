import Foundation
import MenuCatalog
import Testing

@testable import Engine

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MacEasePlanning-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite struct ContentSnifferTests {
    @Test func recognizesRealContentAndRejectsImpostors() throws {
        let folder = try temporaryFolder()
        let png = folder.appending(path: "a.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        let fakeVideo = folder.appending(path: "b.mp4")
        try Data("plain text".utf8).write(to: fakeVideo)
        let mkv = folder.appending(path: "c.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0x01]).write(to: mkv)
        let pdf = folder.appending(path: "d.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: pdf)

        #expect(try ContentSniffer.matches(png, kind: .image))
        #expect(try !ContentSniffer.matches(fakeVideo, kind: .video))
        #expect(try ContentSniffer.matches(fakeVideo, kind: .text))
        #expect(try ContentSniffer.matches(mkv, kind: .video))
        #expect(try ContentSniffer.matches(pdf, kind: .pdf))
        #expect(try ContentSniffer.matches(folder, kind: .folder))
        #expect(try !ContentSniffer.matches(folder, kind: .any))
    }

    @Test func recognizesV7TarAndRejectsBrokenHeaders() throws {
        let folder = try temporaryFolder()
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<6, with: Array("a.txt\0".utf8))
        header.replaceSubrange(100..<108, with: Array("0000644\0".utf8))
        header.replaceSubrange(108..<116, with: Array("0000000\0".utf8))
        header.replaceSubrange(116..<124, with: Array("0000000\0".utf8))
        header.replaceSubrange(124..<136, with: Array("00000000000\0".utf8))
        header.replaceSubrange(136..<148, with: Array("00000000000\0".utf8))
        header.replaceSubrange(148..<156, with: Array("005415\0 ".utf8))
        let archive = folder.appending(path: "old.tar")
        try Data(header + [UInt8](repeating: 0, count: 1024)).write(to: archive)
        #expect(try ContentSniffer.matches(archive, kind: .archive))

        header[100] = UInt8(ascii: "1")
        try Data(header).write(to: archive)
        #expect(try !ContentSniffer.matches(archive, kind: .archive))
    }
}

@Suite struct ChecksumTests {
    @Test func hashesFilesAndSkipsPackages() async throws {
        let folder = try temporaryFolder()
        let file = folder.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: file)
        let package = folder.appending(path: "Tool.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let support = try temporaryFolder()
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        let options = try #require(OperationPlanner.options(for: .anyChecksum, preset: "sha256", settings: Settings()))
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .anyChecksum, options: options, inputs: [file, package, file]),
            settings: Settings()
        )

        let outcome = await engine.run(batch, settings: Settings()) { _ in }

        #expect(batch.items.count == 2)
        #expect(outcome.outcomes.last == .skipped(.isDirectory))
        #expect(outcome.clipboardText == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  hello.txt")
        #expect(OperationPlanner.options(for: .anyChecksum, preset: "unknown", settings: Settings()) == nil)
    }
}

@Suite struct SettingsTests {
    @Test func storedValuesSurviveKeysAddedLater() throws {
        var settings = Settings()
        settings.image.jpegQuality = 42
        settings.text.jsonIndent = .tab
        var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
        var image = stored["image"] as? [String: Any] ?? [:]
        image.removeValue(forKey: "webpQuality")
        stored["image"] = image
        stored.removeValue(forKey: "video")

        let decoded = try Settings.decode(JSONSerialization.data(withJSONObject: stored))

        #expect(decoded.image.jpegQuality == 42)
        #expect(decoded.text.jsonIndent == .tab)
        #expect(decoded.image.webpQuality == ImageSettings().webpQuality)
        #expect(decoded.video == VideoSettings())
    }
}

@Suite struct PresetLibraryTests {
    @Test func userEditsOverrideBundledPresetsAndReset() throws {
        let support = try temporaryFolder()
        let library = PresetLibrary(supportDirectory: support)
        var discord = try #require(try library.preset(id: "discord"))
        #expect(discord.video?.targetBytes == 19_400_000)
        discord.video?.maxBytes = 10_000_000
        try library.save(discord)
        #expect(try library.preset(id: "discord")?.video?.maxBytes == 10_000_000)
        #expect(try library.presets().count == library.bundled.count)

        try library.reset(id: "discord")
        #expect(try library.preset(id: "discord")?.video?.maxBytes == 20_000_000)
    }

    @Test func duplicateUserEntriesDoNotCrash() throws {
        let support = try temporaryFolder()
        let library = PresetLibrary(supportDirectory: support)
        var web = try #require(try library.preset(id: "web"))
        web.image?.quality = 60
        let duplicates = try JSONEncoder().encode([web, web])
        try duplicates.write(to: support.appending(path: PresetLibrary.fileName))
        #expect(try library.preset(id: "web")?.image?.quality == 60)
    }

    @Test func instagramAspectRangeParses() throws {
        let library = PresetLibrary(supportDirectory: try temporaryFolder())
        let aspect = try #require(try library.preset(id: "instagram")?.image?.aspect)
        #expect(abs(aspect.min.value - 0.8) < 0.0001)
        #expect(abs(aspect.max.value - 1.91) < 0.0001)
        #expect(aspect.fit == .crop)
    }

    @Test func aspectRatioStoresPreciseLocaleIndependentNumbers() throws {
        let ratio = AspectRatio(width: 1.2345678901234567, height: 0.875)

        let encoded = try JSONEncoder().encode(ratio)

        #expect(String(decoding: encoded, as: UTF8.self) == "\"1.2345678901234567:0.875\"")
        #expect(try JSONDecoder().decode(AspectRatio.self, from: encoded) == ratio)
    }
}

@Suite struct EditedPresetTests {
    @Test func planningUsesTheSettingsPresets() throws {
        var settings = Settings()
        let index = try #require(settings.platformPresets.firstIndex { $0.id == "discord" })
        settings.platformPresets[index].video?.maxBytes = 1_000_000
        let options = try #require(OperationPlanner.options(for: .videoCompress, preset: "discord", settings: settings))
        guard case .video(.compress(let compression)) = options, case .platform(let preset) = compression.goal else {
            Issue.record("expected a platform goal, got \(options)")
            return
        }
        #expect(preset.video?.maxBytes == 1_000_000)
    }
}
