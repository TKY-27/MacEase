import AVFoundation
import CoreMedia
import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct AudioCopyTimingTests {
    private static let sampleRate: CMTimeScale = 48_000
    private static let aacFrameSamples = 1_024
    private static let audibleThreshold: Float = 0.01
    private static let videoBitrate = 300_000
    private static let audioStart = CMTime(value: 1, timescale: 4)

    private enum CopyPath: CaseIterable {
        case remux, reencodeVideo, toneMap, extract
    }

    private func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    private func hdrWithAudio(in directory: URL) async throws -> URL {
        let movie = AVMutableMovie(url: try resource("ffmpeg-h264-aac.mp4"))
        for video in try await movie.loadTracks(withMediaType: .video) { movie.removeTrack(video) }
        let videoAsset = AVURLAsset(url: try resource("x265-hlg.mov"))
        let source = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let track = try #require(movie.addMutableTrack(withMediaType: .video, copySettingsFrom: source))
        let duration = try await videoAsset.load(.duration)
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: source, at: .zero, copySampleData: false)
        for audio in try await movie.loadTracks(withMediaType: .audio) {
            audio.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: Self.audioStart))
        }
        let url = directory.appending(path: "hlg-audio.mov")
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
        return url
    }

    private func delayedAudio(_ source: URL, in directory: URL, name: String) async throws -> URL {
        let movie = AVMutableMovie(url: source)
        for audio in try await movie.loadTracks(withMediaType: .audio) {
            audio.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: Self.audioStart))
        }
        let url = directory.appending(path: name)
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
        return url
    }

    private func pcmMovie(in directory: URL) async throws -> URL {
        let wave = directory.appending(path: "tone.wav")
        let encoder = try AudioFileEncoder(
            url: wave, target: AudioTarget(format: .wav, kilobits: 0),
            sampleRate: Double(Self.sampleRate), channels: 2)
        let duration = CMTime(value: 1, timescale: 10)
        let toneFrequency = 440.0
        let samples = (0..<Int(Self.sampleRate) / 10).flatMap { frame in
            let value = Float(sin(2 * .pi * toneFrequency * Double(frame) / Double(Self.sampleRate)) * 0.5)
            return [value, value]
        }
        try await encoder.write(samples)
        try await encoder.finish()
        let source = AVURLAsset(url: wave)
        let sourceTrack = try #require(try await source.loadTracks(withMediaType: .audio).first)
        let movie = AVMutableMovie(url: try resource("ffmpeg-h264-aac.mp4"))
        for track in try await movie.load(.tracks) { movie.removeTrack(track) }
        let track = try #require(movie.addMutableTrack(withMediaType: .audio, copySettingsFrom: sourceTrack))
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero, copySampleData: false)
        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: Self.audioStart))
        let url = directory.appending(path: "pcm.mov")
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
        return url
    }

    private func containerPackets(_ url: URL) throws -> [MediaPacket] {
        var demuxer: any MediaDemuxer =
            switch url.pathExtension {
            case "avi": try AVIDemuxer(url: url)
            case "flv": try FLVDemuxer(url: url)
            default: try MatroskaDemuxer(url: url)
            }
        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        return packets
    }

    private func decodedFirstAudible(_ url: URL) async throws -> Double {
        let input = try await MediaInput.open(url)
        let track = try #require(input.audio)
        let source = try VideoPCMSource(input: input, track: track, start: 0, end: .max)
        while let chunk = try await source.next() {
            if let index = chunk.samples.firstIndex(where: { abs($0) > Self.audibleThreshold }) {
                guard case .audio(let sampleRate, let channels) = track.kind else {
                    throw EngineError.decodeFailed("missing audio format")
                }
                return Double(chunk.timestamp) / Double(Nanoseconds.perSecond)
                    + Double(index / channels) / sampleRate
            }
        }
        Issue.record("copied audio has no audible samples")
        return 0
    }

    private func audioMeasurement(_ url: URL, range: CMTimeRange? = nil) async throws -> (
        firstAudible: Double, end: Double, frames: Int
    ) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.decodeFailed("audio measurement") }
        var firstAudible: Double?
        var end = 0.0
        var frames = 0
        while let sample = await output.nextSample() {
            guard sample.numSamples > 0 else { continue }
            let format = try #require(sample.formatDescription)
            let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            let block = try #require(sample.dataBuffer)
            let byteCount = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: base)
            }
            #expect(status == noErr)
            if firstAudible == nil, let index = samples.firstIndex(where: { abs($0) > Self.audibleThreshold }) {
                firstAudible =
                    sample.presentationTimeStamp.seconds
                    + Double(index / Int(basic.mChannelsPerFrame)) / basic.mSampleRate
            }
            frames += sample.numSamples
            end = CMTimeRange(start: sample.presentationTimeStamp, duration: sample.duration).end.seconds
        }
        if reader.status == .failed { throw reader.error ?? EngineError.decodeFailed("audio measurement") }
        return (try #require(firstAudible), end, frames)
    }

    private func firstVideoTime(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.decodeFailed("video measurement") }
        var first: Double?
        while let sample = await output.nextSample() {
            guard sample.numSamples > 0 else { continue }
            let timestamp = sample.outputPresentationTimeStamp.seconds
            first = min(first ?? timestamp, timestamp)
        }
        if reader.status == .failed { throw reader.error ?? EngineError.decodeFailed("video measurement") }
        return try #require(first)
    }

    @Test func rejectsTimeScaledAudioPackets() async throws {
        let asset = AVURLAsset(url: try resource("ffmpeg-h264-aac.mp4"))
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.decodeFailed("audio measurement") }
        while let sample = await output.nextSample() {
            guard sample.numSamples > 0, sample.outputDuration > .zero else { continue }
            let doubledSpeed = NSNumber(value: 2)
            CMSetAttachment(
                sample, key: kCMSampleBufferAttachmentKey_SpeedMultiplier, value: doubledSpeed,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            #expect(throws: FormatError.unsupported("scaled sample timing")) {
                try SampleBuffers.packets(from: sample, track: 1)
            }
            return
        }
        if reader.status == .failed { throw reader.error ?? EngineError.decodeFailed("audio measurement") }
        Issue.record("fixture has no audible packets")
    }

    @Test(arguments: CopyPath.allCases)
    private func copiedAudioKeepsSourcePrimingAndTimeline(path: CopyPath) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioCopyTiming-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await path == .toneMap ? hdrWithAudio(in: directory) : resource("ffmpeg-h264-aac.mp4")
        let asset = AVURLAsset(url: source)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let sourceEdit = try #require(try await sourceTrack.load(.segments).first { !$0.isEmpty })
        #expect(
            sourceEdit.timeMapping.source.start
                == CMTime(value: Int64(Self.aacFrameSamples), timescale: Self.sampleRate))
        let before = try await audioMeasurement(source)
        let videoBefore = path == .extract ? nil : try await firstVideoTime(source)
        let input = try await MediaInput.open(source)
        let output = directory.appending(path: path == .extract ? "copied.m4a" : "copied.mov")
        let encoding = VideoEncoding(
            codec: .h264, width: input.codedSize.width, height: input.codedSize.height,
            frameDuration: input.frameDuration, bitrate: Self.videoBitrate)
        switch path {
        case .remux, .reencodeVideo, .toneMap:
            let video: TranscodePlan.Video =
                switch path {
                case .remux: .copy
                case .toneMap: .toneMapToSDR(encoding)
                default: .encode(encoding, FrameEdit())
                }
            try await Transcoder.run(
                input, plan: TranscodePlan(container: .mov, video: video, audio: .copy), to: output
            ) { _ in }
        case .extract:
            let track = try #require(input.audio)
            let stage = try await PacketCopyStage(input: input, track: track, number: 1, start: 0, end: .max)
            let sink = try AssetWriterSink(
                url: output, fileType: .m4a, tracks: [try #require(stage.output)], transform: .identity)
            while stage.nextTime != nil {
                for packet in try await stage.pull() { try await sink.write(packet) }
            }
            try await sink.finish()
        }
        let after = try await audioMeasurement(output)
        let tolerance = Double(Self.aacFrameSamples) / Double(Self.sampleRate)
        #expect(abs(after.firstAudible - before.firstAudible) <= tolerance)
        #expect(abs(after.end - before.end) <= tolerance)
        #expect(abs(after.frames - before.frames) <= Self.aacFrameSamples)
        if let videoBefore {
            let videoAfter = try await firstVideoTime(output)
            #expect(abs((after.firstAudible - videoAfter) - (before.firstAudible - videoBefore)) <= tolerance)
        }
        let outputTrack = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let outputEdit = try #require(try await outputTrack.load(.segments).first { !$0.isEmpty })
        #expect(outputEdit.timeMapping.source.start == sourceEdit.timeMapping.source.start)
        #expect(outputEdit.timeMapping.target == sourceEdit.timeMapping.target)
    }

    @Test func trimmedAudioKeepsPrerollAndFinalAudiblePacket() async throws {
        let source = try resource("ffmpeg-h264-aac.mp4")
        let range = CMTimeRange(
            start: CMTime(value: 350, timescale: 1_000), duration: CMTime(value: 1, timescale: 1))
        let before = try await audioMeasurement(source, range: range)
        let input = try await MediaInput.open(source)
        let output = FileManager.default.temporaryDirectory.appending(path: "trimmed-audio-\(UUID()).mov")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: output) } }
        var plan = TranscodePlan(container: .mov, video: nil, audio: .copy)
        plan.range = SampleBuffers.nanoseconds(range.start)..<SampleBuffers.nanoseconds(range.end)
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
        let after = try await audioMeasurement(output)
        let sampleTolerance = 1 / Double(Self.sampleRate)
        #expect(abs(after.firstAudible - (before.firstAudible - range.start.seconds)) <= sampleTolerance)
        #expect(abs(after.end - range.duration.seconds) <= sampleTolerance)
        #expect(after.frames == before.frames)
    }

    @Test(arguments: [OutputContainer.mkv, .flv])
    private func inHouseCopyUsesEditedAudioTimeline(container: OutputContainer) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioCopyTiming-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await delayedAudio(
            resource("ffmpeg-h264-aac.mp4"), in: directory, name: "delayed-audio.mov")
        let before = try await audioMeasurement(source)
        let videoBefore = try await firstVideoTime(source)
        let input = try await MediaInput.open(source)
        let output = directory.appending(path: "copied.\(container.fileExtension)")
        try await Transcoder.run(
            input, plan: TranscodePlan(container: container, video: .copy, audio: .copy), to: output
        ) { _ in }
        let packets = try containerPackets(output)
        let audio = packets.filter { $0.track == 2 }
        let firstAudio = try #require(audio.first)
        let firstVideo = try #require(packets.first { $0.track == 1 })
        let frame = Double(Self.aacFrameSamples) / Double(Self.sampleRate)
        let offset = Double(firstAudio.timestamp - firstVideo.timestamp) / Double(Nanoseconds.perSecond)
        #expect(audio.allSatisfy { $0.timestamp >= 0 })
        #expect(audio.map(\.timestamp) == audio.map(\.timestamp).sorted())
        #expect(abs(offset - (before.firstAudible - videoBefore)) <= frame)
        let decoded = try await decodedFirstAudible(output)
        #expect(abs(decoded - before.firstAudible) <= frame)
    }

    @Test func aviCopyKeepsEditedPCMTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioCopyTiming-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await pcmMovie(in: directory)
        let before = try await audioMeasurement(source)
        let input = try await MediaInput.open(source)
        let output = directory.appending(path: "copied.avi")
        try await Transcoder.run(
            input, plan: TranscodePlan(container: .avi, video: nil, audio: .copy), to: output
        ) { _ in }
        let packets = try containerPackets(output)
        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { $0.timestamp >= 0 })
        #expect(packets.map(\.timestamp) == packets.map(\.timestamp).sorted())
        let decoded = try await decodedFirstAudible(output)
        #expect(abs(decoded - before.firstAudible) <= 1 / Double(Self.sampleRate))
    }

    @Test func copiedOpusKeepsCodecDelayAndSeekPreroll() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioCopyTiming-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = try await MediaInput.open(resource("ffmpeg-h264-aac.mp4"))
        let encoded = directory.appending(path: "opus.webm")
        try await Transcoder.run(
            input, plan: TranscodePlan(container: .webm, video: nil, audio: .encode(.opus, kilobits: 96)),
            to: encoded
        ) { _ in }
        let encodedDemuxer = try MatroskaDemuxer(url: encoded)
        let sourceTrack = try #require(encodedDemuxer.tracks.first)
        #expect(sourceTrack.codecDelay > 0)
        #expect(sourceTrack.seekPreRoll == 80 * Nanoseconds.perMillisecond)
        let copied = directory.appending(path: "copied.mkv")
        let copyInput = try await MediaInput.open(encoded)
        try await Transcoder.run(
            copyInput, plan: TranscodePlan(container: .mkv, video: nil, audio: .copy), to: copied
        ) { _ in }
        let copiedDemuxer = try MatroskaDemuxer(url: copied)
        let copiedTrack = try #require(copiedDemuxer.tracks.first)
        #expect(copiedTrack.codecPrivate == sourceTrack.codecPrivate)
        #expect(copiedTrack.codecDelay == sourceTrack.codecDelay)
        #expect(copiedTrack.seekPreRoll == sourceTrack.seekPreRoll)
        #expect(try containerPackets(copied).map(\.timestamp) == containerPackets(encoded).map(\.timestamp))
    }
}
