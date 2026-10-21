import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct MenuValueTests {
    @Test func editedSlotsPersistAndReset() throws {
        var settings = Settings()
        let slotID = "image.resize/percent-50"
        try settings.menuValues.set(63, for: slotID)
        let restored = try Settings.decode(JSONEncoder().encode(settings))
        #expect(restored.menuValues.value(for: slotID) == 63)
        settings.menuValues.reset(slotID)
        #expect(settings.menuValues.value(for: slotID) == 50)
        #expect(throws: MenuValueError.invalidValue) { try settings.menuValues.set(0, for: slotID) }
        #expect(throws: MenuValueError.invalidValue) { try settings.menuValues.set(42, for: "unknown/slot") }
    }

    @Test func editedResizeSlotsReachPlanners() throws {
        var settings = Settings()
        try settings.menuValues.set(63, for: "image.resize/percent-50")
        try settings.menuValues.set(1440, for: "image.resize/long-1920")
        try settings.menuValues.set(80, for: "video.resize/percent-50")
        try settings.menuValues.set(900, for: "video.resize/1080p")
        #expect(
            ImagePlanner.operation(for: .imageResize, preset: "percent-50", settings: settings)
                == .resize(ImageResize(size: .percent(63))))
        #expect(
            ImagePlanner.operation(for: .imageResize, preset: "long-1920", settings: settings)
                == .resize(ImageResize(size: .longEdge(1440))))
        #expect(
            VideoPlanner.options(for: .videoResize, preset: "percent-50", settings: settings) == .resize(.percent(80)))
        #expect(VideoPlanner.options(for: .videoResize, preset: "1080p", settings: settings) == .resize(.lines(900)))
        #expect(VideoPlanner.options(for: .videoResize, preset: "unknown", settings: settings) == nil)
    }

    @Test func editedByteTargetReachesCompressionPlanner() throws {
        var settings = Settings()
        try settings.menuValues.set(40, for: "video.compress/mb-25")
        let expected = Int64((40_000_000.0 * MediaLimits.targetShare).rounded(.down))
        #expect(
            VideoPlanner.options(for: .videoCompress, preset: "mb-25", settings: settings)
                == .compress(VideoCompression(goal: .bytes(expected))))
    }

    @Test func invalidStoredValueIsRejectedDuringPlanning() throws {
        let stored = Data(#"{"menuValues":{"overrides":{"video.resize/1080p":0}}}"#.utf8)
        let settings = try Settings.decode(stored)
        #expect(settings.menuValues.value(for: "video.resize/1080p") == nil)
        #expect(VideoPlanner.options(for: .videoResize, preset: "1080p", settings: settings) == nil)
    }

    @Test func editedCatalogPublishesValuesAndInvalidatesOldRequest() throws {
        let titles = MenuTitles(operation: { $0.rawValue }, preset: { _, slot in slot }, kind: { $0.rawValue })
        func catalog(_ value: Int) -> MenuFile {
            MenuFile(
                token: "token", hostAvailable: true, visibleOperations: [.imageResize, .videoCompress],
                titles: titles, sizeTargets: ["video.compress/mb-25": Int64(value) * MenuValues.bytesPerMegabyte],
                resizeTargets: ["image.resize/percent-50": value])
        }
        let old = catalog(50)
        let edited = try MenuFile(json: catalog(60).encoded())
        #expect(edited.entries.first { $0.op == .imageResize && $0.preset == "percent-50" }?.resizeValue == 60)
        #expect(edited.entries.first { $0.op == .videoCompress && $0.preset == "mb-25" }?.targetBytes == 60_000_000)
        #expect(old.catalogVersion != edited.catalogVersion)
        let request = RunRequest(
            catalogVersion: old.catalogVersion, entryIndex: 0, token: "token", paths: ["/tmp/a.png"])
        let parsed = try RunRequest(url: #require(request.url(scheme: "macease")), scheme: "macease")
        #expect(parsed.catalogVersion != edited.catalogVersion)
    }

    @Test func checksumLeavesRunKnownVectors() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "MacEaseMenuValue-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: source)
        defer {
            do {
                try FileManager.default.removeItem(at: source)
            } catch {
                Issue.record(error)
            }
        }
        #expect(OperationID.anyChecksum.presets == ["sha256", "md5", "sha1", "sha512"])
        #expect(
            try Checksum.digest(of: source, algorithm: .sha1, progress: { _ in })
                == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(
            try Checksum.digest(of: source, algorithm: .sha512, progress: { _ in })
                == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    @Test func negativeExtraAngleIsAcceptedAndOutOfRangeRejected() {
        var settings = Settings()
        settings.extraRotationEnabled = true
        settings.extraRotationDegrees = -45
        #expect(ImagePlanner.operation(for: .imageRotate, preset: "extra-angle", settings: settings) != nil)
        #expect(VideoPlanner.options(for: .videoRotate, preset: "extra-angle", settings: settings) != nil)
        settings.extraRotationDegrees = 361
        #expect(ImagePlanner.operation(for: .imageRotate, preset: "extra-angle", settings: settings) == nil)
        #expect(VideoPlanner.options(for: .videoRotate, preset: "extra-angle", settings: settings) == nil)
    }
}
