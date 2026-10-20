import Foundation
import FoundationModels
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite struct AINamingTests {
    @Test func sanitizesToTheAllowedAlphabet() {
        #expect(AINaming.sanitized("Beach: sunset/2026?") == "Beach sunset 2026")
        #expect(AINaming.sanitized("夕焼けの海 - 写真") == "夕焼けの海 - 写真")
        #expect(AINaming.sanitized(String(repeating: "a", count: 80))?.count == AINaming.maximumLength)
        #expect(AINaming.sanitized(" ./:: ") == nil)
    }

    @Test(.requires(.appleIntelligence) { AINaming.isAvailable })
    func suggestsANameForAnImage() async throws {
        let folder = try TestVolume.makeFolder()
        let url = try ImageFixtures.write(
            [try ImageFixtures.text("Quarterly Sales Report")], as: .png, to: folder.appending(path: "IMG_0001.png"))
        let name = try await AINaming.suggestedName(for: url, languageCode: "en")
        #expect(!name.isEmpty && name.count <= AINaming.maximumLength)
        #expect(AINaming.sanitized(name) == name)
    }

    @Test func confirmedRenamesApplyWithCollisionSuffixes() async throws {
        let folder = try TestVolume.makeFolder()
        let first = folder.appending(path: "a.png")
        let second = folder.appending(path: "b.png")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let plans = [RenamePlan(url: first, newName: "Sunset.png"), RenamePlan(url: second, newName: "Sunset.png")]
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: .imageAIRename, options: .rename(plans), inputs: [first, second]),
            settings: Settings())
        _ = await engine.run(batch, settings: Settings()) { _ in }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Sunset (2).png", "Sunset.png"])
        #expect(OperationPlanner.options(for: .imageAIRename, preset: nil, settings: Settings()) == nil)
    }
}

@Suite struct AICustomPlannerTests {
    @Test func catalogListsOnlyTheKindsOperations() {
        let text = AICustomPlanner.instructions(for: .image)
        #expect(text.contains("image.convert: png, jpeg"))
        #expect(!text.contains("video."))
    }

    @Test func rejectsStepsOutsideTheMenu() throws {
        let valid = GeneratedStep(operation: "image.convert", preset: "webp")
        #expect(
            try AICustomPlanner.validated(valid, kind: .image) == CustomStep(operation: .imageConvert, preset: "webp"))
        #expect(throws: EngineError.self) {
            try AICustomPlanner.validated(GeneratedStep(operation: "video.trim", preset: "x"), kind: .image)
        }
        #expect(throws: EngineError.self) {
            try AICustomPlanner.validated(GeneratedStep(operation: "image.convert", preset: "mkv"), kind: .image)
        }
    }

    @Test(.requires(.appleIntelligence) { AINaming.isAvailable })
    func plansAConversion() async throws {
        let steps = try await AICustomPlanner.plan("Convert these to WebP", kind: .image)
        #expect(steps.contains(CustomStep(operation: .imageConvert, preset: "webp")))
    }
}
