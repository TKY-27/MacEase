import CryptoKit
import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

struct OrganizationTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(
            path: "MacEaseOrganization-\(UUID())")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let canonical = realpath(root.path, nil) else { throw POSIXError(.EIO) }
        defer { free(canonical) }
        return URL(
            fileURLWithPath: FileManager.default.string(
                withFileSystemRepresentation: canonical, length: strlen(canonical)))
    }

    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    private func engine(_ workspace: URL) throws -> JobEngine {
        try JobEngine(supportDirectory: workspace.appending(path: "support"), concurrency: 2)
    }

    private func batch(_ plans: [OrganizationMovePlan]) -> Batch {
        Batch(
            operation: .folderOrganize,
            items: plans.map { plan in WorkItem(inputs: [plan.source]) { _ in .organize(plan) } })
    }

    @Test func looseDiscoveryPreservesFoldersAndRejectsLinks() throws {
        let root = try workspace()
        let nested = root.appending(path: "existing")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let source = root.appending(path: "loose.txt")
        try write("loose", to: source)
        try write("nested", to: nested.appending(path: "keep.txt"))
        try write("hidden", to: root.appending(path: ".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: source)
        #expect(try OrganizationSafety.candidates(in: root).map(\.path) == [source.path])
        #expect(throws: (any Error).self) {
            try OrganizationMovePlan(root: root, source: nested.appending(path: "keep.txt"), category: "Documents")
        }
    }

    @Test func moveAndUndoPreserveExistingFoldersAndContents() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let existing = root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try write("keep", to: existing.appending(path: "existing.txt"))
        let source = root.appending(path: "invoice.txt")
        try write("receipt", to: source)
        let engine = try engine(workspace)
        let batch = batch([try OrganizationMovePlan(root: root, source: source, category: "Documents/Receipts")])
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        let destination = existing.appending(path: "Receipts/invoice.txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [destination], warnings: [])])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "receipt")
        let undos = try await engine.undo(batch.id)
        #expect(undos == [.restored, .restored])
        #expect(try String(contentsOf: source, encoding: .utf8) == "receipt")
        #expect(!FileManager.default.fileExists(atPath: existing.appending(path: "Receipts").path))
        #expect(try String(contentsOf: existing.appending(path: "existing.txt"), encoding: .utf8) == "keep")
        let reloaded = HistoryStore(supportDirectory: workspace.appending(path: "support"))
        #expect(await reloaded.organizationSuppressions.contains { $0.matches(source) })
    }

    @Test func existingEmptyCategoryIsNeverOwnedByBatch() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let category = root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        try write("source", to: source)
        let engine = try engine(workspace)
        let batch = batch([try OrganizationMovePlan(root: root, source: source, category: "Documents")])
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        #expect(outcome.record?.items.count == 1)
        #expect(try await engine.undo(batch.id) == [.restored])
        #expect(FileManager.default.fileExists(atPath: category.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: category.path).isEmpty)
    }

    @Test func policyAllowsOnlyValidatedApprovedDescendants() throws {
        var policy = OrganizationPolicy(categories: ["Documents"])
        #expect(policy.acceptsCategory("Documents/Receipts/2026"))
        #expect(!policy.acceptsCategory("Documents/../Outside"))
        #expect(!policy.acceptsCategory("DocumentsElsewhere"))
        #expect(!policy.acceptsCategory("/Documents"))
        policy.allowNewSubcategories = false
        #expect(policy.acceptsCategory("Documents"))
        #expect(!policy.acceptsCategory("Documents/Receipts"))
    }

    @Test func collisionRetainsExistingFileAndDanglingLink() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let category = root.appending(path: "Images")
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let source = root.appending(path: "photo.jpg")
        try write("source", to: source)
        try write("existing", to: category.appending(path: "photo.jpg"))
        try FileManager.default.createSymbolicLink(
            atPath: category.appending(path: "photo (2).jpg").path,
            withDestinationPath: "missing")
        let engine = try engine(workspace)
        let outcome = await engine.run(
            batch([try OrganizationMovePlan(root: root, source: source, category: "Images")]),
            settings: Settings()
        ) { _ in }
        let destination = category.appending(path: "photo (3).jpg")
        #expect(outcome.outcomes == [.succeeded(outputs: [destination], warnings: [])])
        #expect(try String(contentsOf: category.appending(path: "photo.jpg"), encoding: .utf8) == "existing")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: category.appending(path: "photo (2).jpg").path)
                == "missing")
    }

    @Test func planRejectsChangedIdentityWithSameSizeAndDate() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        try write("old", to: source)
        let plan = try OrganizationMovePlan(root: root, source: source, category: "Documents")
        let replacement = root.appending(path: "replacement.txt")
        try write("new", to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: plan.sourceStamp.modified], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: replacement, to: source)
        let engine = try engine(workspace)
        let outcome = await engine.run(batch([plan]), settings: Settings()) { _ in }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Documents").path))
    }

    @Test func symlinkCategoryCannotMoveOutsideRoot() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let outside = workspace.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        try write("source", to: source)
        let plan = try OrganizationMovePlan(root: root, source: source, category: "Documents")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Documents"), withDestinationURL: outside)
        let engine = try engine(workspace)
        let outcome = await engine.run(
            batch([plan]),
            settings: Settings()
        ) { _ in }
        #expect(outcome.outcomes.count == 1)
        guard case .failed = outcome.outcomes[0] else { Issue.record("Unsafe category must fail"); return }
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func categoryCannotTraverseApplicationBundle() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let bundle = root.appending(path: "Projects/App.app")
        try FileManager.default.createDirectory(
            at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        #expect(try bundle.resourceValues(forKeys: [.isPackageKey]).isPackage == true)
        let source = root.appending(path: "source.txt")
        try write("source", to: source)
        let plan = try OrganizationMovePlan(root: root, source: source, category: "Projects/App.app/Contents")
        let outcome = await (try engine(workspace)).run(batch([plan]), settings: Settings()) { _ in }
        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(!FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/source.txt").path))
    }

    @Test func undoCannotOverwriteRecreatedOriginalOrDeletePopulatedFolder() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        try write("source", to: source)
        let engine = try engine(workspace)
        let batch = batch([try OrganizationMovePlan(root: root, source: source, category: "Documents")])
        _ = await engine.run(batch, settings: Settings()) { _ in }
        try write("new original", to: source)
        let destination = root.appending(path: "Documents/source.txt")
        #expect(
            try await engine.undo(batch.id) == [
                .skipped(.undoOriginalOccupied, path: source.path),
                .skipped(.undoOutputChanged, path: root.appending(path: "Documents").path),
            ])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "source")
        #expect(try String(contentsOf: source, encoding: .utf8) == "new original")
    }

    @Test(arguments: [false, true]) func durableIntentReconcilesBeforeOrAfterMove(moved: Bool) async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let category = root.appending(path: "Documents")
        let support = workspace.appending(path: "support")
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        let destination = category.appending(path: "source.txt")
        try write("source", to: source)
        let plan = try OrganizationMovePlan(root: root, source: source, category: "Documents")
        let move = OrganizationMoveRecord(
            root: root, rootIdentity: plan.rootIdentity, from: source, to: destination,
            stamp: plan.sourceStamp, category: "Documents")
        let batchID = UUID()
        let intent = OrganizationMoveIntent(
            id: UUID(), batchID: batchID, operation: .folderOrganize,
            date: Date(), move: move)
        try HistoryJournal(supportDirectory: support).publishOrganizationIntent(intent)
        if moved { try FileManager.default.moveItem(at: source, to: destination) }
        let history = HistoryStore(supportDirectory: support)
        try await history.checkAcceptingCommits()
        let records = await history.records
        #expect(records.count == (moved ? 1 : 0))
        if moved {
            #expect(records.first?.items == [.organized(move)])
            #expect(try await history.undo(batchID) == [.restored])
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        let reopened = HistoryStore(supportDirectory: support)
        try await reopened.checkAcceptingCommits()
    }

    @Test func ambiguousRecoveryBlocksFurtherCommits() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let support = workspace.appending(path: "support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        try write("original", to: source)
        let plan = try OrganizationMovePlan(root: root, source: source, category: "Documents")
        let move = OrganizationMoveRecord(
            root: root, rootIdentity: plan.rootIdentity, from: source,
            to: root.appending(path: "Documents/source.txt"), stamp: plan.sourceStamp, category: "Documents")
        var snapshot = HistorySnapshot()
        snapshot.organizationIntents = [
            OrganizationMoveIntent(
                id: UUID(), batchID: UUID(), operation: .folderOrganize,
                date: Date(), move: move)
        ]
        try HistoryJournal(supportDirectory: support).publish(snapshot)
        try FileManager.default.removeItem(at: source)
        let history = HistoryStore(supportDirectory: support)
        await #expect(throws: (any Error).self) { try await history.checkAcceptingCommits() }
        #expect(await history.records.isEmpty)
    }

    @Test func recoveryRefusesAmbiguousHardLinks() async throws {
        let workspace = try workspace()
        let root = workspace.appending(path: "root")
        let support = workspace.appending(path: "support")
        let category = root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        let destination = category.appending(path: "source.txt")
        try write("original", to: source)
        let plan = try OrganizationMovePlan(root: root, source: source, category: "Documents")
        let move = OrganizationMoveRecord(
            root: plan.root, rootIdentity: plan.rootIdentity, from: plan.source,
            to: destination, stamp: plan.sourceStamp, category: "Documents")
        try HistoryJournal(supportDirectory: support).publishOrganizationIntent(
            OrganizationMoveIntent(
                id: UUID(), batchID: UUID(), operation: .folderOrganize, date: Date(), move: move))
        try FileManager.default.linkItem(at: source, to: destination)
        let history = HistoryStore(supportDirectory: support)
        await #expect(throws: (any Error).self) { try await history.checkAcceptingCommits() }
        #expect(await history.records.isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }

    @Test func legacyPolicyDoesNotExpandAutomationConsent() throws {
        let encoded = Data(
            "{\"categories\":[\"Documents\"],\"instructions\":\"\",\"renameOpaqueFiles\":true,\"stabilityDelay\":120}"
                .utf8)
        let policy = try JSONDecoder().decode(OrganizationPolicy.self, from: encoded)
        #expect(!policy.allowNewSubcategories)
        #expect(!policy.acceptsCategory("Documents/Receipts"))
    }

    @Test func stabilityResetsOnChangesAndAttemptsOnlyOnce() throws {
        let root = try workspace()
        let source = root.appending(path: "download.txt")
        try write("partial", to: source)
        var tracker = OrganizationStability()
        let start = Date(timeIntervalSince1970: 100)
        #expect(try tracker.inspect([source], now: start, delay: 120, suppressions: []).ready.isEmpty)
        try write("finished download", to: source)
        #expect(
            try tracker.inspect([source], now: start.addingTimeInterval(119), delay: 120, suppressions: []).ready
                .isEmpty)
        #expect(
            try tracker.inspect([source], now: start.addingTimeInterval(238), delay: 120, suppressions: []).ready
                .isEmpty)
        #expect(
            try tracker.inspect([source], now: start.addingTimeInterval(239), delay: 120, suppressions: []).ready == [
                source
            ])
        #expect(
            try tracker.inspect([source], now: start.addingTimeInterval(500), delay: 120, suppressions: []).ready
                .isEmpty)
    }

    @Test func savedCorrectionClassifiesIdenticalContentWithoutModel() async throws {
        let root = try workspace()
        let source = root.appending(path: "invoice.txt")
        let evidence = "Invoice 90210, accounting services, total USD 800"
        try write(evidence, to: source)
        let digest = SHA256.hash(data: Data(evidence.utf8)).map { String(format: "%02x", $0) }.joined()
        let correction = OrganizationCorrection(fingerprint: digest, evidence: evidence, category: "Receipts")
        let proposal = try await OrganizationClassifier().propose(
            source, policy: OrganizationPolicy(categories: ["Receipts"]),
            corrections: [correction])
        #expect(proposal.category == "Receipts")
        #expect(proposal.name == "invoice.txt")
        #expect(proposal.reason == "Saved category correction")
    }

    @Test func opaqueNameRulePreservesMeaningfulNames() {
        #expect(OrganizationClassifier.isOpaqueName("IMG_1234"))
        #expect(OrganizationClassifier.isOpaqueName("d52eea39-1663-4df1-a036-f986c181b534"))
        #expect(!OrganizationClassifier.isOpaqueName("Family vacation 2026"))
        #expect(!OrganizationClassifier.isOpaqueName("Invoice_2026-09"))
    }

    @Test func registrationRoundTripKeepsOptInSeparateAndRootIdentity() async throws {
        let root = try workspace()
        let store = OrganizationStore(supportDirectory: root.appending(path: "support"))
        let registration = try OrganizationRegistration(root: root, policy: OrganizationPolicy())
        #expect(!registration.automatic)
        try await store.save([registration])
        var loaded = try #require(await store.load().first)
        #expect(try loaded.resolve().path == root.path)
        #expect(!loaded.automatic)
        #expect(loaded.rootIdentity?.matches(root, directory: true) == true)
    }

    @Test func groupedCommitChecksEverySourceAfterProcessing() async throws {
        let workspace = try workspace()
        let first = workspace.appending(path: "first.txt")
        let second = workspace.appending(path: "second.txt")
        try write("first", to: first)
        try write("second", to: second)
        let firstStamp = try FileStamp(of: first, includingIdentity: true)
        let secondStamp = try FileStamp(of: second, includingIdentity: true)
        let work = WorkItem(inputs: [first, second]) { context in
            let staged = try context.stagingURL(for: first, name: "combined.txt")
            try Data("combined".utf8).write(to: staged)
            try Data("changed by another application".utf8).write(to: second)
            return .groupedDerived(
                destination: first.deletingLastPathComponent().appending(path: "combined.txt"),
                sources: [first: firstStamp, second: secondStamp],
                output: StagedFile(url: staged, name: "combined.txt", check: .text(.utf8)))
        }
        let outcome = await (try engine(workspace)).run(
            Batch(operation: .filesFinish, items: [work]), settings: Settings()
        ) { _ in }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(!FileManager.default.fileExists(atPath: workspace.appending(path: "combined.txt").path))
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
    }
}
