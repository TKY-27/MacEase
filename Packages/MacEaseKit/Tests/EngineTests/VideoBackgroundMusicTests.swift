import AVFoundation
import CoreMedia
import CoreVideo
import Formats
import Foundation
import Synchronization
import Testing

@testable import Engine

private final class OnceFlag: Sendable {
    private let fired = Mutex(false)
    func trigger() -> Bool {
        fired.withLock { value in
            if value { return false }
            value = true
            return true
        }
    }
}

@Suite(.serialized) struct VideoBackgroundMusicTests {
    private static let sampleRate = 48_000.0
    private static let frameRate = 30
    private static let frameWidth = 128
    private static let frameHeight = 96

    @Test func codableRoundTripValidationAndFadeMath() async throws {
        let legacyJSON = Data(#"{"start":0,"end":2,"speed":1,"trimMode":"exact"}"#.utf8)
        let legacy = try JSONDecoder().decode(VideoEdit.self, from: legacyJSON)
        #expect(legacy.music == nil)

        let folder = try AudioSignals.temporaryFolder()
        let songURL = folder.appending(path: "song.wav")
        try await AudioSignals.write(
            tone(frequency: 660, amplitude: 0.5, seconds: 5.0, sampleRate: Self.sampleRate, channels: 2),
            to: songURL, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        let loaded = try await BackgroundMusic.load(from: songURL)
        #expect(loaded.url == songURL)
        #expect(abs(loaded.duration - 5.0) < 0.01)
        #expect(loaded.start == 0)
        #expect(loaded.volume == BackgroundMusic.defaultVolume)

        var edit = VideoEdit(start: 0, end: 3)
        edit.segments = [VideoSegment(start: 0, end: 3)]
        edit.music = BackgroundMusic(
            url: songURL, stamp: loaded.stamp, duration: loaded.duration, start: 1.25, volume: 0.45)
        let restored = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
        #expect(restored == edit)

        let minimalJSON = try JSONEncoder().encode(loaded)
        var raw = try #require(try JSONSerialization.jsonObject(with: minimalJSON) as? [String: Any])
        raw.removeValue(forKey: "start")
        raw.removeValue(forKey: "volume")
        let defaulted = try JSONDecoder().decode(
            BackgroundMusic.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(defaulted.start == 0)
        #expect(defaulted.volume == BackgroundMusic.defaultVolume)

        let longerFade = loaded.fade(forOutputDuration: 3.0)
        #expect(abs(longerFade.duration - 3.0) < 1e-6)
        #expect(abs(longerFade.fadeOut - 1.0) < 1e-6)
        #expect(abs(longerFade.gain(at: 1.5) - 1.0) < 1e-6)
        #expect(abs(longerFade.gain(at: 2.5) - 0.5) < 1e-6)

        let shortVideoFade = loaded.fade(forOutputDuration: 0.6)
        #expect(abs(shortVideoFade.duration - 0.6) < 1e-6)
        #expect(abs(shortVideoFade.fadeOut - 0.6) < 1e-6)
        #expect(abs(shortVideoFade.gain(at: 0.3) - 0.5) < 1e-6)

        let shorterSongFade = loaded.fade(forOutputDuration: 8.0)
        #expect(abs(shorterSongFade.duration - loaded.duration) < 1e-6)
        #expect(shorterSongFade.fadeOut == 0)

        var offsetMusic = loaded
        offsetMusic.start = 3.5
        #expect(abs(offsetMusic.playDuration(forOutputDuration: 4.0) - (loaded.duration - 3.5)) < 1e-6)
        #expect(offsetMusic.fade(forOutputDuration: 4.0).fadeOut == 0)
        #expect(abs(offsetMusic.fade(forOutputDuration: 1.0).fadeOut - 1.0) < 1e-6)

        let nonFileURL = try #require(URL(string: "https://example.invalid/song.wav"))
        let invalidCases: [BackgroundMusic] = [
            BackgroundMusic(url: nonFileURL, stamp: loaded.stamp, duration: 5.0),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 0),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: -1),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: .nan),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 5.0, start: -0.1),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 5.0, start: 5.0),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 5.0, start: .infinity),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 5.0, volume: -0.01),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 5.0, volume: 1.01),
            BackgroundMusic(url: songURL, stamp: loaded.stamp, duration: 5.0, volume: .nan),
        ]
        for invalid in invalidCases {
            #expect(throws: EngineError.self) { try invalid.validate() }
            var badEdit = VideoEdit()
            badEdit.segments = [VideoSegment(start: 0, end: 2)]
            badEdit.music = invalid
            #expect(throws: EngineError.self) { try VideoTimeline(edit: badEdit, sourceDuration: 2) }
        }
    }

    @Test func silentVideoWithMusicProducesAudioInSingleAndJoinedExports() async throws {
        let folder = try TestVolume.makeFolder()
        let silentClip = folder.appending(path: "silent.mov")
        try await writeVideo(to: silentClip, duration: 3.0, audio: nil)
        let secondSilent = folder.appending(path: "silent2.mov")
        try await writeVideo(to: secondSilent, duration: 1.5, audio: nil)
        let songURL = folder.appending(path: "music.wav")
        try await AudioSignals.write(
            tone(frequency: 880, amplitude: 0.8, seconds: 6.0, sampleRate: Self.sampleRate, channels: 2),
            to: songURL, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var music = try await BackgroundMusic.load(from: songURL)
        music.volume = 0.5

        var singleEdit = VideoEdit()
        singleEdit.segments = [VideoSegment(start: 0, end: 3.0)]
        singleEdit.music = music
        let singleExport = folder.appending(path: "single_out.mov")
        try await exportVideo(source: silentClip, edit: singleEdit, to: singleExport)
        let singleDecoded = try await decodeVideoAudio(singleExport)
        #expect(singleDecoded.channels == 2)
        #expect(abs(singleDecoded.sampleRate - Self.sampleRate) < 1)
        let midRMS = rms(singleDecoded, from: 0.5, to: 1.5)
        let expectedMid = 0.8 * 0.5 / sqrt(2.0)
        #expect(abs(midRMS - expectedMid) < 0.04, "expected ~\(expectedMid), got \(midRMS)")
        let tailRMS = rms(singleDecoded, from: 2.5, to: 2.9)
        #expect(tailRMS < midRMS * 0.45, "expected fade-out in tail: mid \(midRMS), tail \(tailRMS)")

        var legacyEdit = VideoEdit()
        legacyEdit.music = music
        let legacyExport = folder.appending(path: "legacy_out.mov")
        try await exportVideo(source: silentClip, edit: legacyEdit, to: legacyExport)
        let legacyDecoded = try await decodeVideoAudio(legacyExport)
        #expect(rms(legacyDecoded, from: 0.5, to: 1.5) > 0.2)

        var joinedEdit = VideoEdit()
        joinedEdit.sources = [
            VideoEditSource(url: silentClip, duration: 3.0, stamp: try MediaSourceStamp(url: silentClip)),
            VideoEditSource(url: secondSilent, duration: 1.5, stamp: try MediaSourceStamp(url: secondSilent)),
        ]
        joinedEdit.segments = [
            VideoSegment(start: 0, end: 1.5, sourceIndex: 0),
            VideoSegment(start: 0, end: 1.5, sourceIndex: 1),
        ]
        joinedEdit.music = music
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        let outcome = await engine.run(
            MediaEditing.video(url: silentClip, edit: joinedEdit, settings: Settings()), settings: Settings()
        ) { _ in }
        guard case .succeeded(let outputs, _) = outcome.outcomes.first, let joinedURL = outputs.first else {
            Issue.record("expected joined silent video with music to succeed: \(outcome.outcomes)")
            return
        }
        let joinedDecoded = try await decodeVideoAudio(joinedURL)
        #expect(rms(joinedDecoded, from: 0.4, to: 1.8) > 0.2)
        #expect(rms(joinedDecoded, from: 2.5, to: 2.9) < rms(joinedDecoded, from: 0.4, to: 1.8) * 0.5)

        let voicedClip = folder.appending(path: "voiced.mov")
        try await writeVideo(
            to: voicedClip, duration: 2.5,
            audio: tone(frequency: 440, amplitude: 0.5, seconds: 2.5, sampleRate: Self.sampleRate, channels: 2))
        var mutedEdit = VideoEdit()
        mutedEdit.segments = [VideoSegment(start: 0, end: 2.5, volume: 0)]
        mutedEdit.music = music
        let mutedExport = folder.appending(path: "muted_with_music.mov")
        try await exportVideo(source: voicedClip, edit: mutedEdit, to: mutedExport)
        let mutedDecoded = try await decodeVideoAudio(mutedExport)
        #expect(toneMagnitude(mutedDecoded, frequency: 440, from: 0.3, to: 1.2) < 0.02)
        #expect(toneMagnitude(mutedDecoded, frequency: 880, from: 0.3, to: 1.2) > 0.3)
    }

    @Test func mixLevelsClampingStartOffsetShortAndLongSongs() async throws {
        let folder = try TestVolume.makeFolder()
        let voicedClip = folder.appending(path: "voiced.mov")
        try await writeVideo(
            to: voicedClip, duration: 3.0,
            audio: tone(frequency: 440, amplitude: 0.4, seconds: 3.0, sampleRate: Self.sampleRate, channels: 2))
        let longSong = folder.appending(path: "long.wav")
        try await AudioSignals.write(
            tone(frequency: 1_000, amplitude: 0.8, seconds: 6.0, sampleRate: Self.sampleRate, channels: 2),
            to: longSong, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var longMusic = try await BackgroundMusic.load(from: longSong)
        longMusic.volume = 0.3

        var mixEdit = VideoEdit()
        mixEdit.segments = [VideoSegment(start: 0, end: 3.0)]
        mixEdit.music = longMusic
        let mixOut = folder.appending(path: "mix.mov")
        try await exportVideo(source: voicedClip, edit: mixEdit, to: mixOut)
        let mixed = try await decodeVideoAudio(mixOut)
        let midVideo = toneMagnitude(mixed, frequency: 440, from: 0.5, to: 1.5)
        let midMusic = toneMagnitude(mixed, frequency: 1_000, from: 0.5, to: 1.5)
        let tailVideo = toneMagnitude(mixed, frequency: 440, from: 2.4, to: 2.9)
        let tailMusic = toneMagnitude(mixed, frequency: 1_000, from: 2.4, to: 2.9)
        #expect(abs(midVideo - 0.4) < 0.05)
        #expect(abs(midMusic - 0.24) < 0.05)
        #expect(abs(tailVideo - 0.4) < 0.05)
        #expect(tailMusic < midMusic * 0.45)

        let loudClip = folder.appending(path: "loud.mov")
        try await writeVideo(
            to: loudClip, duration: 1.5,
            audio: tone(frequency: 440, amplitude: 0.9, seconds: 1.5, sampleRate: Self.sampleRate, channels: 2))
        var loudMusic = try await BackgroundMusic.load(from: longSong)
        loudMusic.volume = 1.0
        var clampEdit = VideoEdit()
        clampEdit.segments = [VideoSegment(start: 0, end: 1.5)]
        clampEdit.music = loudMusic
        let clampInput = try await MediaInput.open(loudClip)
        let clampTimeline = try VideoTimeline(edit: clampEdit, sourceDuration: 1.5)
        let pcmSource = try await TimelinePCMSource(
            input: clampInput, track: clampInput.audio, timeline: clampTimeline, stagingDirectory: folder)
        var maxSample: Float = 0
        var clampedHits = 0
        while let chunk = try await pcmSource.next() {
            for sample in chunk.samples {
                #expect(sample.isFinite)
                #expect(sample >= -1 && sample <= 1)
                let magnitude = abs(sample)
                if magnitude > maxSample { maxSample = magnitude }
                if magnitude >= 0.999 { clampedHits += 1 }
            }
        }
        #expect(maxSample <= 1.0)
        #expect(clampedHits > 100)

        let silentClip = folder.appending(path: "silent_35.mov")
        try await writeVideo(to: silentClip, duration: 3.5, audio: nil)
        let shortSong = folder.appending(path: "short.wav")
        try await AudioSignals.write(
            tone(frequency: 880, amplitude: 0.7, seconds: 1.5, sampleRate: Self.sampleRate, channels: 2),
            to: shortSong, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var shortMusic = try await BackgroundMusic.load(from: shortSong)
        shortMusic.volume = 0.5
        var shortEdit = VideoEdit()
        shortEdit.segments = [VideoSegment(start: 0, end: 3.5)]
        shortEdit.music = shortMusic
        let shortOut = folder.appending(path: "short_out.mov")
        try await exportVideo(source: silentClip, edit: shortEdit, to: shortOut)
        let shortDecoded = try await decodeVideoAudio(shortOut)
        let earlyShort = toneMagnitude(shortDecoded, frequency: 880, from: 0.2, to: 0.7)
        let lateShort = toneMagnitude(shortDecoded, frequency: 880, from: 0.9, to: 1.4)
        let afterShort = peak(shortDecoded, from: 1.8, to: 3.3)
        #expect(abs(earlyShort - 0.35) < 0.05)
        #expect(abs(lateShort - earlyShort) < 0.05)
        #expect(afterShort < 0.005)

        let delayedSong = folder.appending(path: "delayed.wav")
        let silentPrefix = [Float](repeating: 0, count: Int(2.0 * Self.sampleRate) * 2)
        let loudSuffix = tone(frequency: 750, amplitude: 0.8, seconds: 2.0, sampleRate: Self.sampleRate, channels: 2)
        try await AudioSignals.write(
            silentPrefix + loudSuffix, to: delayedSong, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var offsetMusic = try await BackgroundMusic.load(from: delayedSong)
        offsetMusic.start = 2.0
        offsetMusic.volume = 0.5
        let twoSecondSilent = folder.appending(path: "silent_2.mov")
        try await writeVideo(to: twoSecondSilent, duration: 2.0, audio: nil)
        var offsetEdit = VideoEdit()
        offsetEdit.segments = [VideoSegment(start: 0, end: 2.0)]
        offsetEdit.music = offsetMusic
        let offsetOut = folder.appending(path: "offset_out.mov")
        try await exportVideo(source: twoSecondSilent, edit: offsetEdit, to: offsetOut)
        let offsetDecoded = try await decodeVideoAudio(offsetOut)
        #expect(toneMagnitude(offsetDecoded, frequency: 750, from: 0.2, to: 1.6) > 0.3)

        let editor = try await VideoEditorSource.open(
            twoSecondSilent, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        defer { Task { await editor.close() } }
        let offsetPreview = try await renderPreviewAudio(try await editor.playback(edit: offsetEdit))
        #expect(toneMagnitude(offsetPreview, frequency: 750, from: 0.2, to: 1.6) > 0.3)
    }

    @Test func interactsWithSegmentVolumeFadesSpeedFreezeReversedAndSilenceRemoval() async throws {
        let folder = try TestVolume.makeFolder()
        let clip = folder.appending(path: "voiced_4s.mov")
        try await writeVideo(
            to: clip, duration: 4.0,
            audio: tone(frequency: 440, amplitude: 0.6, seconds: 4.0, sampleRate: Self.sampleRate, channels: 2))
        let songURL = folder.appending(path: "music_1000.wav")
        try await AudioSignals.write(
            tone(frequency: 1_000, amplitude: 0.8, seconds: 8.0, sampleRate: Self.sampleRate, channels: 2),
            to: songURL, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var music = try await BackgroundMusic.load(from: songURL)
        music.volume = 0.35

        var seg0 = VideoSegment(start: 0, end: 1.5, volume: 0.8)
        seg0.fadeIn = 0.5
        seg0.fadeOut = 0.5
        let seg1 = VideoSegment(start: 1.5, end: 3.0, volume: 0.2)
        var fadeEdit = VideoEdit()
        fadeEdit.segments = [seg0, seg1]
        fadeEdit.music = music
        let fadeOut = folder.appending(path: "seg_fades.mov")
        try await exportVideo(source: clip, edit: fadeEdit, to: fadeOut)
        let fadeDecoded = try await decodeVideoAudio(fadeOut)
        let seg0MidVideo = toneMagnitude(fadeDecoded, frequency: 440, from: 0.6, to: 0.9)
        let seg0FadeEdgeVideo = toneMagnitude(fadeDecoded, frequency: 440, from: 1.35, to: 1.48)
        let seg1MidVideo = toneMagnitude(fadeDecoded, frequency: 440, from: 1.8, to: 2.3)
        let musicAtSeg0Edge = toneMagnitude(fadeDecoded, frequency: 1_000, from: 1.3, to: 1.7)
        #expect(seg0MidVideo > 0.35)
        #expect(seg0FadeEdgeVideo < seg0MidVideo * 0.4)
        #expect(abs(seg1MidVideo - 0.12) < 0.04)
        #expect(abs(musicAtSeg0Edge - 0.28) < 0.05)

        var speedEdit = VideoEdit()
        speedEdit.segments = [
            VideoSegment(start: 0, end: 2.0, speed: 2.0, volume: 0.5),
            VideoSegment(start: 2.0, end: 3.0, speed: 0.5, volume: 0.5),
        ]
        speedEdit.music = music
        let speedOut = folder.appending(path: "speed_music.mov")
        try await exportVideo(source: clip, edit: speedEdit, to: speedOut)
        let speedDecoded = try await decodeVideoAudio(speedOut)
        #expect(abs(toneMagnitude(speedDecoded, frequency: 1_000, from: 0.2, to: 0.8) - 0.28) < 0.05)
        #expect(abs(toneMagnitude(speedDecoded, frequency: 1_000, from: 1.2, to: 1.8) - 0.28) < 0.05)
        #expect(toneMagnitude(speedDecoded, frequency: 2_000, from: 0.2, to: 0.8) < 0.03)
        #expect(toneMagnitude(speedDecoded, frequency: 500, from: 1.2, to: 1.8) < 0.03)
        #expect(toneMagnitude(speedDecoded, frequency: 1_000, from: 2.5, to: 2.9) < 0.14)

        let frameStep = 1.0 / Double(Self.frameRate)
        var freezeEdit = VideoEdit()
        freezeEdit.segments = [
            VideoSegment(start: 0, end: 1.0, volume: 0.6),
            VideoSegment(start: 1.0, end: 1.0 + frameStep, speed: 1, volume: 0, freezeDuration: 1.5),
            VideoSegment(start: 1.0, end: 2.0, volume: 0.6),
        ]
        freezeEdit.music = music
        let freezeOut = folder.appending(path: "freeze_music.mov")
        try await exportVideo(source: clip, edit: freezeEdit, to: freezeOut)
        let freezeDecoded = try await decodeVideoAudio(freezeOut)
        #expect(toneMagnitude(freezeDecoded, frequency: 440, from: 0.2, to: 0.8) > 0.25)
        #expect(toneMagnitude(freezeDecoded, frequency: 440, from: 1.2, to: 2.3) < 0.02)
        #expect(abs(toneMagnitude(freezeDecoded, frequency: 1_000, from: 1.2, to: 2.3) - 0.28) < 0.05)
        #expect(toneMagnitude(freezeDecoded, frequency: 440, from: 2.7, to: 3.3) > 0.25)

        let twoToneClip = folder.appending(path: "two_tone.mov")
        let firstHalf = tone(frequency: 330, amplitude: 0.5, seconds: 1.0, sampleRate: Self.sampleRate, channels: 2)
        let secondHalf = tone(frequency: 660, amplitude: 0.5, seconds: 1.0, sampleRate: Self.sampleRate, channels: 2)
        try await writeVideo(to: twoToneClip, duration: 2.0, audio: firstHalf + secondHalf)
        let twoToneSong = folder.appending(path: "two_tone_song.wav")
        let songFirst = tone(frequency: 1_100, amplitude: 0.8, seconds: 1.0, sampleRate: Self.sampleRate, channels: 2)
        let songSecond = tone(frequency: 1_500, amplitude: 0.8, seconds: 3.0, sampleRate: Self.sampleRate, channels: 2)
        try await AudioSignals.write(
            songFirst + songSecond, to: twoToneSong, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var stepMusic = try await BackgroundMusic.load(from: twoToneSong)
        stepMusic.volume = 0.4
        let reverseTarget = VideoSegment(start: 0, end: 2.0)
        var reverseEdit = VideoEdit()
        reverseEdit.segments = [reverseTarget]
        reverseEdit.music = stepMusic
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let reversedEdit = try await VideoSegmentReverser.reverse(
            segmentID: reverseTarget.id, in: reverseEdit, primaryURL: twoToneClip, staging: staging)
        defer {
            for extra in (reversedEdit.sources ?? []).dropFirst() {
                VideoSegmentReverser.cleanupStagedSource(extra.url, in: staging)
            }
        }
        #expect(reversedEdit.music == stepMusic)
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        let reverseOutcome = await engine.run(
            MediaEditing.video(url: twoToneClip, edit: reversedEdit, settings: Settings()), settings: Settings()
        ) { _ in }
        guard case .succeeded(let revOutputs, _) = reverseOutcome.outcomes.first, let revOut = revOutputs.first else {
            Issue.record("expected reversed video with music to succeed: \(reverseOutcome.outcomes)")
            return
        }
        let revDecoded = try await decodeVideoAudio(revOut)
        #expect(toneMagnitude(revDecoded, frequency: 660, from: 0.2, to: 0.7) > 0.3)
        #expect(toneMagnitude(revDecoded, frequency: 330, from: 0.2, to: 0.7) < 0.05)
        #expect(toneMagnitude(revDecoded, frequency: 1_100, from: 0.2, to: 0.7) > 0.2)
        #expect(toneMagnitude(revDecoded, frequency: 1_500, from: 1.2, to: 1.5) > 0.15)

        let pauseClip = folder.appending(path: "with_pause.mov")
        let partA = tone(frequency: 440, amplitude: 0.5, seconds: 1.0, sampleRate: Self.sampleRate, channels: 2)
        let pause = [Float](repeating: 0, count: Int(1.5 * Self.sampleRate) * 2)
        let partB = tone(frequency: 440, amplitude: 0.5, seconds: 1.0, sampleRate: Self.sampleRate, channels: 2)
        try await writeVideo(to: pauseClip, duration: 3.5, audio: partA + pause + partB)
        let levels = try await AudioWaveform.levels(videoAt: pauseClip)
        let silences = try levels.silentRanges(SilenceRule())
        #expect(!silences.isEmpty)
        let cutSegments = try SilenceRemoval.segments(
            [VideoSegment(start: 0, end: 3.5)], silences: [0: silences], minimumKept: 2.0 / Double(Self.frameRate))
        var silenceEdit = VideoEdit()
        silenceEdit.segments = cutSegments
        silenceEdit.music = stepMusic
        let silenceTimeline = try VideoTimeline(edit: silenceEdit, sourceDuration: 3.5)
        #expect(silenceTimeline.duration < 2.6)
        let silenceOut = folder.appending(path: "silence_music.mov")
        try await exportVideo(source: pauseClip, edit: silenceEdit, to: silenceOut)
        let silenceDecoded = try await decodeVideoAudio(silenceOut)
        #expect(toneMagnitude(silenceDecoded, frequency: 1_100, from: 0.2, to: 0.8) > 0.2)
        #expect(toneMagnitude(silenceDecoded, frequency: 1_500, from: 1.15, to: 1.55) > 0.15)
        let endStart = max(0, silenceTimeline.duration - 0.35)
        let endStop = max(endStart + 0.05, silenceTimeline.duration - 0.05)
        #expect(
            toneMagnitude(silenceDecoded, frequency: 1_500, from: endStart, to: endStop)
                < toneMagnitude(silenceDecoded, frequency: 1_500, from: 1.15, to: 1.45) * 0.45)
    }

    @Test func decodableFormatsWorkAndUnsupportedFormatsFailClearly() async throws {
        let folder = try TestVolume.makeFolder()
        let silentClip = folder.appending(path: "silent.mov")
        try await writeVideo(to: silentClip, duration: 2.0, audio: nil)
        let signal = tone(frequency: 700, amplitude: 0.7, seconds: 3.0, sampleRate: 44_100, channels: 2)
        let formats: [(AudioFormat, String)] = [
            (.wav, "song.wav"),
            (.m4aAAC, "song_aac.m4a"),
            (.m4aALAC, "song_alac.m4a"),
            (.mp3, "song.mp3"),
            (.flac, "song.flac"),
            (.ogg, "song.ogg"),
            (.opus, "song.opus"),
            (.aiff, "song.aiff"),
            (.cafPCM, "song.caf"),
        ]
        let stagingDir = try AudioSignals.temporaryFolder()
        let staging = StagingArea(supportDirectory: stagingDir)
        let editor = try await VideoEditorSource.open(silentClip, staging: staging)

        for (format, fileName) in formats {
            let songURL = folder.appending(path: fileName)
            let rate = format == .opus ? 48_000.0 : 44_100.0
            let samples =
                rate == 44_100
                ? signal : tone(frequency: 700, amplitude: 0.7, seconds: 3.0, sampleRate: rate, channels: 2)
            try await AudioSignals.write(samples, to: songURL, format: format, sampleRate: rate, channels: 2)
            var music = try await BackgroundMusic.load(from: songURL)
            music.volume = 0.5
            var edit = VideoEdit()
            edit.segments = [VideoSegment(start: 0, end: 2.0)]
            edit.music = music

            let playback = try await editor.playback(edit: edit)
            let previewAudio = try await renderPreviewAudio(playback)
            #expect(rms(previewAudio, from: 0.2, to: 0.8) > 0.15, "preview silent for \(format)")

            let exported = folder.appending(path: "out_\(fileName).mov")
            try await exportVideo(source: silentClip, edit: edit, to: exported)
            let exportAudio = try await decodeVideoAudio(exported)
            #expect(rms(exportAudio, from: 0.2, to: 0.8) > 0.15, "export silent for \(format)")
        }
        await editor.close()

        let wmaURL = folder.appending(path: "unsupported.wma")
        try Data(AudioInput.asfSignature + [0, 1, 2, 3]).write(to: wmaURL)
        await #expect(throws: EngineError.unsupportedCodec("Windows Media Audio")) {
            try await BackgroundMusic.load(from: wmaURL)
        }

        let textURL = folder.appending(path: "notes.txt")
        try Data("not an audio file".utf8).write(to: textURL)
        do {
            _ = try await BackgroundMusic.load(from: textURL)
            Issue.record("expected text file to fail")
        } catch let error as EngineError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed for text file, got \(error)")
                return
            }
        }

        let corruptOgg = folder.appending(path: "corrupt.ogg")
        try Data("OggS\u{00}\u{02}corrupt".utf8).write(to: corruptOgg)
        do {
            _ = try await BackgroundMusic.load(from: corruptOgg)
            Issue.record("expected corrupt ogg to fail")
        } catch let error as EngineError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed for corrupt ogg, got \(error)")
                return
            }
        }

        do {
            _ = try await BackgroundMusic.load(from: silentClip)
            Issue.record("expected audio-less video to fail")
        } catch let error as EngineError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed for audio-less video, got \(error)")
                return
            }
        }
    }

    @Test func musicFileNeverWrittenAndStampChangesAbortSave() async throws {
        let folder = try TestVolume.makeFolder()
        let clip = folder.appending(path: "clip.mov")
        try await writeVideo(
            to: clip, duration: 2.0,
            audio: tone(frequency: 440, amplitude: 0.4, seconds: 2.0, sampleRate: Self.sampleRate, channels: 2))
        let secondClip = folder.appending(path: "clip2.mov")
        try await writeVideo(to: secondClip, duration: 1.5, audio: nil)
        let songURL = folder.appending(path: "song.wav")
        try await AudioSignals.write(
            tone(frequency: 880, amplitude: 0.7, seconds: 4.0, sampleRate: Self.sampleRate, channels: 2),
            to: songURL, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        let originalSongBytes = try Data(contentsOf: songURL)
        let originalSongAttributes = try FileManager.default.attributesOfItem(atPath: songURL.path)
        let originalSongModified = originalSongAttributes[.modificationDate] as? Date
        let originalClipBytes = try Data(contentsOf: clip)

        let music = try await BackgroundMusic.load(from: songURL)
        var edit = VideoEdit()
        edit.sourceStamp = try MediaSourceStamp(url: clip)
        edit.segments = [VideoSegment(start: 0, end: 2.0)]
        edit.music = music

        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        var newFileSettings = Settings()
        newFileSettings.outputMode = .newFile
        let newOutcome = await engine.run(
            MediaEditing.video(url: clip, edit: edit, settings: newFileSettings), settings: newFileSettings
        ) { _ in }
        guard case .succeeded(let newOutputs, _) = newOutcome.outcomes.first, let derivedURL = newOutputs.first else {
            Issue.record("expected new-file save with music to succeed: \(newOutcome.outcomes)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: derivedURL.path))
        #expect(try Data(contentsOf: songURL) == originalSongBytes)
        let currentSongModified =
            try FileManager.default.attributesOfItem(atPath: songURL.path)[.modificationDate] as? Date
        #expect(currentSongModified == originalSongModified)

        var replaceSettings = Settings()
        replaceSettings.outputMode = .replace
        let replaceOutcome = await engine.run(
            MediaEditing.video(url: clip, edit: edit, settings: replaceSettings), settings: replaceSettings
        ) { _ in }
        guard case .succeeded = replaceOutcome.outcomes.first else {
            Issue.record("expected replace save with music to succeed: \(replaceOutcome.outcomes)")
            return
        }
        #expect(try Data(contentsOf: songURL) == originalSongBytes)
        let replaceRecord = try #require(replaceOutcome.record)
        #expect(try await engine.history.undo(replaceRecord.id) == [.restored])
        #expect(try Data(contentsOf: clip) == originalClipBytes)
        #expect(try Data(contentsOf: songURL) == originalSongBytes)

        let changedSong = folder.appending(path: "changed_start.wav")
        try originalSongBytes.write(to: changedSong)
        let staleMusic = try await BackgroundMusic.load(from: changedSong)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 15)], ofItemAtPath: changedSong.path)
        var staleEdit = edit
        staleEdit.sourceStamp = try MediaSourceStamp(url: clip)
        staleEdit.music = staleMusic
        let staleOutcome = await engine.run(
            MediaEditing.video(url: clip, edit: staleEdit, settings: newFileSettings), settings: newFileSettings
        ) { _ in }
        guard case .failed(let startError) = staleOutcome.outcomes.first else {
            Issue.record("expected changed music before save start to fail")
            return
        }
        #expect(startError == .invalidInput(.malformed(BackgroundMusic.changedErrorMessage)))

        var staleJoined = VideoEdit()
        staleJoined.sources = [
            VideoEditSource(url: clip, duration: 2.0, stamp: try MediaSourceStamp(url: clip)),
            VideoEditSource(url: secondClip, duration: 1.5, stamp: try MediaSourceStamp(url: secondClip)),
        ]
        staleJoined.segments = [
            VideoSegment(start: 0, end: 1.0, sourceIndex: 0),
            VideoSegment(start: 0, end: 1.0, sourceIndex: 1),
        ]
        staleJoined.music = staleMusic
        let staleJoinedOutcome = await engine.run(
            MediaEditing.video(url: clip, edit: staleJoined, settings: newFileSettings), settings: newFileSettings
        ) { _ in }
        guard case .failed(let joinedStartError) = staleJoinedOutcome.outcomes.first else {
            Issue.record("expected changed music before joined save start to fail")
            return
        }
        #expect(joinedStartError == .invalidInput(.malformed(BackgroundMusic.changedErrorMessage)))

        let midExportSong = folder.appending(path: "changed_mid.wav")
        try originalSongBytes.write(to: midExportSong)
        let midMusic = try await BackgroundMusic.load(from: midExportSong)
        var midEdit = VideoEdit()
        midEdit.sourceStamp = try MediaSourceStamp(url: clip)
        midEdit.segments = [VideoSegment(start: 0, end: 2.0)]
        midEdit.music = midMusic
        let beforeFiles = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        let mutatedSingle = OnceFlag()
        let midOutcome = await engine.run(
            MediaEditing.video(url: clip, edit: midEdit, settings: newFileSettings), settings: newFileSettings
        ) { snapshot in
            if snapshot.itemPhases.first == .encoding, mutatedSingle.trigger() {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: 20)], ofItemAtPath: midExportSong.path)
            }
        }
        guard case .failed(let midError) = midOutcome.outcomes.first else {
            Issue.record("expected mid-export music change to abort save: \(midOutcome.outcomes)")
            return
        }
        #expect(midError == .invalidInput(.malformed(BackgroundMusic.changedErrorMessage)))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == beforeFiles)
        #expect(try Data(contentsOf: clip) == originalClipBytes)

        let midJoinedSong = folder.appending(path: "changed_mid_joined.wav")
        try originalSongBytes.write(to: midJoinedSong)
        let midJoinedMusic = try await BackgroundMusic.load(from: midJoinedSong)
        var midJoinedEdit = staleJoined
        midJoinedEdit.music = midJoinedMusic
        let beforeJoinedFiles = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        let mutatedJoined = OnceFlag()
        let midJoinedOutcome = await engine.run(
            MediaEditing.video(url: clip, edit: midJoinedEdit, settings: newFileSettings), settings: newFileSettings
        ) { snapshot in
            if snapshot.itemPhases.first == .encoding, mutatedJoined.trigger() {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: 25)], ofItemAtPath: midJoinedSong.path)
            }
        }
        guard case .failed(let midJoinedError) = midJoinedOutcome.outcomes.first else {
            Issue.record("expected mid-export music change in joined save to abort: \(midJoinedOutcome.outcomes)")
            return
        }
        #expect(midJoinedError == .invalidInput(.malformed(BackgroundMusic.changedErrorMessage)))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == beforeJoinedFiles)
    }

    @Test func previewAndExportAudioLevelsMatchAcrossEditsAndFades() async throws {
        let folder = try TestVolume.makeFolder()
        let clip = folder.appending(path: "clip.mov")
        try await writeVideo(
            to: clip, duration: 3.0,
            audio: tone(frequency: 440, amplitude: 0.4, seconds: 3.0, sampleRate: Self.sampleRate, channels: 2))
        let longSong = folder.appending(path: "long_music.wav")
        try await AudioSignals.write(
            tone(frequency: 1_000, amplitude: 0.8, seconds: 6.0, sampleRate: Self.sampleRate, channels: 2),
            to: longSong, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var music = try await BackgroundMusic.load(from: longSong)
        music.start = 0.5
        music.volume = 0.35

        let frameStep = 1.0 / Double(Self.frameRate)
        var seg0 = VideoSegment(start: 0, end: 1.5, volume: 0.8)
        seg0.fadeOut = 0.4
        let freeze = VideoSegment(start: 1.5, end: 1.5 + frameStep, speed: 1, volume: 0, freezeDuration: 1.0)
        let seg2 = VideoSegment(start: 1.5, end: 3.0, speed: 1.0, volume: 0.5)
        var edit = VideoEdit()
        edit.segments = [seg0, freeze, seg2]
        edit.music = music

        let editor = try await VideoEditorSource.open(
            clip, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        defer { Task { await editor.close() } }
        let playback = try await editor.playback(edit: edit)
        let compositionTracks = try await playback.asset.loadTracks(withMediaType: .audio)
        #expect(compositionTracks.count == 2)
        for track in compositionTracks {
            #expect(try await track.load(.naturalTimeScale) == 60_000)
        }

        let previewAudio = try await renderPreviewAudio(playback)
        let exportedURL = folder.appending(path: "exported_match.mov")
        try await exportVideo(source: clip, edit: edit, to: exportedURL)
        let exportAudio = try await decodeVideoAudio(exportedURL)

        let windows: [(Double, Double)] = [
            (0.2, 0.9),
            (1.15, 1.45),
            (1.65, 2.35),
            (2.65, 2.95),
            (3.15, 3.45),
            (3.55, 3.85),
        ]
        for (start, end) in windows {
            let previewLevel = rms(previewAudio, from: start, to: end)
            let exportLevel = rms(exportAudio, from: start, to: end)
            #expect(
                abs(previewLevel - exportLevel) < 0.035,
                "window \(start)...\(end): preview \(previewLevel) vs export \(exportLevel)")
        }

        let silentClip = folder.appending(path: "silent_match.mov")
        try await writeVideo(to: silentClip, duration: 3.0, audio: nil)
        let shortSong = folder.appending(path: "short_match.wav")
        try await AudioSignals.write(
            tone(frequency: 880, amplitude: 0.7, seconds: 1.2, sampleRate: Self.sampleRate, channels: 2),
            to: shortSong, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var shortMusic = try await BackgroundMusic.load(from: shortSong)
        shortMusic.volume = 0.5
        var shortEdit = VideoEdit()
        shortEdit.segments = [VideoSegment(start: 0, end: 3.0)]
        shortEdit.music = shortMusic

        let silentEditor = try await VideoEditorSource.open(
            silentClip, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        defer { Task { await silentEditor.close() } }
        let shortPreview = try await renderPreviewAudio(try await silentEditor.playback(edit: shortEdit))
        let shortExportURL = folder.appending(path: "short_match_export.mov")
        try await exportVideo(source: silentClip, edit: shortEdit, to: shortExportURL)
        let shortExport = try await decodeVideoAudio(shortExportURL)
        for (start, end) in [(0.2, 0.6), (0.7, 1.1), (1.5, 2.7)] {
            let previewLevel = rms(shortPreview, from: start, to: end)
            let exportLevel = rms(shortExport, from: start, to: end)
            #expect(
                abs(previewLevel - exportLevel) < 0.03,
                "short song window \(start)...\(end): preview \(previewLevel) vs export \(exportLevel)")
        }
        #expect(rms(shortPreview, from: 1.5, to: 2.7) < 0.005)
        #expect(rms(shortExport, from: 1.5, to: 2.7) < 0.005)
    }

    @Test func monoVideoWithStereoMusicMatchesPreviewAndExportAndSilentMKVProducesOpus() async throws {
        let folder = try TestVolume.makeFolder()
        let monoClip = folder.appending(path: "mono.mov")
        try await writeVideo(
            to: monoClip, duration: 2.5,
            audio: tone(frequency: 440, amplitude: 0.4, seconds: 2.5, sampleRate: Self.sampleRate, channels: 1),
            audioChannels: 1)
        let stereoSong = folder.appending(path: "stereo.wav")
        try await AudioSignals.write(
            tone(frequency: 1_000, amplitude: 0.7, seconds: 5.0, sampleRate: 44_100, channels: 2),
            to: stereoSong, format: .wav, sampleRate: 44_100, channels: 2)
        var music = try await BackgroundMusic.load(from: stereoSong)
        music.volume = 0.35

        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 2.5)]
        edit.music = music
        let editor = try await VideoEditorSource.open(
            monoClip, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        defer { Task { await editor.close() } }
        let previewAudio = try await renderPreviewAudio(try await editor.playback(edit: edit))
        let exported = folder.appending(path: "mono_mix.mov")
        try await exportVideo(source: monoClip, edit: edit, to: exported)
        let exportAudio = try await decodeVideoAudio(exported)
        for (start, end) in [(0.3, 1.2), (1.7, 2.0), (2.1, 2.4)] {
            let previewLevel = rms(previewAudio, from: start, to: end)
            let exportLevel = rms(exportAudio, from: start, to: end)
            #expect(
                abs(previewLevel - exportLevel) < 0.04,
                "mono+stereo window \(start)...\(end): preview \(previewLevel) vs export \(exportLevel)")
        }

        let silentMOV = folder.appending(path: "silent_for_mkv.mov")
        try await writeVideo(to: silentMOV, duration: 2.0, audio: nil)
        let silentMKV = folder.appending(path: "silent.mkv")
        let movInput = try await MediaInput.open(silentMOV)
        let movTrack = try #require(movInput.video)
        let mkvPlan = try VideoEdits.plan(.convert(.mkv), input: movInput, source: movTrack, settings: VideoSettings())
        try await Transcoder.run(movInput, plan: mkvPlan, to: silentMKV) { _ in }
        let mkvOut = folder.appending(path: "silent_with_music.mkv")
        var mkvEdit = VideoEdit()
        mkvEdit.segments = [VideoSegment(start: 0, end: 2.0)]
        mkvEdit.music = music
        try await exportVideo(source: silentMKV, edit: mkvEdit, to: mkvOut)
        let mkvInput = try await MediaInput.open(mkvOut)
        #expect(mkvInput.audio?.codec == .opus)
        let mkvAudio = try await decodeVideoAudio(mkvOut)
        #expect(rms(mkvAudio, from: 0.2, to: 0.8) > 0.12)
        #expect(rms(mkvAudio, from: 1.6, to: 1.95) < rms(mkvAudio, from: 0.2, to: 0.8) * 0.5)
    }

    @Test func reversedFreezeAndMusicPreserveAudioPlacementAndSampleSync() async throws {
        let folder = try TestVolume.makeFolder()
        let clip = folder.appending(path: "sync.mov")
        let rate = Self.sampleRate
        let channels = 2
        var signal = [Float](repeating: 0, count: Int(rate * 2) * channels)
        for frame in 0..<Int(rate * 2) {
            let time = Double(frame) / rate
            let frequency = time < 0.5 ? 440.0 : time < 1 ? 660.0 : time < 1.5 ? 880.0 : 1_100.0
            let value = Float(sin(2 * .pi * frequency * time)) * 0.4
            signal[frame * channels] = value
            signal[frame * channels + 1] = value
        }
        try await writeVideo(to: clip, duration: 2, audio: signal)
        let songURL = folder.appending(path: "music.wav")
        try await AudioSignals.write(
            tone(frequency: 1_600, amplitude: 0.3, seconds: 3, sampleRate: rate, channels: channels),
            to: songURL, format: .wav, sampleRate: rate, channels: channels)
        var music = try await BackgroundMusic.load(from: songURL)
        music.volume = 0.3
        let target = VideoSegment(start: 0, end: 1)
        var edit = VideoEdit()
        edit.segments = [
            target, VideoSegment(start: 1, end: 1.04, volume: 0, freezeDuration: 0.4), VideoSegment(start: 1, end: 2),
        ]
        edit.music = music
        let editor = try await VideoEditorSource.open(
            clip, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        let reversed = try await editor.reverse(segmentID: target.id, in: edit)
        let playback = try await editor.playback(edit: reversed)
        let preview = try await renderPreviewAudio(playback)
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        let result = await engine.run(
            MediaEditing.video(url: clip, edit: reversed, settings: Settings()), settings: Settings()
        ) { _ in }
        guard case .succeeded(let outputs, _) = result.outcomes.first, let output = outputs.first else {
            Issue.record("sync export failed")
            await editor.close()
            return
        }
        let exported = try await decodeVideoAudio(output)
        for audio in [preview, exported] {
            for (start, end, frequency) in [
                (0.05, 0.4, 660.0), (0.6, 0.95, 440.0), (1.45, 1.8, 880.0), (1.95, 2.3, 1_100.0),
            ] {
                #expect(toneMagnitude(audio, frequency: frequency, from: start, to: end) > 0.15)
                #expect(toneMagnitude(audio, frequency: 1_600, from: start, to: end) > 0.015)
            }
            #expect(toneMagnitude(audio, frequency: 440, from: 1.05, to: 1.35) < 0.005)
            #expect(toneMagnitude(audio, frequency: 880, from: 1.05, to: 1.35) < 0.005)
            #expect(toneMagnitude(audio, frequency: 1_600, from: 1.05, to: 1.35) > 0.02)
            let duration = Double(audio.samples.count / audio.channels) / audio.sampleRate
            #expect(abs(duration - 2.4) < 0.03)
        }
        let videoInput = try await MediaInput.open(output)
        #expect(abs(Double(videoInput.duration) / Double(Nanoseconds.perSecond) - 2.4) < 0.03)
        await editor.close()
    }

    @Test func nativePreviewDefersSaturationToOutputDevice() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "saturated.mov")
        let signal = tone(frequency: 440, amplitude: 0.8, seconds: 2, sampleRate: Self.sampleRate, channels: 2)
        try await writeVideo(to: source, duration: 2, audio: signal)
        let song = folder.appending(path: "same-tone.wav")
        try await AudioSignals.write(signal, to: song, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 2)]
        edit.music = try await BackgroundMusic.load(from: song)
        edit.music?.volume = 1
        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        let preview = try await renderPreviewAudio(try await editor.playback(edit: edit))
        let output = folder.appending(path: "saturated-export.mov")
        try await exportVideo(source: source, edit: edit, to: output)
        let exported = try await decodeVideoAudio(output)
        let previewLevel = rms(preview, from: 0.2, to: 1.8)
        let exportLevel = rms(exported, from: 0.2, to: 1.8)
        #expect(abs(previewLevel - 1.131371) < 0.035)
        #expect(abs(exportLevel - 0.850146) < 0.035)
        let clipped = DecodedAudio(
            samples: preview.samples.map { min(1, max(-1, $0)) },
            sampleRate: preview.sampleRate, channels: preview.channels)
        #expect(abs(rms(clipped, from: 0.2, to: 1.8) - exportLevel) < 0.035)
        await editor.close()
    }

    @Test func nativeMusicEditsAreImmediateAndNeverStageMixedAudio() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "cleanup.mov")
        try await writeVideo(to: source, duration: 2, audio: nil)
        let song = folder.appending(path: "cleanup.wav")
        try await AudioSignals.write(
            tone(frequency: 440, amplitude: 0.5, seconds: 3, sampleRate: Self.sampleRate, channels: 2),
            to: song, format: .wav, sampleRate: Self.sampleRate, channels: 2)
        let support = try AudioSignals.temporaryFolder()
        let editor = try await VideoEditorSource.open(source, staging: StagingArea(supportDirectory: support))
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 2)]
        edit.music = try await BackgroundMusic.load(from: song)
        edit.music?.volume = 0.25
        let first = try await renderPreviewAudio(try await editor.playback(edit: edit))
        var appearance = edit
        appearance.adjustments[.exposure] = 0.5
        let unchanged = try await renderPreviewAudio(try await editor.playback(edit: appearance))
        #expect(abs(rms(first, from: 0.2, to: 0.8) - rms(unchanged, from: 0.2, to: 0.8)) < 0.001)
        var louder = appearance
        louder.music?.volume = 0.75
        let changed = try await renderPreviewAudio(try await editor.playback(edit: louder))
        #expect(abs(rms(changed, from: 0.2, to: 0.8) / rms(first, from: 0.2, to: 0.8) - 3) < 0.02)
        _ = try await editor.playback(edit: edit)
        _ = try await editor.playback(edit: louder)
        let registry = support.appending(path: "staging.json")
        #expect(!FileManager.default.fileExists(atPath: registry.path))
        await editor.close()
    }

    @Test func concurrentNonNativeMusicUsesOneSessionProxyAndCloseRemovesIt() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "cleanup.mov")
        try await writeVideo(to: source, duration: 2, audio: nil)
        let song = folder.appending(path: "cleanup.ogg")
        try await AudioSignals.write(
            tone(frequency: 440, amplitude: 0.5, seconds: 10, sampleRate: Self.sampleRate, channels: 2),
            to: song, format: .ogg, sampleRate: Self.sampleRate, channels: 2)
        let support = try AudioSignals.temporaryFolder()
        let editor = try await VideoEditorSource.open(source, staging: StagingArea(supportDirectory: support))
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 2)]
        edit.music = try await BackgroundMusic.load(from: song)
        var other = edit
        other.music?.volume = 0.75
        let firstEdit = edit
        let secondEdit = other
        async let first = editor.playback(edit: firstEdit)
        async let second = editor.playback(edit: secondEdit)
        let (quiet, loud) = try await (first, second)
        #expect(rms(try await renderPreviewAudio(quiet), from: 0.2, to: 0.8) > 0.05)
        #expect(rms(try await renderPreviewAudio(loud), from: 0.2, to: 0.8) > 0.2)
        let registry = support.appending(path: "staging.json")
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        #expect(paths.count == 1)
        var appearance = edit
        appearance.adjustments[.exposure] = 0.5
        _ = try await editor.playback(edit: appearance)
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)) == paths)
        await editor.close()
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path)) }
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
    }

    @Test func closingDuringNonNativeMusicPreparationRemovesStaging() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "closing.mov")
        try await writeVideo(to: source, duration: 2, audio: nil)
        let song = folder.appending(path: "closing.ogg")
        try await AudioSignals.write(
            tone(frequency: 440, amplitude: 0.5, seconds: 30, sampleRate: Self.sampleRate, channels: 2),
            to: song, format: .ogg, sampleRate: Self.sampleRate, channels: 2)
        let support = try AudioSignals.temporaryFolder()
        let editor = try await VideoEditorSource.open(source, staging: StagingArea(supportDirectory: support))
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 2)]
        edit.music = try await BackgroundMusic.load(from: song)
        let snapshot = edit
        let preparation = Task { try await editor.playback(edit: snapshot) }
        let registry = support.appending(path: "staging.json")
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: registry.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        #expect(paths.count == 1)
        await editor.close()
        switch await preparation.result {
        case .success: break
        case .failure(let error): #expect(error is CancellationError)
        }
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path)) }
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
    }

    private struct DecodedAudio {
        let samples: [Float]
        let sampleRate: Double
        let channels: Int
    }

    private func tone(
        frequency: Double, amplitude: Float, seconds: Double, sampleRate: Double, channels: Int
    ) -> [Float] {
        let frames = Int((seconds * sampleRate).rounded())
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<channels {
                samples[frame * channels + channel] = value
            }
        }
        return samples
    }

    private func writeVideo(
        to url: URL, duration: Double, audio: [Float]?, audioChannels: Int = 2
    ) async throws {
        let folder = url.deletingLastPathComponent()
        let videoOnly = audio == nil ? url : folder.appending(path: "video-\(UUID().uuidString).mov")
        let encoding = VideoEncoding(
            codec: .h264, width: Self.frameWidth, height: Self.frameHeight,
            frameDuration: Nanoseconds.perSecond / Int64(Self.frameRate), bitrate: nil)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var packets: [MediaPacket] = []
        let frameCount = Int((duration * Double(Self.frameRate)).rounded())
        for index in 0..<frameCount {
            var buffer: CVPixelBuffer?
            try #require(
                CVPixelBufferCreate(
                    nil, Self.frameWidth, Self.frameHeight, kCVPixelFormatType_32BGRA, nil, &buffer)
                    == kCVReturnSuccess)
            let picture = try #require(buffer)
            try #require(CVPixelBufferLockBaseAddress(picture, []) == kCVReturnSuccess)
            let base = try #require(CVPixelBufferGetBaseAddress(picture)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(picture)
            let shade = UInt8((index * 7) % 200 + 20)
            for row in 0..<Self.frameHeight {
                for column in 0..<Self.frameWidth {
                    let offset = row * bytesPerRow + column * 4
                    base[offset] = shade
                    base[offset + 1] = 80
                    base[offset + 2] = 160
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(picture, [])
            let timestamp = try Nanoseconds.from(seconds: Double(index) / Double(Self.frameRate))
            packets += try encoder.encode(picture, timestamp: timestamp)
        }
        packets += try encoder.finish()
        var sink = try Sinks.make(
            .mov, url: videoOnly, tracks: [OutputTrack(track: encoder.track, format: encoder.formatDescription)],
            transform: .identity)
        let orderedPackets = packets.sorted {
            ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp)
        }
        for packet in orderedPackets {
            try await sink.write(packet)
        }
        sink.endTrack(1)
        try await sink.finish()
        guard let audio else { return }
        defer { try? FileManager.default.removeItem(at: videoOnly) }

        let audioURL = folder.appending(path: "audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await AudioSignals.write(
            audio, to: audioURL, format: .m4aALAC, sampleRate: Self.sampleRate, channels: audioChannels)

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoOnly)
        let audioAsset = AVURLAsset(url: audioURL)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let sourceVideo = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let sourceAudio = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let videoTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        let exporter = try #require(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: url, as: .mov)
    }

    private func exportVideo(source: URL, edit: VideoEdit, to output: URL) async throws {
        let input = try await MediaInput.open(source)
        let videoTrack = try #require(input.video)
        let plan = try VideoEdits.plan(.edit(edit), input: input, source: videoTrack, settings: VideoSettings())
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
    }

    private func decodeVideoAudio(_ url: URL) async throws -> DecodedAudio {
        let input = try await MediaInput.open(url)
        let track = try #require(input.audio)
        let source = try VideoPCMSource(input: input, track: track, start: 0, end: .max)
        var samples: [Float] = []
        while let chunk = try await source.next() { samples += chunk.samples }
        return DecodedAudio(samples: samples, sampleRate: source.sampleRate, channels: source.channels)
    }

    private func renderPreviewAudio(_ playback: VideoEditorPlayback) async throws -> DecodedAudio {
        let tracks = try await playback.asset.loadTracks(withMediaType: .audio)
        try #require(!tracks.isEmpty)
        let reader = try AVAssetReader(asset: playback.asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = playback.audioMix
        output.audioTimePitchAlgorithm = .timeDomain
        output.alwaysCopiesSampleData = false
        try #require(reader.canAdd(output))
        reader.add(output)
        try #require(reader.startReading())
        var samples: [Float] = []
        while let buffer = await output.nextSample() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteLength = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: byteLength / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { pointer -> OSStatus in
                guard let base = pointer.baseAddress else { return OSStatus(kCMBlockBufferBadLengthParameterErr) }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteLength, destination: base)
            }
            try #require(status == noErr)
            samples += chunk
        }
        try #require(reader.status == .completed, "preview audio reader failed: \(String(describing: reader.error))")
        return DecodedAudio(samples: samples, sampleRate: Self.sampleRate, channels: 2)
    }

    private func rms(_ audio: DecodedAudio, from start: Double, to end: Double) -> Double {
        let first = max(0, Int(start * audio.sampleRate)) * audio.channels
        let last = min(audio.samples.count, Int(end * audio.sampleRate) * audio.channels)
        guard first < last else { return 0 }
        var sumSquares = 0.0
        for index in first..<last {
            let value = Double(audio.samples[index])
            sumSquares += value * value
        }
        return sqrt(sumSquares / Double(last - first))
    }

    private func peak(_ audio: DecodedAudio, from start: Double, to end: Double) -> Float {
        let first = max(0, Int(start * audio.sampleRate)) * audio.channels
        let last = min(audio.samples.count, Int(end * audio.sampleRate) * audio.channels)
        guard first < last else { return 0 }
        return audio.samples[first..<last].map(abs).max() ?? 0
    }

    private func toneMagnitude(_ audio: DecodedAudio, frequency: Double, from start: Double, to end: Double) -> Double {
        let firstFrame = max(0, Int(start * audio.sampleRate))
        let lastFrame = min(audio.samples.count / audio.channels, Int(end * audio.sampleRate))
        let count = lastFrame - firstFrame
        guard count > 0 else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        let step = 2.0 * .pi * frequency / audio.sampleRate
        for offset in 0..<count {
            let sample = Double(audio.samples[(firstFrame + offset) * audio.channels])
            let angle = step * Double(offset)
            real += sample * cos(angle)
            imaginary += sample * sin(angle)
        }
        return 2.0 * hypot(real, imaginary) / Double(count)
    }
}
