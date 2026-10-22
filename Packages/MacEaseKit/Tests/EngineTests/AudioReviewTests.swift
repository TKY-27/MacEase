import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct AudioReviewTests {
    @Test func extractedPCMRetainsSilenceAcrossTimestampGap() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "sparse.mkv")
        let output = folder.appending(path: "sparse.wav")
        let rate: Int64 = 48_000
        let laterFrame: Int64 = 12_000
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(rate), channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: 0, duration: 4 * Nanoseconds.perSecond / rate, isKeyframe: true,
                payload: Data(repeating: 0x40, count: 8)))
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: laterFrame * Nanoseconds.perSecond / rate,
                duration: 4 * Nanoseconds.perSecond / rate, isKeyframe: true,
                payload: Data(repeating: 0xC0, count: 8)))
        try muxer.finish()

        let input = try await MediaInput.open(source)
        let audio = try #require(input.audio)
        try await VideoAudio.encode(
            input, track: audio, sampleRate: Double(rate), target: AudioTarget(format: .wav, kilobits: 0),
            to: output
        ) { _ in }

        let (_, samples) = try AudioSignals.decode(output)
        #expect(samples.count == Int(laterFrame) + 4)
        #expect(samples.prefix(4).allSatisfy { $0 > 0 })
        #expect(samples[4..<Int(laterFrame)].allSatisfy { $0 == 0 })
        #expect(samples.suffix(4).allSatisfy { $0 < 0 })
    }

    @Test func targetSizeIncludesTextTagsAndSearchesPastSixBitrates() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "tagged.opus")
        let tags = AudioTags(
            title: String(repeating: "T", count: 8_000), artist: String(repeating: "A", count: 8_000),
            album: String(repeating: "B", count: 8_000))
        try await AudioSignals.write(
            AudioSignals.music(seconds: 2, sampleRate: 48_000, channels: 1), to: source, format: .opus,
            sampleRate: 48_000, channels: 1, kilobits: 256, tags: tags)
        let target: Int64 = 58_000
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        let result = try await AudioJob.run(.compress(.targetBytes(target)), on: source, context: context)

        guard case .replace(_, let staged) = result else {
            Issue.record("expected a compressed audio output")
            return
        }
        let size = try #require(staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(Int64(size) <= target)
        #expect(try await AudioInput(url: staged.url).tags() == tags)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func targetSizeReachesMinimumBitrateAcrossContainerOverhead() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Issue.record("failed to remove audio test folder: \(error)")
            }
        }
        let source = folder.appending(path: "brief.opus")
        let minimum = folder.appending(path: "minimum.opus")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.1, sampleRate: 48_000, channels: 1), to: source, format: .opus,
            sampleRate: 48_000, channels: 1, kilobits: 256)
        let input = try AudioInput(url: source)
        let lowest = try #require(
            AudioFormat.opus.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels).first)
        let baseline = try AudioFileEncoder(
            url: minimum, target: AudioTarget(format: .opus, kilobits: lowest), sampleRate: input.sampleRate,
            channels: input.channels)
        let decoded = try input.open()
        while let chunk = try decoded.read() { try await baseline.write(chunk) }
        try await baseline.finish()
        let target = try #require(minimum.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        let result = try await AudioJob.run(.compress(.targetBytes(Int64(target))), on: source, context: context)

        guard case .replace(_, let staged) = result else {
            Issue.record("expected a compressed audio output")
            return
        }
        let size = try #require(staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= target)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func unreachableTaggedTargetReportsMinimumEncodedSize() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "short.opus")
        let minimum = folder.appending(path: "minimum.opus")
        let samples = AudioSignals.music(seconds: 0.5, sampleRate: 48_000, channels: 1)
        let tags = AudioTags(
            title: String(repeating: "T", count: 5_000), artist: String(repeating: "A", count: 5_000),
            album: String(repeating: "B", count: 5_000), artwork: AudioSignals.pngArtwork())
        try await AudioSignals.write(
            samples, to: source, format: .opus, sampleRate: 48_000, channels: 1, kilobits: 256, tags: tags)
        let input = try AudioInput(url: source)
        let lowest = try #require(
            AudioFormat.opus.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels).first)
        let baseline = try AudioFileEncoder(
            url: minimum, target: AudioTarget(format: .opus, kilobits: lowest), sampleRate: input.sampleRate,
            channels: input.channels, bitDepth: input.bitDepth, isFloat: input.isFloat, tags: tags)
        let decoded = try input.open()
        while let chunk = try decoded.read() { try await baseline.write(chunk) }
        try await baseline.finish()
        let expected = try #require(minimum.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        do {
            _ = try await AudioJob.run(.compress(.targetBytes(1_000)), on: source, context: context)
            Issue.record("expected unreachable target")
        } catch EngineError.targetUnreachable(let smallestBytes) {
            #expect(smallestBytes == Int64(expected))
            #expect(FileManager.default.fileExists(atPath: source.path))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
