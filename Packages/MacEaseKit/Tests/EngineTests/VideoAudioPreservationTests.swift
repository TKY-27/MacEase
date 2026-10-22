import AVFoundation
import AudioToolbox
import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite(.serialized) struct VideoAudioPreservationTests {
    private static let sampleRate = 48_000

    @Test(arguments: [AudioFormat.wav, .aiff, .flac], [MediaCodec.alac, .flac])
    func losslessExtractionRetainsSourcePrecision(format: AudioFormat, codec: MediaCodec) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let samples: [Float] = [0.5, 0.5 + 1 / 8_388_608, -0.5, -0.5 - 1 / 8_388_608]
        let source = try await losslessSource(samples, codec: codec, folder: folder)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(format, url: source, context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("expected derived audio")
            return
        }
        let output = try #require(outputs.first)
        #expect(try AudioInput(url: output.url).bitDepth == 24)
        let (_, decoded) = try AudioSignals.decode(output.url)
        #expect(decoded == samples)
    }

    @Test(arguments: [AudioFormat.wav, .aiff, .flac, .m4aALAC, .cafPCM, .cafALAC])
    func losslessReencodingHonorsEditedALACDuration(format: AudioFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let samples = (0..<5_003).map { Float($0 + 1) / 8_388_608 }
        let encoded = try await losslessSource(samples, codec: .alac, folder: folder)
        let sourceAsset = AVURLAsset(url: encoded, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .audio).first)
        let scale = CMTimeScale(Self.sampleRate)
        let firstFrame = 13
        let keptFrames = 4_501
        let delayedFrames = 120
        let movie = AVMutableMovie()
        movie.timescale = scale
        let audio = try #require(movie.addMutableTrack(withMediaType: .audio, copySettingsFrom: sourceTrack))
        try audio.insertTimeRange(
            CMTimeRange(
                start: CMTime(value: Int64(firstFrame), timescale: scale),
                duration: CMTime(value: Int64(keptFrames), timescale: scale)),
            of: sourceTrack, at: .zero, copySampleData: false)
        audio.insertEmptyTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(value: Int64(delayedFrames), timescale: scale)))
        let videoURL = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let videoAsset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoSource = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let video = try #require(movie.addMutableTrack(withMediaType: .video, copySettingsFrom: videoSource))
        try video.insertTimeRange(
            try await videoSource.load(.timeRange), of: videoSource, at: .zero, copySampleData: false)
        let source = folder.appending(path: "edited.mov")
        try movie.writeHeader(to: source, fileType: .mov, options: .addMovieHeaderToDestination)
        let editedAsset = AVURLAsset(url: source)
        let editedAudio = try #require(try await editedAsset.loadTracks(withMediaType: .audio).first)
        #expect(try await editedAsset.load(.duration) > editedAudio.load(.timeRange).end)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(format, kilobits: 0, url: source, context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("expected derived audio")
            return
        }
        let output = try #require(outputs.first)
        #expect(try AudioInput(url: output.url).bitDepth == 24)
        let (_, decoded) = try AudioSignals.decode(output.url)
        let expected = [Float](repeating: 0, count: delayedFrames) + samples[firstFrame..<firstFrame + keptFrames]
        #expect(decoded == expected)
    }

    private func losslessSource(_ samples: [Float], codec: MediaCodec, folder: URL) async throws -> URL {
        let format: AudioFormat = codec == .alac ? .m4aALAC : .flac
        let encoded = folder.appending(path: "source.\(format.fileExtension)")
        let encoder = try AudioFileEncoder(
            url: encoded, target: AudioTarget(format: format, kilobits: 0),
            sampleRate: Double(Self.sampleRate), channels: 1, bitDepth: 24)
        try await encoder.write(samples)
        try await encoder.finish()
        if codec == .alac {
            let asset = AVURLAsset(url: encoded, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let nativeTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let range = try await nativeTrack.load(.timeRange)
            #expect(range.duration == CMTime(value: Int64(samples.count), timescale: CMTimeScale(Self.sampleRate)))
            return encoded
        }
        let reader = try FileHandle(forReadingFrom: encoded)
        defer { #expect(throws: Never.self) { try reader.close() } }
        let offset = Int(try FLACBlock.read(reader).framesOffset)
        let bytes = try Data(contentsOf: encoded)
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(Self.sampleRate), channels: 1),
            codec: .flac, codecPrivate: Data(bytes.prefix(offset)))
        let source = folder.appending(path: "source.mkv")
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data(bytes.dropFirst(offset))))
        try muxer.finish()
        return source
    }

    @Test(arguments: [MediaCodec.flac, .pcm(bits: 32, float: false, bigEndian: false)])
    func losslessExtractionRefusesUnknownOrUnrepresentablePrecisionBeforeStaging(codec: MediaCodec) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "unsupported.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(Self.sampleRate), channels: 1), codec: codec)
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let detail = codec == .flac ? "Unknown audio bit depth" : "Audio precision cannot be preserved"
        await #expect(throws: EngineError.unsupportedCodec(detail)) {
            _ = try await VideoAudio.extract(.aiff, url: source, context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [8, 24, 32])
    func copiedPCMRetainsGapsAndIntegerPrecision(bits: Int) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "sparse.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(Self.sampleRate), channels: 2),
            codec: .pcm(bits: bits, float: false, bigEndian: false))
        let bytesPerFrame = bits / 8 * 2
        let packetFrames = Self.sampleRate / 50
        let payload = Data((0..<packetFrames * bytesPerFrame).map { UInt8($0 % 256) })
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        for second in [0, 1] {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(second) * Nanoseconds.perSecond,
                    duration: 20 * Nanoseconds.perMillisecond, isKeyframe: true, payload: payload))
        }
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(.wav, url: source, context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("expected derived WAV")
            return
        }
        let output = try #require(outputs.first)
        let silence = Data(repeating: bits == 8 ? 128 : 0, count: (Self.sampleRate - packetFrames) * bytesPerFrame)
        #expect(try pcmBytes(output.url) == payload + silence + payload)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func copiedPCMRetainsNativeDelayAndTrim() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let wave = folder.appending(path: "source.wav")
        let samples = (0..<480).map { Float($0 + 1) / 8_388_608 }
        let encoder = try AudioFileEncoder(
            url: wave, target: AudioTarget(format: .wav, kilobits: 0),
            sampleRate: Double(Self.sampleRate), channels: 1, bitDepth: 24)
        try await encoder.write(samples)
        try await encoder.finish()
        let original = try pcmBytes(wave)
        let asset = AVURLAsset(url: wave)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let movie = AVMutableMovie()
        let scale = CMTimeScale(Self.sampleRate)
        movie.timescale = scale
        let track = try #require(movie.addMutableTrack(withMediaType: .audio, copySettingsFrom: sourceTrack))
        try track.insertTimeRange(
            CMTimeRange(start: CMTime(value: 48, timescale: scale), duration: CMTime(value: 240, timescale: scale)),
            of: sourceTrack, at: .zero, copySampleData: false)
        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 120, timescale: scale)))
        let source = folder.appending(path: "edited.mov")
        try movie.writeHeader(to: source, fileType: .mov, options: .addMovieHeaderToDestination)
        let edited = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).first)
        let segment = try #require(try await edited.load(.segments).first { !$0.isEmpty })
        #expect(segment.timeMapping.target.start == CMTime(value: 120, timescale: scale))
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(.wav, url: source, context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("expected derived WAV")
            return
        }
        let output = try #require(outputs.first)
        let actual = try pcmBytes(output.url)
        #expect(actual.count == 360 * 3)
        #expect(actual.firstIndex(where: { $0 != 0 }) == 120 * 3)
        #expect(actual == Data(repeating: 0, count: 120 * 3) + original[48 * 3..<288 * 3])
    }

    @Test func copiedPCMEnforcesCumulativeSilenceBudget() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "excessive-gaps.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 1, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        for second in [0, 302, 604] {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(second) * Nanoseconds.perSecond,
                    isKeyframe: true, payload: Data([1, 0])))
        }
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")) {
            _ = try await VideoAudio.extract(.wav, url: source, context: context)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func copiedPCMRemovesContainerCodecDelay() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "codec-delay.mkv")
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 1_000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        track.codecDelay = 2 * Nanoseconds.perMillisecond
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        let payload = Data([1, 0, 2, 0, 3, 0, 4, 0])
        for millisecond in [0, 4] {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(millisecond) * Nanoseconds.perMillisecond,
                    isKeyframe: true, payload: payload))
        }
        try muxer.finish()
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(.wav, url: source, context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("expected derived WAV")
            return
        }
        let output = try #require(outputs.first)
        #expect(try pcmBytes(output.url) == Data([3, 0, 4, 0]) + payload)
    }

    private func pcmBytes(_ url: URL) throws -> Data {
        var opened: AudioFileID?
        #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened) == noErr)
        let file = try #require(opened)
        defer { #expect(AudioFileClose(file) == noErr) }
        var length: UInt64 = 0
        var propertySize = UInt32(MemoryLayout<UInt64>.size)
        #expect(AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &propertySize, &length) == noErr)
        var bytes = Data(count: Int(length))
        var count = UInt32(length)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return OSStatus(kAudioFileUnspecifiedError) }
            return AudioFileReadBytes(file, false, 0, &count, address)
        }
        #expect(status == noErr)
        #expect(UInt64(count) == length)
        return bytes
    }
}
