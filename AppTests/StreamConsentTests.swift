import AVFoundation
import AppKit
import CoreMedia
import MenuCatalog
import XCTest

@testable import Engine
@testable import MacEase

@MainActor
final class StreamConsentTests: XCTestCase {
    func testActivityAsksOnlyAboutAffectedFilesAndResubmitsExactlyThoseKinds() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let plain = directory.appending(path: "plain.mp4")
        try FileManager.default.copyItem(at: try fixture(), to: plain)
        let original = try Data(contentsOf: timecoded)
        let (jobs, activity, store) = try makeActivity(in: directory)
        store.activityClosesAfterFailure = true

        let first = try await runSpeed([timecoded, plain], jobs: jobs, settings: store.planning)
        guard case .failed(.invalidInput(.unpreservedStreams([.timecode]))) = first.outcomes[0],
            case .succeeded = first.outcomes[1]
        else { return XCTFail("unexpected outcomes \(first.outcomes)") }

        let session = try XCTUnwrap(jobs.sessions[first.batchID])
        let result = ActivityResult(first, awaitingConsent: session)
        XCTAssertTrue(result.problems.isEmpty, "a question is not a failure")
        XCTAssertFalse(result.isFailure)
        XCTAssertEqual(result.confirmations.map(\.file), ["timecoded.mov"])
        XCTAssertEqual(result.summary, "Done. 1 file needs your confirmation.")
        XCTAssertTrue(jobs.canContinueWithoutStreams(first.batchID))
        XCTAssertFalse(jobs.canRetry(first.batchID), "a plain retry would only fail again")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "MacEase Activity" })
        XCTAssertTrue(panel.isVisible, "a pending choice stays visible despite closing after failure")
        XCTAssertEqual(try Data(contentsOf: timecoded), original)
        XCTAssertEqual(try files(in: directory), ["engine", "plain.mp4", "plain_speed2x.mp4", "timecoded.mov"])

        let retried = try await continueAndWait(first.batchID, jobs: jobs)
        XCTAssertEqual(retried.request.inputs, [timecoded])
        XCTAssertEqual(retried.request.omittedStreams, [.timecode])
        guard case .succeeded(let outputs, let warnings) = retried.outcome.outcomes.first else {
            return XCTFail("consented retry failed: \(retried.outcome.outcomes)")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.timecode])])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try Data(contentsOf: timecoded), original)
        XCTAssertFalse(jobs.canContinueWithoutStreams(first.batchID), "one consent runs once")
        XCTAssertTrue(jobs.continuedWithoutStreams.contains(first.batchID))
        activity.dismissBatch(first.batchID)
    }

    func testDismissingTheQuestionWritesNothing() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let original = try Data(contentsOf: timecoded)
        let (jobs, activity, store) = try makeActivity(in: directory)
        let first = try await runSpeed([timecoded], jobs: jobs, settings: store.planning)
        XCTAssertTrue(jobs.canContinueWithoutStreams(first.batchID))
        let known = Set(jobs.sessions.keys)

        activity.dismissBatch(first.batchID)
        XCTAssertFalse(jobs.canContinueWithoutStreams(first.batchID))
        jobs.continueWithoutStreams(first.batchID)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(jobs.active.isEmpty)
        XCTAssertEqual(Set(jobs.sessions.keys), known.subtracting([first.batchID]))
        XCTAssertEqual(try Data(contentsOf: timecoded), original)
        XCTAssertEqual(try files(in: directory), ["engine", "timecoded.mov"])
    }

    func testEveryAffectedFileIsShownAndOnlyThoseAreResubmitted() async throws {
        let directory = try workspace()
        let source = try await timecodedClip(in: directory)
        let clips = try (1...6).map { index in
            let clip = directory.appending(path: "clip-\(index).mov")
            try FileManager.default.copyItem(at: source, to: clip)
            return clip
        }
        try FileManager.default.removeItem(at: source)
        let (jobs, activity, store) = try makeActivity(in: directory)
        let first = try await runSpeed(clips, jobs: jobs, settings: store.planning)
        let session = try XCTUnwrap(jobs.sessions[first.batchID])
        let result = ActivityResult(first, awaitingConsent: session)
        XCTAssertEqual(result.status, .awaitingConfirmation)
        XCTAssertEqual(result.statusText, "6 files need your confirmation.")
        XCTAssertEqual(result.confirmations.map(\.file), clips.map(\.lastPathComponent))
        XCTAssertTrue(result.confirmations.allSatisfy { $0.streams == [.timecode] })

        let retried = try await continueAndWait(first.batchID, jobs: jobs)
        XCTAssertEqual(retried.request.inputs, clips)
        XCTAssertEqual(retried.outcome.outcomes.count, 6)
        XCTAssertTrue(retried.outcome.outcomes.allSatisfy { if case .succeeded = $0 { true } else { false } })
        activity.dismissBatch(first.batchID)
    }

    func testRealFailuresStayDistinctFromQuestionsAndRetryFailedSkipsQuestions() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let broken = directory.appending(path: "broken.mov")
        try (Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8) + Data(repeating: 0, count: 2_048)).write(to: broken)
        let (jobs, activity, store) = try makeActivity(in: directory)
        store.settings.outputMode = .newFile
        let options = try XCTUnwrap(
            OperationPlanner.options(for: .videoConvert, preset: "mp4", settings: store.planning))
        let outcome = await jobs.run(
            OperationRequest(op: .videoConvert, options: options, inputs: [broken, timecoded])
        ).value
        let first = try XCTUnwrap(outcome)
        let session = try XCTUnwrap(jobs.sessions[first.batchID])
        XCTAssertEqual(session.failedIndices, [0], "Retry Failed covers the real failure only")

        let result = ActivityResult(first, awaitingConsent: session)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.confirmations.map(\.file), ["timecoded.mov"])
        XCTAssertEqual(result.statusText, "Finished with 1 problem.")
        XCTAssertEqual(result.summary, "Finished with 1 problem. 1 file needs your confirmation.")
        activity.dismissBatch(first.batchID)
    }

    func testConsentedReplaceUndoRestoresTheOriginalWithItsTimecode() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let original = try Data(contentsOf: timecoded)
        let (jobs, activity, store) = try makeActivity(in: directory)
        store.settings.outputMode = .replace
        let first = try await runSpeed([timecoded], jobs: jobs, settings: store.planning)
        let session = try XCTUnwrap(jobs.sessions[first.batchID])
        XCTAssertEqual(
            UserMessages.streamOmissionConsequence(
                files: ActivityResult(first, awaitingConsent: session).confirmations.map(\.file),
                replacesOriginals: session.replacesOriginals),
            "If you continue, “timecoded.mov” is replaced. The original moves to the Trash, and you can undo this.")

        let retried = try await continueAndWait(first.batchID, jobs: jobs)
        guard case .succeeded = retried.outcome.outcomes.first else {
            return XCTFail("consented replace failed: \(retried.outcome.outcomes)")
        }
        XCTAssertNotEqual(try Data(contentsOf: timecoded), original)
        let rotated = try await AVURLAsset(url: timecoded).loadTracks(withMediaType: .timecode)
        XCTAssertTrue(rotated.isEmpty)

        jobs.undo(retried.outcome.batchID)
        try await eventually { (try? Data(contentsOf: timecoded)) == original }
        let restored = try await AVURLAsset(url: timecoded).loadTracks(withMediaType: .timecode)
        XCTAssertEqual(restored.count, 1)
        activity.dismissBatch(first.batchID)
    }

    func testEnglishConsentTextIsSpecificAndPlain() throws {
        XCTAssertEqual(
            UserMessages.streamsStatement(file: "a.mov", streams: [.timecode]),
            "“a.mov” contains timecode, which MacEase can’t carry over.")
        XCTAssertEqual(
            UserMessages.streamsStatement(file: "b.mkv", streams: [.audio, .subtitle]),
            "“b.mkv” contains extra audio and subtitles, which MacEase can’t carry over.")
        XCTAssertEqual(
            UserMessages.consequence(of: .timecode),
            "Timecode: editing apps use it to line up clips. Leaving it out doesn’t affect picture or sound.")
        XCTAssertEqual(UserMessages.consequence(of: .audio), "Extra audio: only the first audio track is kept.")
        XCTAssertEqual(UserMessages.confirmationCount(1), "1 file needs your confirmation.")
        XCTAssertEqual(UserMessages.confirmationCount(6), "6 files need your confirmation.")
        XCTAssertEqual(UserMessages.continueWithout([.timecode]), "Continue Without Timecode")
        XCTAssertEqual(
            UserMessages.continueWithout([.subtitle, .timecode]), "Continue Without Subtitles and Timecode")
        XCTAssertEqual(UserMessages.continueWithout([.subtitle, .timecode, .chapter]), "Continue Without Them")
        XCTAssertEqual(
            UserMessages.streamOmissionConsequence(files: ["a.mov"], replacesOriginals: false),
            "If you continue, a new file is made and “a.mov” stays as it is.")
        XCTAssertEqual(
            UserMessages.streamOmissionConsequence(files: ["a.mov", "b.mov"], replacesOriginals: true),
            "If you continue, these 2 files are replaced. The originals move to the Trash, and you can undo this.")
        XCTAssertEqual(
            UserMessages.streamOmissionConsequence(files: ["a.mov", "b.mov"], replacesOriginals: false),
            "If you continue, new files are made and the originals stay as they are.")
        XCTAssertEqual(
            UserMessages.continuedWithout([.timecode]), "Continued without timecode. The new result is below.")
        XCTAssertEqual(UserMessages.describe(.streamsOmitted([.timecode])), "Left out, as you confirmed: timecode.")
        XCTAssertEqual(
            UserMessages.describe(.invalidInput(.unpreservedStreams([.timecode, .chapter])), file: "clip.mov"),
            "Couldn’t process “clip.mov”: it contains timecode and chapters, which MacEase can’t carry over. Nothing was changed."
        )

        let directory = try workspace()
        let files = try ["a.mov", "Interview B-roll.mov"].map { name in
            let url = directory.appending(path: name)
            try Data("video".utf8).write(to: url)
            return StreamConsentRequest.File(
                url: url, omission: StreamOmission(stamp: try MediaSourceStamp(url: url), streams: [.timecode]))
        }
        let single = StreamConsentRequest(purpose: .open, files: [files[0]])
        XCTAssertEqual(single.title, "Open “a.mov” without timecode?")
        XCTAssertEqual(
            single.message,
            """
            “a.mov” contains timecode, which MacEase can’t carry over.

            Timecode: editing apps use it to line up clips. Leaving it out doesn’t affect picture or sound.

            Opening doesn’t change “a.mov”.
            """)
        XCTAssertEqual(single.actionTitle, "Open Without Timecode")
        let batch = StreamConsentRequest(purpose: .proceed, files: files)
        XCTAssertEqual(batch.title, "Continue without timecode?")
        XCTAssertEqual(
            batch.message,
            """
            These files contain content MacEase can’t carry over:
            “a.mov”: timecode
            “Interview B-roll.mov”: timecode

            Timecode: editing apps use it to line up clips. Leaving it out doesn’t affect picture or sound.

            Your originals stay as they are.
            """)
        XCTAssertEqual(batch.actionTitle, "Continue Without Timecode")
        XCTAssertEqual(
            StreamConsentRequest(purpose: .add(files.map(\.url)), files: files).title,
            "Add 2 videos without content MacEase can’t carry over?")
    }

    func testJapaneseConsentTextIsTranslated() throws {
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        func ja(_ key: String) -> String { japanese.localizedString(forKey: key, value: nil, table: nil) }
        XCTAssertEqual(
            String(format: ja("“%@” contains %@, which MacEase can’t carry over."), "a.mov", ja("timecode")),
            "“a.mov” にはタイムコードが含まれていますが、MacEase では引き継げません。")
        XCTAssertEqual(
            ja("Timecode: editing apps use it to line up clips. Leaving it out doesn’t affect picture or sound."),
            "タイムコード：編集アプリがクリップの位置合わせに使う情報です。省いても映像と音声には影響しません。")
        XCTAssertEqual(ja("Extra audio: only the first audio track is kept."), "2本目以降の音声トラック：最初の音声トラックだけが残ります。")
        XCTAssertEqual(ja("Subtitles: they can no longer be turned on during playback."), "字幕：再生中に表示できなくなります。")
        XCTAssertEqual(ja("Chapters: you can no longer jump from chapter to chapter."), "チャプター：チャプター単位で移動できなくなります。")
        XCTAssertEqual(ja("1 file needs your confirmation."), "確認が必要なファイルが 1 件あります。")
        XCTAssertEqual(String(format: ja("%lld files need your confirmation."), 6), "確認が必要なファイルが 6 件あります。")
        XCTAssertEqual(String(format: ja("Continue Without %@"), ja("timecode")), "タイムコードなしで続ける")
        XCTAssertEqual(ja("Continue Without Them"), "これらを省いて続ける")
        XCTAssertEqual(
            String(
                format: ja(
                    "If you continue, “%@” is replaced. The original moves to the Trash, and you can undo this."),
                "a.mov"),
            "続けると、“a.mov” は置き換えられます。元のファイルはゴミ箱に移動し、取り消すこともできます。")
        XCTAssertEqual(
            String(format: ja("If you continue, a new file is made and “%@” stays as it is."), "a.mov"),
            "続けると新しいファイルが作られ、“a.mov” はそのまま残ります。")
        XCTAssertEqual(
            String(format: ja("Open “%@” without %@?"), "a.mov", ja("timecode")), "“a.mov” をタイムコードなしで開きますか？")
        XCTAssertEqual(
            String(format: ja("Continued without %@. The new result is below."), ja("timecode")),
            "タイムコードを省いて続けました。新しい結果は下に表示されています。")
        XCTAssertEqual(
            String(
                format: ja(
                    "Couldn’t process “%@”: it contains %@, which MacEase can’t carry over. Nothing was changed."),
                "clip.mov", ja("timecode")),
            "“clip.mov” を処理できませんでした：タイムコードが含まれていますが、MacEase では引き継げません。ファイルは変更されていません。")
        XCTAssertEqual(String(format: ja("Left out, as you confirmed: %@."), ja("timecode")), "確認したとおり省きました：タイムコード。")
    }

    func testConsequencesMatchEveryOperationInBothLanguages() throws {
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        let cases: [(OperationID, String, String, String, String)] = [
            (
                .videoRemoveAudio, "Extra audio: all audio tracks are removed.", "2本目以降の音声トラック：すべての音声トラックが削除されます。",
                "Extra video: only the first video track is kept.", "2本目以降の映像トラック：最初の映像トラックだけが残ります。"
            ),
            (
                .videoExtractAudio, "Extra audio: only the first audio track is kept.",
                "2本目以降の音声トラック：最初の音声トラックだけが残ります。", "Extra video: the output contains no video tracks.",
                "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .videoThumbnail, "Extra audio: the output contains no audio tracks.", "2本目以降の音声トラック：出力に音声トラックは含まれません。",
                "Extra video: only the first video track is used to create the output.",
                "2本目以降の映像トラック：最初の映像トラックだけを使って出力を作成します。"
            ),
            (
                .videoToGIF, "Extra audio: the output contains no audio tracks.", "2本目以降の音声トラック：出力に音声トラックは含まれません。",
                "Extra video: only the first video track is used to create the output.",
                "2本目以降の映像トラック：最初の映像トラックだけを使って出力を作成します。"
            ),
            (
                .videoToAPNG, "Extra audio: the output contains no audio tracks.", "2本目以降の音声トラック：出力に音声トラックは含まれません。",
                "Extra video: only the first video track is used to create the output.",
                "2本目以降の映像トラック：最初の映像トラックだけを使って出力を作成します。"
            ),
            (
                .videoToAnimatedWebP, "Extra audio: the output contains no audio tracks.",
                "2本目以降の音声トラック：出力に音声トラックは含まれません。",
                "Extra video: only the first video track is used to create the output.",
                "2本目以降の映像トラック：最初の映像トラックだけを使って出力を作成します。"
            ),
            (
                .videoSubtitles, "Extra audio: the output contains no audio tracks.", "2本目以降の音声トラック：出力に音声トラックは含まれません。",
                "Extra video: the output contains no video tracks.", "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .audioSubtitles, "Extra audio: the output contains no audio tracks.", "2本目以降の音声トラック：出力に音声トラックは含まれません。",
                "Extra video: the output contains no video tracks.", "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .videoEdit, "Extra audio: only the first audio track is kept.", "2本目以降の音声トラック：最初の音声トラックだけが残ります。",
                "Extra video: only the first video track is kept.", "2本目以降の映像トラック：最初の映像トラックだけが残ります。"
            ),
            (
                .filesFinish, "Extra audio: only the first audio track is kept.", "2本目以降の音声トラック：最初の音声トラックだけが残ります。",
                "Extra video: only the first video track is kept.", "2本目以降の映像トラック：最初の映像トラックだけが残ります。"
            ),
            (
                .audioConvert, "Extra audio: only the first audio track is kept.", "2本目以降の音声トラック：最初の音声トラックだけが残ります。",
                "Extra video: the output contains no video tracks.", "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .audioCompress, "Extra audio: only the first audio track is kept.", "2本目以降の音声トラック：最初の音声トラックだけが残ります。",
                "Extra video: the output contains no video tracks.", "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .audioNormalize, "Extra audio: only the first audio track is kept.", "2本目以降の音声トラック：最初の音声トラックだけが残ります。",
                "Extra video: the output contains no video tracks.", "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .audioTrim, "Extra audio: only the first audio track is kept.", "2本目以降の音声トラック：最初の音声トラックだけが残ります。",
                "Extra video: the output contains no video tracks.", "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
            (
                .audioEnhance, "Extra audio: only the first audio track is used to create the output.",
                "2本目以降の音声トラック：最初の音声トラックだけを使って出力を作成します。", "Extra video: the output contains no video tracks.",
                "2本目以降の映像トラック：出力に映像トラックは含まれません。"
            ),
        ]
        let shared: [(UnpreservedStream, String, String)] = [
            (.subtitle, "Subtitles: they can no longer be turned on during playback.", "字幕：再生中に表示できなくなります。"),
            (
                .closedCaption, "Closed captions: they can no longer be turned on during playback.",
                "クローズドキャプション：再生中に表示できなくなります。"
            ),
            (
                .timecode,
                "Timecode: editing apps use it to line up clips. Leaving it out doesn’t affect picture or sound.",
                "タイムコード：編集アプリがクリップの位置合わせに使う情報です。省いても映像と音声には影響しません。"
            ),
            (.chapter, "Chapters: you can no longer jump from chapter to chapter.", "チャプター：チャプター単位で移動できなくなります。"),
            (
                .attachment, "Attachments: files stored inside, such as cover art or fonts, are left out.",
                "添付ファイル：カバー画像やフォントなど、ファイル内に保存されたものは含まれません。"
            ),
            (
                .metadata, "Timed metadata: details that change over time, such as location, are left out.",
                "時系列のメタデータ：位置情報など、時間とともに変わる情報は含まれません。"
            ),
            (
                .data, "Other data: things like markers or sensor readings are left out. Most players don’t use them.",
                "その他のデータ：マーカーやセンサーの記録などは含まれません。多くの再生アプリでは使われない情報です。"
            ),
        ]
        for (operation, audio, japaneseAudio, video, japaneseVideo) in cases {
            let expected: [(UnpreservedStream, String, String)] =
                shared + [
                    (.audio, audio, japaneseAudio), (.video, video, japaneseVideo),
                ]
            for (stream, english, translation) in expected {
                let message = UserMessages.consequence(of: stream, operation: operation)
                XCTAssertEqual(message, english, "\(operation): \(stream)")
                XCTAssertEqual(japanese.localizedString(forKey: message, value: nil, table: nil), translation)
            }
        }
    }

    func testEditorAsksBeforeOpeningAndSavesWithTheSameConsent() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let model = MediaEditorModel(
            urls: [timecoded], isVideo: true, settings: Engine.Settings(), staging: try staging(in: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.streamConsent != nil || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.ready)
        let request = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(request.purpose, .open)
        XCTAssertEqual(request.files.map(\.url), [timecoded])
        XCTAssertEqual(request.streams, [.timecode])
        XCTAssertEqual(request.title, "Open “timecoded.mov” without timecode?")
        XCTAssertEqual(request.actionTitle, "Open Without Timecode")

        model.continueWithoutStreams(request)
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertNil(model.streamConsent, "the same file is not asked about twice")
        XCTAssertNotNil(model.omittedStreamsNote)
        model.change { $0.photo.geometry.quarterTurns = 1 }
        let planned = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(planned.batch.items.map(\.omittedStreams), [[.timecode]])
        XCTAssertEqual(
            planned.batch.items.first?.requiredInputStamps?[timecoded],
            request.files.first?.omission.stamp.fileStamp)
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let saved = await engine.run(planned.batch, settings: planned.settings) { _ in }
        guard case .succeeded(_, let warnings) = saved.outcomes.first else {
            return XCTFail("editor save failed: \(saved.outcomes)")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.timecode])])
        let original = try Data(contentsOf: timecoded)
        await model.saveFrame { batch, settings in
            Task { await engine.run(batch, settings: settings) { _ in } }
        }
        guard case .saved(let frame) = model.frameNote else {
            return XCTFail("consented single-video frame save failed: \(String(describing: model.frameNote))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: frame.path))
        XCTAssertEqual(try Data(contentsOf: timecoded), original)
    }

    func testEditorAsksBeforeAddingAVideoThatLosesStreams() async throws {
        let directory = try workspace()
        let plain = directory.appending(path: "plain.mp4")
        try FileManager.default.copyItem(at: try fixture(), to: plain)
        let timecoded = try await timecodedClip(in: directory)
        let model = MediaEditorModel(
            urls: [plain], isVideo: true, settings: Engine.Settings(), staging: try staging(in: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.omittedStreamsNote)

        model.importVideos([timecoded])
        try await eventually { model.streamConsent != nil || model.failure != nil }
        let request = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(request.purpose, .add([timecoded]))
        XCTAssertEqual(model.values.sources.count, 1, "declining leaves the timeline unchanged")

        model.continueWithoutStreams(request)
        try await eventually { model.values.sources.count == 2 || model.failure != nil }
        XCTAssertNil(model.failure)
        try await eventually { model.canSave || model.failure != nil }
        XCTAssertNil(model.failure, "the joined preview keeps the consented omission")
        let original = try Data(contentsOf: timecoded)
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let planned = try model.makeSave(replacingOriginal: false)
        let saved = await engine.run(planned.batch, settings: planned.settings) { _ in }
        guard case .succeeded(let outputs, _) = saved.outcomes.first else {
            return XCTFail("consented joined save failed: \(saved.outcomes)")
        }
        XCTAssertEqual(outputs.count, 1)
        model.seek(model.values.segments[0].outputDuration + 0.1)
        await model.saveFrame { batch, settings in
            Task { await engine.run(batch, settings: settings) { _ in } }
        }
        guard case .saved(let frame) = model.frameNote else {
            return XCTFail("consented frame save failed: \(String(describing: model.frameNote))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: frame.path))
        model.selectSegment(try XCTUnwrap(model.values.segments.last).id)
        model.toggleReverse()
        try await eventually { model.reverseProgress == nil }
        XCTAssertNil(model.reverseFailure)
        XCTAssertTrue(model.selectedSegment?.isReversed == true)
        XCTAssertEqual(try Data(contentsOf: timecoded), original)
    }

    func testAudioTrimAsksBeforeOpeningAndTrimsWithTheSameConsent() async throws {
        let directory = try workspace()
        let audio = try waveWithCuePoints(in: directory)
        let model = AudioTrimModel(url: audio, staging: try staging(in: directory), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.ready)
        let request = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(request.files.map(\.url), [audio])
        XCTAssertEqual(request.operation, .audioTrim)
        XCTAssertEqual(request.streams, [.data])

        model.continueWithoutStreams(request)
        try await eventually { model.ready || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.omittedStreams, [.data])
        let trim = OperationRequest(
            op: .audioTrim, options: .audio(.trim(start: 0, end: model.duration / 2, fadeIn: 0, fadeOut: 0)),
            inputs: [audio], omittedStreams: model.omittedStreams)
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let settings = Engine.Settings()
        let outcome = await engine.run(OperationPlanner.batch(for: trim, settings: settings), settings: settings) {
            _ in
        }
        guard case .succeeded(_, let warnings) = outcome.outcomes.first else {
            return XCTFail("trim failed: \(outcome.outcomes)")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.data])])
    }

    func testEditorAsksAgainWhenTheFileIsReplacedWhileAsking() async throws {
        let directory = try workspace()
        let timecoded = try await timecodedClip(in: directory)
        let model = MediaEditorModel(
            urls: [timecoded], isVideo: true, settings: Engine.Settings(), staging: try staging(in: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.streamConsent != nil || model.failure != nil }
        let shown = try XCTUnwrap(model.streamConsent)

        let replacement = try await timecodedClip(in: try workspace())
        try FileManager.default.removeItem(at: timecoded)
        try FileManager.default.copyItem(at: replacement, to: timecoded)
        model.continueWithoutStreams(shown)
        try await eventually { model.streamConsent != nil || model.canPlay || model.failure != nil }
        XCTAssertFalse(model.canPlay, "consent for the old file must not open the new one")
        let asked = try XCTUnwrap(model.streamConsent)
        XCTAssertNotEqual(asked.files.map(\.omission.stamp), shown.files.map(\.omission.stamp))

        model.continueWithoutStreams(asked)
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.failure)
    }

    func testAudioTrimAsksAgainWhenTheFileIsReplacedWhileAsking() async throws {
        let directory = try workspace()
        let audio = try waveWithCuePoints(in: directory)
        let model = AudioTrimModel(url: audio, staging: try staging(in: directory), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        let shown = try XCTUnwrap(model.streamConsent)

        let replacement = try Data(contentsOf: audio)
        try FileManager.default.removeItem(at: audio)
        try replacement.write(to: audio)
        model.continueWithoutStreams(shown)
        try await eventually { model.streamConsent != nil || model.ready || model.failure != nil }
        XCTAssertFalse(model.ready)
        XCTAssertTrue(model.omittedStreams.isEmpty)
        let asked = try XCTUnwrap(model.streamConsent)
        XCTAssertNotEqual(asked.files.map(\.omission.stamp), shown.files.map(\.omission.stamp))
    }

    func testAudioTrimRunRefusesAnOriginalReplacedAfterPreview() async throws {
        let directory = try workspace()
        let audio = try waveWithCuePoints(in: directory)
        let model = AudioTrimModel(url: audio, staging: try staging(in: directory), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        model.continueWithoutStreams(try XCTUnwrap(model.streamConsent))
        try await eventually { model.ready || model.failure != nil }
        model.changeRange(start: 0, end: model.duration / 2)
        let trim = try model.trimRequest()
        XCTAssertEqual(trim.omittedStreams, [.data])

        var replacement = try Data(contentsOf: audio)
        replacement[44] ^= 0x7F
        try FileManager.default.removeItem(at: audio)
        try replacement.write(to: audio)
        var settings = Engine.Settings()
        settings.outputMode = .replace
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let outcome = await engine.run(OperationPlanner.batch(for: trim, settings: settings), settings: settings) {
            _ in
        }
        XCTAssertEqual(outcome.outcomes, [.failed(.retryInputChanged)])
        let validReplacement = try AVAudioFile(forReading: audio)
        let samples = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: validReplacement.processingFormat, frameCapacity: 8_000))
        try validReplacement.read(into: samples)
        XCTAssertEqual(samples.frameLength, 8_000)
        let history = await engine.history.records
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(outcome.record)
        XCTAssertEqual(try Data(contentsOf: audio), replacement)
        XCTAssertEqual(try files(in: directory), ["cues.wav", "engine", "support"])
    }

    func testAudioEnhancementAsksFirstAndCarriesTheConsentIntoTheRun() async throws {
        let directory = try workspace()
        let source = directory.appending(path: "two-voices.ogg")
        let ffmpeg = Process()
        ffmpeg.executableURL = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "media-tools/bin/ffmpeg")
        ffmpeg.arguments = [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-f", "lavfi", "-i",
            "sine=frequency=660:duration=1", "-map", "0", "-map", "1", "-c:a", "libopus", source.path,
        ]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        XCTAssertEqual(ffmpeg.terminationStatus, 0)
        var submitted: [Batch] = []
        let model = AudioEnhancementModel(source: source) { submitted.append($0) }

        model.enhance()
        try await eventually { model.streamConsent != nil || model.failure != nil }
        let declined = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(declined.purpose, .proceed)
        XCTAssertEqual(declined.operation, .audioEnhance)
        XCTAssertEqual(declined.streams, [.audio])
        model.streamConsent = nil
        XCTAssertTrue(submitted.isEmpty, "declining submits nothing")

        model.enhance()
        try await eventually { model.streamConsent != nil || model.failure != nil }
        model.continueWithoutStreams(try XCTUnwrap(model.streamConsent))
        XCTAssertEqual(submitted.map { $0.items.map(\.omittedStreams) }, [[[.audio]]])
        XCTAssertTrue(model.submitted)
    }

    private func runSpeed(_ inputs: [URL], jobs: JobCenter, settings: Engine.Settings) async throws -> BatchOutcome {
        let options = try XCTUnwrap(OperationPlanner.options(for: .videoSpeed, preset: "2", settings: settings))
        let outcome = await jobs.run(OperationRequest(op: .videoSpeed, options: options, inputs: inputs)).value
        return try XCTUnwrap(outcome)
    }

    private func continueAndWait(_ id: UUID, jobs: JobCenter) async throws -> ActivitySession {
        let known = Set(jobs.sessions.keys)
        jobs.continueWithoutStreams(id)
        try await eventually { jobs.sessions.keys.contains { !known.contains($0) } }
        return try XCTUnwrap(jobs.sessions.first { !known.contains($0.key) }?.value)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func makeActivity(in directory: URL) throws -> (JobCenter, ActivityWindow, SettingsStore) {
        let suite = "MacEaseStreamConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.notificationsEnabled = false
        let engine = try JobEngine(supportDirectory: directory.appending(path: "engine"), concurrency: 1)
        let notifier = BatchNotifier(settings: store)
        let jobs = JobCenter(engine: engine, settings: store, notifier: notifier)
        let activity = ActivityWindow(jobs: jobs, settings: store, notifier: notifier)
        jobs.onStart = { [weak activity] in activity?.started($0) }
        jobs.showsFinished = { [weak activity] in activity?.finished($0, outcome: $1) ?? false }
        return (jobs, activity, store)
    }

    func testRecipeLateTimecodeRefusalReturnsToConsentAndCompletes() async throws {
        let directory = try workspace()
        let source = try await timecodedClip(in: directory)
        let original = try Data(contentsOf: source)
        let (jobs, _, store) = try makeActivity(in: directory)
        let recipe = Recipe(name: "Native Recipe", variants: [OutputVariant(output: .videoMOV)])
        var attempts = 0
        var completed = false
        var lastOutcome: BatchOutcome?
        let model = RecipeRunModel(
            inputs: [source], settings: store.planning,
            onRun: { batch in
                attempts += 1
                let submitted: Batch
                if attempts == 1, let work = batch.items.first {
                    let failing = WorkItem(inputs: work.inputs, lane: work.lane) { context in
                        _ = try await work.body(context)
                        throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
                    }
                    submitted = Batch(
                        operation: batch.operation, items: [failing], recipeExecution: batch.recipeExecution)
                } else {
                    submitted = batch
                }
                let outcome = await jobs.run(batch: submitted, settings: store.planning).value
                lastOutcome = outcome
                return outcome
            }, onComplete: { completed = true })
        await model.run(recipe, destination: directory)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(completed)
        XCTAssertNil(model.failure)
        let question = try XCTUnwrap(model.streamConsent)
        XCTAssertEqual(question.files.map(\.url), [source])
        XCTAssertEqual(question.streams, [.timecode])
        XCTAssertEqual(question.files.first?.omission.stamp, try MediaSourceStamp(url: source))
        await model.continueWithoutStreams(question)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(completed)
        XCTAssertNil(model.streamConsent)
        XCTAssertNil(model.failure)
        guard case .succeeded(let packages, let warnings) = lastOutcome?.outcomes.first else {
            return XCTFail("expected consented recipe success")
        }
        XCTAssertEqual(warnings, [.streamsOmitted([.timecode])])
        let package = try XCTUnwrap(packages.first)
        let output = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil).first {
                $0.pathExtension == "mov"
            })
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .timecode)
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRecipeRecoveryConsentRejectsAReplacedInput() async throws {
        let directory = try workspace()
        let source = try await timecodedClip(in: directory)
        let (jobs, _, store) = try makeActivity(in: directory)
        var attempts = 0
        let model = RecipeRunModel(
            inputs: [source], settings: store.planning,
            onRun: { batch in
                attempts += 1
                let failing = WorkItem(inputs: [source]) { _ in
                    throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
                }
                return await jobs.run(
                    batch: Batch(operation: batch.operation, items: [failing]), settings: store.planning
                ).value
            }, onComplete: { XCTFail("changed source must not complete") })
        await model.run(
            Recipe(name: "Stamped Recipe", variants: [OutputVariant(output: .videoMOV)]), destination: directory)
        let question = try XCTUnwrap(model.streamConsent)
        let replacement = try await timecodedClip(in: try workspace())
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: replacement, to: source)
        await model.continueWithoutStreams(question)
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(model.failure)
        XCTAssertNil(model.streamConsent)
    }

    func testRecipeWriterFailuresDoNotBecomeTimecodeQuestions() async throws {
        let directory = try workspace()
        let source = try await timecodedClip(in: directory)
        let (jobs, _, store) = try makeActivity(in: directory)
        let model = RecipeRunModel(
            inputs: [source], settings: store.planning,
            onRun: { batch in
                let failing = WorkItem(inputs: [source]) { _ in throw EngineError.encodeFailed("Disk is full") }
                return await jobs.run(
                    batch: Batch(operation: batch.operation, items: [failing]), settings: store.planning
                ).value
            }, onComplete: { XCTFail("writer failure must not complete") })
        await model.run(
            Recipe(name: "Failed Recipe", variants: [OutputVariant(output: .videoMOV)]), destination: directory)
        XCTAssertNil(model.streamConsent)
        XCTAssertNotNil(model.failure)
        XCTAssertTrue(model.failure?.contains("Disk is full") == true)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4"))
    }

    private func staging(in directory: URL) throws -> StagingArea {
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        return StagingArea(supportDirectory: support)
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the consent flow")
    }

    /// A trim cannot keep cue chunks.
    private func waveWithCuePoints(in directory: URL) throws -> URL {
        let sampleRate: UInt32 = 8_000
        let samples = (0..<Int(sampleRate)).map { Int16(sin(Double($0) / 4) * 8_000) }
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var format = little(UInt16(1)) + little(UInt16(1)) + little(sampleRate) + little(sampleRate * 2)
        format += little(UInt16(2)) + little(UInt16(16))
        let audio = samples.reduce(into: Data()) { $0 += little($1) }
        let cue =
            little(UInt32(1)) + Data(repeating: 0, count: 8)
            + Data("data".utf8) + Data(repeating: 0, count: 12)
        let chunks = [("fmt ", format), ("data", audio), ("cue ", cue)]
            .reduce(into: Data()) { $0 += Data($1.0.utf8) + little(UInt32($1.1.count)) + $1.1 }
        let url = directory.appending(path: "cues.wav")
        try (Data("RIFF".utf8) + little(UInt32(4 + chunks.count)) + Data("WAVE".utf8) + chunks).write(to: url)
        return url
    }

    private func timecodedClip(in directory: URL) async throws -> URL {
        let asset = AVURLAsset(url: try fixture())
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let duration = try await asset.load(.duration)
        let destination = directory.appending(path: "timecoded.mov")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
        var format: CMTimeCodeFormatDescription?
        XCTAssertEqual(
            CMTimeCodeFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: CMTime(value: 1, timescale: 24), frameQuanta: 24, flags: 0, extensions: nil,
                formatDescriptionOut: &format), noErr)
        let timecodeFormat = try XCTUnwrap(format)
        let timecodeIn = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: timecodeFormat)
        writer.add(videoIn)
        writer.add(timecodeIn)
        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var frameNumber = Int32(0).bigEndian
        var block: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: MemoryLayout<Int32>.size,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: MemoryLayout<Int32>.size, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        XCTAssertEqual(
            CMBlockBufferReplaceDataBytes(
                with: &frameNumber, blockBuffer: buffer, offsetIntoDestination: 0,
                dataLength: MemoryLayout<Int32>.size), noErr)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = MemoryLayout<Int32>.size
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: buffer, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: timecodeFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample), noErr)
        while !timecodeIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(timecodeIn.append(try XCTUnwrap(sample)))
        timecodeIn.markAsFinished()
        while true {
            guard videoIn.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            guard let videoSample = videoOut.copyNextSampleBuffer() else {
                videoIn.markAsFinished()
                break
            }
            XCTAssertTrue(videoIn.append(videoSample))
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return destination
    }
}
