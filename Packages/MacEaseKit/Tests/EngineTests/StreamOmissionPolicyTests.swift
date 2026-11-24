import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite struct StreamOmissionPolicyTests {
    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func requestPolicyNeverApprovesReplacement(mode: Settings.OutputMode) async throws {
        let folder = try TestVolume.makeFolder()
        let source = try await timecodedClip(named: "timecoded.mov", in: folder)
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = mode
        let request = OperationRequest(
            op: .videoConvert, options: .video(.convert(.mp4)), inputs: [source],
            unpreservedStreams: .omitFromNewFiles)
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let phases = Mutex<[ItemPhase]>([])
        let outcome = await engine.run(batch, settings: settings) { progress in
            phases.withLock { $0.append(contentsOf: progress.itemPhases) }
        }
        #expect(outcome.batchID == batch.id)
        #expect(try Data(contentsOf: source) == original)
        if mode == .replace {
            #expect(!phases.withLock { $0.contains(.encoding) })
            #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.timecode])))])
            #expect(outcome.record == nil)
        } else {
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first else {
                Issue.record("Expected a derived result: \(outcome.outcomes)")
                return
            }
            #expect(outputs.count == 1)
            #expect(warnings == [.streamsOmitted([.timecode])])
            #expect(outcome.record?.canUndo == true)
            #expect(await engine.history.records.count == 1)
        }
    }

    @Test func askPolicyRefusesEvenWithTheOmitSetting() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try await timecodedClip(named: "timecoded.mov", in: folder)
        var settings = Settings()
        settings.unpreservedStreams = .omitFromNewFiles
        let request = OperationRequest(op: .videoConvert, options: .video(.convert(.mp4)), inputs: [source])
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.timecode])))])
    }

    @Test func derivedItemsContinueUnderTheGlobalReplaceSetting() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try await timecodedClip(named: "timecoded.mov", in: folder)
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = .replace
        let request = OperationRequest(
            op: .videoThumbnail, options: .video(.still(.edited(VideoEdit(), outputSeconds: 0))), inputs: [source],
            unpreservedStreams: .omitFromNewFiles)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first else {
            Issue.record("Expected a derived thumbnail: \(outcome.outcomes)")
            return
        }
        #expect(outputs.count == 1)
        #expect(warnings.contains(.streamsOmitted([.timecode])))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func mixedEditorItemsUseTheirActualCommitKinds() async throws {
        let folder = try TestVolume.makeFolder()
        let hdrFixture = try #require(
            Bundle.module.url(
                forResource: "x265-hlg.mov", withExtension: nil, subdirectory: "Resources"))
        let hdr = try await timecodedClip(named: "hdr.mov", in: folder, source: hdrFixture)
        let sdr = try await timecodedClip(named: "sdr.mov", in: folder)
        let originals = try [hdr, sdr].map { try Data(contentsOf: $0) }
        var settings = Settings()
        settings.outputMode = .replace
        var edit = VideoEdit(speed: 2)
        edit.adjustments[.exposure] = 0.5
        let request = OperationRequest(
            op: .videoEdit, options: .video(.edit(edit)), inputs: [hdr, sdr], unpreservedStreams: .omitFromNewFiles)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        guard case .succeeded(let outputs, let warnings) = outcome.outcomes[0] else {
            Issue.record("HDR color edits must derive: \(outcome.outcomes)")
            return
        }
        #expect(outputs.count == 1)
        #expect(warnings == [.streamsOmitted([.timecode]), .videoToneMappedToSDR])
        #expect(outcome.outcomes[1] == .failed(.invalidInput(.unpreservedStreams([.timecode]))))
        #expect(try [hdr, sdr].map { try Data(contentsOf: $0) } == originals)
        #expect(outcome.record?.items.count == 1)
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func audioPolicyUsesTheSameEngineRule(mode: Settings.OutputMode) async throws {
        let source = try await AudioStreamOmissionTests().id3Source(frameID: "PRIV")
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = mode
        let request = OperationRequest(
            op: .audioConvert, options: .audio(.convert(.flac)), inputs: [source],
            unpreservedStreams: .omitFromNewFiles)
        let engine = try JobEngine(supportDirectory: try TestVolume.makeFolder(), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        #expect(try Data(contentsOf: source) == original)
        if mode == .replace {
            #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.data])))])
        } else {
            guard case .succeeded(_, [.streamsOmitted([.data])]) = outcome.outcomes.first else {
                Issue.record("Expected consented audio conversion: \(outcome.outcomes)")
                return
            }
        }
    }

    @Test func recipeContinuesAllInspectedKindsInOneBatch() async throws {
        let folder = try TestVolume.makeFolder()
        let timecoded = try await timecodedClip(named: "timecoded.mov", in: folder)
        let chapterSource = try await VideoOperationTests().videoWithExtraTracks(includeChapter: true)
        let chaptered = folder.appending(path: "chaptered.mov")
        try FileManager.default.copyItem(at: chapterSource, to: chaptered)
        let originals = try [timecoded, chaptered].map { try Data(contentsOf: $0) }
        var settings = Settings()
        settings.outputMode = .replace
        let batch = try RecipePlanner.batch(
            recipe: Recipe(name: "Both kinds", variants: [OutputVariant(output: .videoMP4)]),
            inputs: [timecoded, chaptered], destination: folder, settings: settings,
            unpreservedStreams: .omitFromNewFiles)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let outcome = await engine.run(batch, settings: settings) { _ in }
        guard case .succeeded(let packages, let warnings) = outcome.outcomes.first else {
            Issue.record("Expected all kinds to continue together: \(outcome.outcomes)")
            return
        }
        #expect(outcome.batchID == batch.id)
        #expect(warnings == [.streamsOmitted([.timecode, .chapter])])
        let package = try #require(packages.first)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
                == ["chaptered.mp4", "timecoded.mp4"])
        #expect(try [timecoded, chaptered].map { try Data(contentsOf: $0) } == originals)
        #expect(await engine.history.records.count == 1)
        let recipe = Recipe(name: "Both kinds", variants: [OutputVariant(output: .videoMP4)])
        let omissions = try await RecipePlanner.streamOmissions(recipe: recipe, inputs: [timecoded, chaptered])
        let manualBatch = try RecipePlanner.batch(
            recipe: recipe, inputs: [timecoded, chaptered], destination: folder, settings: settings,
            omissions: omissions)
        let manual = await engine.run(manualBatch, settings: settings) { _ in }
        guard case .succeeded(_, let manualWarnings) = manual.outcomes.first else {
            Issue.record("Expected a manual recipe success: \(manual.outcomes)")
            return
        }
        #expect(warnings == manualWarnings)
    }

    @Test func failedItemRetryRetainsTheSubmittedOmissionPolicy() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try await timecodedClip(named: "timecoded.mov", in: folder)
        let settings = Settings()
        let request = OperationRequest(
            op: .videoCompress, options: .video(.compress(VideoCompression(goal: .bytes(1)))), inputs: [source],
            unpreservedStreams: .omitFromNewFiles)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let first = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        guard case .failed(.targetUnreachable) = first.outcomes.first else {
            Issue.record("Expected a real target-size failure: \(first.outcomes)")
            return
        }
        let preset = try #require(settings.platformPresets.first { $0.video != nil })
        var session = ActivitySession(request: request, settings: settings, outcome: first)
        let retry = try session.beginRetry(options: .video(.compress(VideoCompression(goal: .platform(preset)))))
        #expect(retry.unpreservedStreams == .omitFromNewFiles)
        let outcome = await engine.run(session.retryBatch(for: retry), settings: settings) { _ in }
        guard case .succeeded(_, let warnings) = outcome.outcomes.first else {
            Issue.record("Expected retry to retain automatic omission: \(outcome.outcomes)")
            return
        }
        #expect(warnings.contains(.streamsOmitted([.timecode])))
    }

    @Test func continuationReportsPreflightWarningsOnlyOnce() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "source.txt")
        try Data("source".utf8).write(to: source)
        var work = WorkItem(inputs: [source]) { context in
            context.warn(.loudnessLimitedByPeak(reachedLUFS: -18))
            if context.omittedStreams.isEmpty {
                throw EngineError.invalidInput(.unpreservedStreams([.data]))
            }
            let output = try context.stagingURL(for: source, name: "output.txt")
            try Data("output".utf8).write(to: output)
            return .derived(nextTo: source, outputs: [StagedFile(url: output, name: "output.txt", check: .text(.utf8))])
        }
        work.derivesOutput = true
        work.unpreservedStreams = .omitFromNewFiles
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let outcome = await engine.run(Batch(operation: .audioNormalize, items: [work]), settings: Settings()) { _ in }
        guard case .succeeded(_, let warnings) = outcome.outcomes.first else {
            Issue.record("Expected a derived result")
            return
        }
        #expect(warnings == [.loudnessLimitedByPeak(reachedLUFS: -18), .streamsOmitted([.data])])
    }

    @Test(arguments: [false, true])
    func lateRefusalNeverRunsAnEncoderAgain(reportsEncoding: Bool) async throws {
        let folder = try TestVolume.makeFolder()
        let attempts = Mutex(0)
        var work = WorkItem(inputs: []) { context in
            attempts.withLock { $0 += 1 }
            if reportsEncoding {
                context.phase(.encoding)
            } else {
                let output = try context.stagingURL(for: folder, name: "encoded.txt")
                try Data("encoded".utf8).write(to: output)
            }
            throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
        }
        work.derivesOutput = true
        work.unpreservedStreams = .omitFromNewFiles
        let engine = try JobEngine(supportDirectory: folder, concurrency: 1)
        let outcome = await engine.run(Batch(operation: .filesFinish, items: [work]), settings: Settings()) { _ in }
        #expect(attempts.withLock { $0 } == 1)
        #expect(outcome.outcomes == [.failed(.invalidInput(.unpreservedStreams([.timecode])))])
    }

    @Test func changedSourceIsReinspectedAndManualConsentUsesItsNewStamp() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "source.txt")
        try Data("first".utf8).write(to: source)
        let replaced = Mutex(false)
        var work = WorkItem(inputs: [source]) { context in
            if context.omittedStreams.isEmpty {
                if replaced.withLock({ flag in
                    defer { flag = true }; return !flag
                }) {
                    try Data("replacement".utf8).write(to: source, options: .atomic)
                }
                throw EngineError.invalidInput(.unpreservedStreams([.data]))
            }
            let staged = try context.stagingURL(for: source, name: "output.txt")
            try Data(contentsOf: source).write(to: staged)
            return .derived(nextTo: source, outputs: [StagedFile(url: staged, name: "output.txt", check: .text(.utf8))])
        }
        work.derivesOutput = true
        work.unpreservedStreams = .omitFromNewFiles
        let engine = try JobEngine(supportDirectory: folder.appending(path: "engine"), concurrency: 1)
        let request = OperationRequest(op: .videoConvert, options: .video(.convert(.mp4)), inputs: [source])
        let first = await engine.run(Batch(operation: .videoConvert, items: [work]), settings: Settings()) { _ in }
        #expect(first.outcomes == [.failed(.invalidInput(.unpreservedStreams([.data])))])
        #expect(first.record == nil)
        var session = ActivitySession(request: request, settings: Settings(), outcome: first)
        let retry = try session.beginRetry(omittingStreams: [.data])
        #expect(retry.inputs == [source])
        work.requiredInputStamps = first.details[0].inputStamps
        work.omittedStreams = retry.omittedStreams
        let second = await engine.run(Batch(operation: .videoConvert, items: [work]), settings: Settings()) { _ in }
        guard case .succeeded = second.outcomes.first else {
            Issue.record("Manual consent must work")
            return
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
    }
}
