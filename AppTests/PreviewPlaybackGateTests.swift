import AVFoundation
import Engine
import Foundation
import XCTest

@testable import MacEase

final class PreviewPlaybackGateTests: XCTestCase {
    func testPlayableAssetsRemainPlayableEvenWhenRestricted() {
        let mp4 = DetectedContent(family: .video, displayName: "MP4")
        let mp3 = DetectedContent(family: .audio, displayName: "MP3")
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .video, isPlayable: true, detected: mp4, restricted: false),
            .playable)
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .video, isPlayable: true, detected: mp4, restricted: true),
            .playable)
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .audio, isPlayable: true, detected: mp3, restricted: false),
            .playable)
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .audio, isPlayable: true, detected: mp3, restricted: true),
            .playable)
    }

    func testEmptyFilesAreAlwaysRefused() {
        let empty = DetectedContent(family: .empty, displayName: "Empty file")
        for role in [PreviewMediaRole.video, .audio] {
            for playable in [false, true] {
                for restricted in [false, true] {
                    XCTAssertEqual(
                        PreviewPlaybackDecision.evaluate(
                            role: role, isPlayable: playable, detected: empty, restricted: restricted),
                        .refused(.emptyFile))
                }
            }
        }
    }

    func testUnplayableMatchingAssetsAreConvertibleOnlyWhenUnrestricted() {
        let mkv = DetectedContent(family: .video, displayName: "Matroska video")
        let ogg = DetectedContent(family: .audio, displayName: "Ogg audio")
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .video, isPlayable: false, detected: mkv, restricted: false),
            .convertible)
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .video, isPlayable: false, detected: mkv, restricted: true),
            .refused(.restricted))
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .audio, isPlayable: false, detected: ogg, restricted: false),
            .convertible)
        XCTAssertEqual(
            PreviewPlaybackDecision.evaluate(role: .audio, isPlayable: false, detected: ogg, restricted: true),
            .refused(.restricted))
    }

    func testUnplayableMismatchedAssetsAreRefusedWithDetectedName() {
        let text = DetectedContent(family: .text, displayName: "Text")
        let audio = DetectedContent(family: .audio, displayName: "FLAC")
        let video = DetectedContent(family: .video, displayName: "AVI")
        for restricted in [false, true] {
            XCTAssertEqual(
                PreviewPlaybackDecision.evaluate(
                    role: .video, isPlayable: false, detected: text, restricted: restricted),
                .refused(.contentMismatch(detectedName: "Text")))
            XCTAssertEqual(
                PreviewPlaybackDecision.evaluate(
                    role: .video, isPlayable: false, detected: audio, restricted: restricted),
                .refused(.contentMismatch(detectedName: "FLAC")))
            XCTAssertEqual(
                PreviewPlaybackDecision.evaluate(
                    role: .audio, isPlayable: false, detected: video, restricted: restricted),
                .refused(.contentMismatch(detectedName: "AVI")))
        }
    }

    func testVideoAndAudioPlaybackSourcesCreateAndCleanUpStagedCopiesOutsideEditor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let staging = StagingArea(supportDirectory: directory)

        let videoFixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4"))
        let videoSource = try await VideoEditorSource.open(videoFixture, staging: staging)
        let stagedVideo = try await videoSource.playbackURL(sdr: true, normalized: true)
        XCTAssertNotEqual(stagedVideo, videoFixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedVideo.path))
        let playable = try await AVURLAsset(url: stagedVideo).load(.isPlayable)
        XCTAssertTrue(playable)
        await videoSource.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedVideo.path))

        let wavURL = directory.appendingPathComponent("tone.wav")
        try Self.writeSilentPCM16WAV(to: wavURL)
        let audioSource = try await AudioPreviewSource.open(wavURL, staging: staging)
        let playbackAudio = try await audioSource.playbackURL()
        XCTAssertEqual(playbackAudio, wavURL)
        await audioSource.close()
    }

    @MainActor
    func testQuickTimeReferenceMovieIsRefusedWithSpecificMessage() async throws {
        let directory = try PreviewFixtures.directory(self)
        let videoFixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4"))
        let targetCopy = directory.appendingPathComponent("secret.mp4")
        try FileManager.default.copyItem(at: videoFixture, to: targetCopy)
        let referenceMovie = directory.appendingPathComponent("reference.mov")
        try Self.makeQuickTimeReferenceMovie(referencing: "secret.mp4").write(to: referenceMovie)

        // Control: unrestricted AVURLAsset resolves the sibling target.
        let unrestrictedPlayable = try await AVURLAsset(url: referenceMovie).load(.isPlayable)
        XCTAssertTrue(unrestrictedPlayable)

        let asset = PreviewMediaAsset.make(referenceMovie)
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll)
        let playability = try await PreviewMediaAsset.checkPlayability(referenceMovie)
        guard case .forbiddenReference = playability else {
            return XCTFail("expected forbiddenReference")
        }

        let staging = StagingArea(supportDirectory: directory)
        let detected = try ContentSniffer.identify(referenceMovie)
        for restricted in [false, true] {
            let playback = PreviewPlayback()
            await playback.load(
                referenceMovie, audioOnly: false, detected: detected, restricted: restricted, staging: staging)
            XCTAssertEqual(playback.phase, .message(PreviewMediaAsset.forbiddenReferenceMessage))
            XCTAssertNil(playback.player)
            playback.stop()
        }
    }

    private static func makeQuickTimeReferenceMovie(referencing relativeTarget: String) -> Data {
        func atom(_ type: String, _ payload: Data) -> Data {
            var data = Data()
            appendUInt32BE(&data, UInt32(8 + payload.count))
            data.append(contentsOf: type.utf8)
            data.append(payload)
            return data
        }
        var rdrfPayload = Data([0, 0, 0, 0])
        rdrfPayload.append(contentsOf: "url ".utf8)
        var urlBytes = Data(relativeTarget.utf8)
        urlBytes.append(0)
        appendUInt32BE(&rdrfPayload, UInt32(urlBytes.count))
        rdrfPayload.append(urlBytes)
        let moov = atom("moov", atom("rmra", atom("rmda", atom("rdrf", rdrfPayload))))
        var ftypPayload = Data("qt  ".utf8)
        ftypPayload.append(contentsOf: [0x20, 0x05, 0x03, 0x00])
        ftypPayload.append(contentsOf: "qt  ".utf8)
        return atom("ftyp", ftypPayload) + moov
    }

    private static func appendUInt32BE(_ buffer: inout Data, _ value: UInt32) {
        buffer.append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    private static func writeSilentPCM16WAV(to url: URL) throws {
        let sampleRate: UInt32 = 44_100
        let sampleCount: UInt32 = 4_410
        let dataBytes = sampleCount * 2
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(&header, 36 + dataBytes)
        header.append(contentsOf: "WAVEfmt ".utf8)
        appendUInt32LE(&header, 16)
        appendUInt16LE(&header, 1)
        appendUInt16LE(&header, 1)
        appendUInt32LE(&header, sampleRate)
        appendUInt32LE(&header, sampleRate * 2)
        appendUInt16LE(&header, 2)
        appendUInt16LE(&header, 16)
        header.append(contentsOf: "data".utf8)
        appendUInt32LE(&header, dataBytes)
        header.append(Data(repeating: 0, count: Int(dataBytes)))
        try header.write(to: url)
    }

    private static func appendUInt16LE(_ buffer: inout Data, _ value: UInt16) {
        buffer.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func appendUInt32LE(_ buffer: inout Data, _ value: UInt32) {
        buffer.append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}
