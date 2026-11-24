import AVFoundation
import Engine
import Foundation
import XCTest

@testable import MacEase

@MainActor
final class PreviewFallbackPlaybackTests: XCTestCase {
    private static let conversionTimeout = Duration.seconds(60)
    private static let roomyLimits = PreviewConversionLimits(
        maximumAudioDuration: 600, maximumVideoDuration: 600, maximumInputBytes: 512 * 1024 * 1024)

    func testWMVAndWMAConvertOnlyAfterTheButtonAndPlay() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, support) = try Self.staging(in: directory)
        let wmv = try Self.makeWMV(named: "clip.wmv", seconds: 1, in: directory)
        let wma = directory.appendingPathComponent("song.wma")
        try Self.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "wmav2", wma.path])

        for (url, audioOnly, stagedName) in [(wmv, false, "fallback.mov"), (wma, true, "fallback.m4a")] {
            let playback = PreviewPlayback()
            await playback.load(
                url, audioOnly: audioOnly, detected: try ContentSniffer.identify(url), restricted: false,
                staging: staging)
            XCTAssertEqual(playback.phase, .convertible, url.lastPathComponent)
            XCTAssertEqual(try Self.trackedStaging(support), [], "selection must not stage anything")

            playback.convert(url)
            let finished = try await PreviewFixtures.waitUntil(timeout: Self.conversionTimeout) {
                !Self.isConverting(playback.phase)
            }
            XCTAssertTrue(finished)
            XCTAssertEqual(playback.phase, .playing, url.lastPathComponent)
            let ready = try await PreviewFixtures.waitUntil {
                playback.player?.currentItem?.status == .readyToPlay
            }
            XCTAssertTrue(ready, url.lastPathComponent)
            let staged = try XCTUnwrap((playback.player?.currentItem?.asset as? AVURLAsset)?.url)
            XCTAssertEqual(staged.lastPathComponent, stagedName)

            await playback.stopAndWait()
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertEqual(try Self.trackedStaging(support), [])
        }
    }

    func testQuarantinedWMVIsRefusedWithoutProbingOrConverting() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, support) = try Self.staging(in: directory)
        let wmv = try Self.makeWMV(named: "download.wmv", seconds: 1, in: directory)
        try PreviewFixtures.quarantine(wmv)
        let trust = PreviewTrust.evaluate(wmv, trustedFolders: [])
        XCTAssertTrue(trust.restricted)

        let playback = PreviewPlayback()
        await playback.load(
            wmv, audioOnly: false, detected: try ContentSniffer.identify(wmv), restricted: trust.restricted,
            staging: staging)
        XCTAssertEqual(
            playback.phase,
            .message(
                String(
                    localized:
                        "This file is from the internet, so MacEase doesn't convert it. Open it in a media player.")))
        playback.convert(wmv)
        XCTAssertFalse(Self.isConverting(playback.phase))
        XCTAssertEqual(try Self.trackedStaging(support), [])
        await playback.stopAndWait()
    }

    func testOverLimitFilesAreRefusedBeforeConversion() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, support) = try Self.staging(in: directory)
        let wmv = try Self.makeWMV(named: "long.wmv", seconds: 2, in: directory)
        let size = Int64(try XCTUnwrap(try wmv.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let detected = try ContentSniffer.identify(wmv)

        let cases: [(PreviewConversionLimits, String)] = [
            (
                PreviewConversionLimits(maximumAudioDuration: 600, maximumVideoDuration: 1, maximumInputBytes: size),
                PreviewConversionLimits.fileTooLongMessage
            ),
            (
                PreviewConversionLimits(
                    maximumAudioDuration: 600, maximumVideoDuration: 600, maximumInputBytes: size - 1),
                PreviewConversionLimits.fileTooLargeMessage
            ),
        ]
        for (limits, message) in cases {
            let playback = PreviewPlayback(limits: limits)
            await playback.load(wmv, audioOnly: false, detected: detected, restricted: false, staging: staging)
            playback.convert(wmv)
            let settled = try await PreviewFixtures.waitUntil(timeout: Self.conversionTimeout) {
                !Self.isConverting(playback.phase)
            }
            XCTAssertTrue(settled)
            XCTAssertEqual(playback.phase, .message(message))
            await playback.stopAndWait()
        }
        XCTAssertEqual(try Self.trackedStaging(support), [])
    }

    func testSelectionChangeMidConversionKillsFFmpegAndEmptiesStaging() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, support) = try Self.staging(in: directory)
        let name = "cancel-\(UUID().uuidString).wmv"
        let wmv = try Self.makeWMV(named: name, seconds: 40, size: "1280x720", in: directory)

        let playback = PreviewPlayback(limits: Self.roomyLimits)
        await playback.load(
            wmv, audioOnly: false, detected: try ContentSniffer.identify(wmv), restricted: false, staging: staging)
        XCTAssertEqual(playback.phase, .convertible)
        playback.convert(wmv)
        let running = try await PreviewFixtures.waitUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
            try Self.isFFmpegRunning(on: name)
        }
        XCTAssertTrue(running, "expected a live ffmpeg child before the selection changed")

        await playback.stopAndWait()
        XCTAssertFalse(try Self.isFFmpegRunning(on: name))
        XCTAssertEqual(try Self.trackedStaging(support), [])
        XCTAssertNil(playback.player)
    }

    func testConversionPastTheWallClockLimitStopsInTheFailedState() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, support) = try Self.staging(in: directory)
        let name = "slow-\(UUID().uuidString).wmv"
        let wmv = try Self.makeWMV(named: name, seconds: 60, size: "1280x720", in: directory)
        var limits = Self.roomyLimits
        limits.maximumFallbackConversionTime = .seconds(1)

        let playback = PreviewPlayback(limits: limits)
        await playback.load(
            wmv, audioOnly: false, detected: try ContentSniffer.identify(wmv), restricted: false, staging: staging)
        XCTAssertEqual(playback.phase, .convertible)
        playback.convert(wmv)
        let stopped = try await PreviewFixtures.waitUntil(timeout: Self.conversionTimeout) {
            !Self.isConverting(playback.phase)
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(playback.phase, .failed)
        XCTAssertFalse(try Self.isFFmpegRunning(on: name))
        XCTAssertEqual(try Self.trackedStaging(support), [])
        await playback.stopAndWait()
    }

    func testGarbageNamedWMVEndsInAnErrorState() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, support) = try Self.staging(in: directory)
        let noise = directory.appendingPathComponent("noise.wmv")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: noise)
        let asfHeader: [UInt8] = [
            0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
        ]
        let asfVideoGUID: [UInt8] = [
            0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
        ]
        let brokenASF = directory.appendingPathComponent("broken.wmv")
        try Data(asfHeader + asfVideoGUID + [UInt8](repeating: 0xEE, count: 4096)).write(to: brokenASF)

        let mismatched = PreviewPlayback()
        await mismatched.load(
            noise, audioOnly: false, detected: try ContentSniffer.identify(noise), restricted: false, staging: staging)
        XCTAssertEqual(mismatched.phase, .failed)

        let undecodable = PreviewPlayback()
        await undecodable.load(
            brokenASF, audioOnly: false, detected: try ContentSniffer.identify(brokenASF), restricted: false,
            staging: staging)
        XCTAssertEqual(undecodable.phase, .convertible, "nothing parses the file before the button")
        undecodable.convert(brokenASF)
        let settled = try await PreviewFixtures.waitUntil(timeout: Self.conversionTimeout) {
            !Self.isConverting(undecodable.phase)
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            undecodable.phase,
            .message(UserMessages.describe(.decodeFailed(""), file: brokenASF.lastPathComponent)))
        XCTAssertEqual(try Self.trackedStaging(support), [])
        await mismatched.stopAndWait()
        await undecodable.stopAndWait()
    }

    func testNativelyDecodedFormatsStillTakeTheNativePath() async throws {
        let directory = try PreviewFixtures.directory(self)
        let (staging, _) = try Self.staging(in: directory)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4"))
        let mkv = directory.appendingPathComponent("clip.mkv")
        try Self.ffmpeg(["-i", fixture.path, "-c", "copy", mkv.path])
        let opus = directory.appendingPathComponent("voice.opus")
        try Self.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libopus", opus.path])

        for (url, audioOnly, stagedName) in [(mkv, false, "preview.mp4"), (opus, true, "preview.m4a")] {
            let playback = PreviewPlayback()
            await playback.prepareConversion(url, audioOnly: audioOnly, staging: staging)
            XCTAssertEqual(playback.phase, .convertible, url.lastPathComponent)
            playback.convert(url)
            let finished = try await PreviewFixtures.waitUntil(timeout: Self.conversionTimeout) {
                !Self.isConverting(playback.phase)
            }
            XCTAssertTrue(finished)
            XCTAssertEqual(playback.phase, .playing, url.lastPathComponent)
            let staged = try XCTUnwrap((playback.player?.currentItem?.asset as? AVURLAsset)?.url)
            XCTAssertEqual(staged.lastPathComponent, stagedName)
            await playback.stopAndWait()
        }
    }

    func testLegacyExtensionsRouteToTheMediaViewers() throws {
        let directory = try PreviewFixtures.directory(self)
        let samples: [(String, [UInt8], PreviewKind)] = [
            ("disc.vob", [0x00, 0x00, 0x01, 0xBA, 0x44, 0x00], .media),
            ("show.rm", Array(".RMF".utf8) + [0, 0, 0, 0x12], .media),
            ("show.rmvb", Array(".RMF".utf8) + [0, 0, 0, 0x12], .media),
            ("track.wv", Array("wvpk".utf8) + [0x20, 0, 0, 0], .audio),
            ("track.ape", Array("MAC ".utf8) + [0x96, 0x0F, 0, 0], .audio),
            ("track.dts", [0x7F, 0xFE, 0x80, 0x01, 0xFC, 0x3C], .audio),
            ("track.ac3", [0x0B, 0x77, 0x3E, 0x9C, 0x14, 0x40], .audio),
        ]
        for (name, header, kind) in samples {
            let file = directory.appendingPathComponent(name)
            try Data(header + [UInt8](repeating: 0x80, count: 64)).write(to: file)
            let result = try PreviewKind.inspectContent(file)
            XCTAssertEqual(result.kind, kind, name)
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: result.kind, detected: try XCTUnwrap(result.detected)), .matches,
                name)
        }
        let typeScript = directory.appendingPathComponent("module.mts")
        try Data("export const answer = 42;\n".utf8).write(to: typeScript)
        XCTAssertEqual(try PreviewKind.inspect(typeScript), .text)
        let textAsAudio = directory.appendingPathComponent("notes.wv")
        try Data("plain words".utf8).write(to: textAsAudio)
        let mismatch = try PreviewKind.inspectContent(textAsAudio)
        XCTAssertEqual(mismatch.kind, .audio)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(kind: mismatch.kind, detected: try XCTUnwrap(mismatch.detected)),
            .mismatch(detectedName: "Text"))
    }

    private static func staging(in directory: URL) throws -> (StagingArea, URL) {
        let support = directory.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        return (StagingArea(supportDirectory: support), support)
    }

    private static func trackedStaging(_ support: URL) throws -> [String] {
        let registry = support.appendingPathComponent("staging.json")
        guard FileManager.default.fileExists(atPath: registry.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
    }

    private static func isConverting(_ phase: PreviewPlayback.Phase) -> Bool {
        if case .converting = phase { true } else { false }
    }

    private static func makeWMV(named name: String, seconds: Int, size: String = "160x120", in directory: URL) throws
        -> URL
    {
        let url = directory.appendingPathComponent(name)
        try ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=24:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", "wmv2", "-c:a", "wmav2", url.path,
        ])
        return url
    }

    private static func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "media-tools/bin/ffmpeg")
        process.arguments = ["-nostdin", "-v", "error", "-y"] + arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    private static func isFFmpegRunning(on name: String) throws -> Bool {
        let checker = Process()
        checker.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checker.arguments = ["-f", "bin/ffmpeg .*\(name)"]
        try checker.run()
        checker.waitUntilExit()
        return checker.terminationStatus == 0
    }
}
