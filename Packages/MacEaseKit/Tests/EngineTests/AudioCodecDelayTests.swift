import AVFoundation
import Foundation
import Testing

@testable import Engine
@testable import Formats

extension VideoAudioTests {
    @Test(arguments: [Int64(0), 100 * Nanoseconds.perMillisecond], [false, true])
    func partialCodecDelayPreservesSamplePositions(start: Int64, laced: Bool) async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "partial-delay.mkv")
        let sampleRate = 1_000.0
        let firstTimestamp = 100 * Nanoseconds.perMillisecond
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: sampleRate, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        track.codecDelay = 2 * Nanoseconds.perMillisecond
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        let framesPerPacket = 4
        for index in 0..<2 {
            var payload = Data()
            for sample in (index * framesPerPacket + 1)...((index + 1) * framesPerPacket) {
                payload.appendLittleEndian(Int16(sample))
            }
            var packet = MediaPacket(
                track: 1, timestamp: firstTimestamp + Int64(index * framesPerPacket) * Nanoseconds.perMillisecond,
                isKeyframe: true, payload: payload)
            if laced {
                packet.timestamp = firstTimestamp
                packet.continuesPrevious = index > 0
                packet.remainingLaceFrames = 1 - index
                packet.laceDuration = index == 0 ? 8 * Nanoseconds.perMillisecond : nil
                packet.discardPadding = index == 0 ? Nanoseconds.perMillisecond : nil
            }
            try muxer.write(packet)
        }
        try muxer.finish()
        let input = try await MediaInput.open(url)
        let source = try VideoPCMSource(input: input, track: try #require(input.audio), start: start, end: .max)
        var samples: [Float] = []
        var positions: [Int64] = []
        while let chunk = try await source.next() {
            positions += chunk.samples.indices.map { chunk.timestamp + Int64($0) * Nanoseconds.perMillisecond }
            samples += chunk.samples
        }
        let lastSample = laced ? 7 : 8
        #expect(samples == (3...lastSample).map { Float($0) / 32_768 })
        #expect(positions == (0..<(lastSample - 2)).map { firstTimestamp + Int64($0) * Nanoseconds.perMillisecond })
        if start == 0 {
            let context = ItemContext(
                settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
            defer { context.removeStaging() }
            for format in [AudioFormat.wav, .aiff] {
                guard case .derived(_, let outputs) = try await VideoAudio.extract(format, url: url, context: context)
                else {
                    Issue.record("expected copied PCM audio")
                    return
                }
                let output = try #require(outputs.first)
                let copied = try AudioSignals.decode(output.url).samples
                let expected = [Float](repeating: 0, count: 100) + (3...lastSample).map { Float($0) / 32_768 }
                #expect(copied == expected)
            }
        }
    }

    @Test func codecDelayCountsFramesBeforePadding() async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "padded-delay.mkv")
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 1_000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        track.codecDelay = 6 * Nanoseconds.perMillisecond
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        let framesPerPacket = 4
        for index in 0..<2 {
            var payload = Data()
            for sample in (index * framesPerPacket + 1)...((index + 1) * framesPerPacket) {
                payload.appendLittleEndian(Int16(sample))
            }
            var packet = MediaPacket(
                track: 1, timestamp: Int64(index * framesPerPacket) * Nanoseconds.perMillisecond,
                isKeyframe: true, payload: payload)
            packet.discardPadding = index == 0 ? Nanoseconds.perMillisecond : nil
            try muxer.write(packet)
        }
        try muxer.finish()
        let expected = [Float(7), 8].map { $0 / 32_768 }
        let input = try await MediaInput.open(url)
        let source = try VideoPCMSource(input: input, track: try #require(input.audio), start: 0, end: .max)
        var decoded: [Float] = []
        while let chunk = try await source.next() { decoded += chunk.samples }
        #expect(decoded == expected)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        guard case .derived(_, let outputs) = try await VideoAudio.extract(.wav, url: url, context: context) else {
            Issue.record("expected copied PCM audio")
            return
        }
        #expect(try AudioSignals.decode(try #require(outputs.first).url).samples == expected)
    }

    @Test func rangeEndStopsBeforeDecodingLaterPackets() async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "invalid-tail.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 1_000, channels: 1),
            codec: .pcm(bits: 32, float: true, bigEndian: false))
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        let framesPerPacket = 10
        let end = Int64(framesPerPacket) * Nanoseconds.perMillisecond
        let silence = Data(repeating: 0, count: framesPerPacket * MemoryLayout<Float>.size)
        let notANumber = Data([0, 0, 192, 127])
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: silence))
        try muxer.write(MediaPacket(track: 1, timestamp: end, isKeyframe: true, payload: notANumber))
        try muxer.finish()
        let input = try await MediaInput.open(url)
        let source = try VideoPCMSource(input: input, track: try #require(input.audio), start: 0, end: end)
        var samples: [Float] = []
        while let chunk = try await source.next() { samples += chunk.samples }
        #expect(samples.count == framesPerPacket)
    }
}

extension AudioCopyTimingTests {
    @Test func matroskaCodecDelayCopyPreservesGapAfterPriming() async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let matroska = directory.appending(path: "source.mkv")
        try await Transcoder.run(
            try await MediaInput.open(original),
            plan: TranscodePlan(container: .mkv, video: nil, audio: .copy), to: matroska
        ) { _ in }

        var demuxer = try MatroskaDemuxer(url: matroska)
        let track = try #require(demuxer.tracks.first { !$0.isVideo })
        let gap = 100 * Nanoseconds.perMillisecond
        let gapped = directory.appending(path: "gapped.mkv")
        var muxer = try MatroskaMuxer(url: gapped, tracks: [track], webm: false)
        var sourceTimes: [Int64] = []
        while var packet = try demuxer.nextPacket() {
            guard packet.track == track.number else { continue }
            sourceTimes.append(packet.timestamp)
            if sourceTimes.count > 1 { packet.timestamp += gap }
            try muxer.write(packet)
        }
        try #require(sourceTimes.count > 2)
        #expect(sourceTimes[0] == 0)
        #expect(abs(sourceTimes[1] - track.codecDelay) <= Nanoseconds.perMillisecond)
        try muxer.finish()

        let output = directory.appending(path: "gapped.flv")
        try await Transcoder.run(
            try await MediaInput.open(gapped),
            plan: TranscodePlan(container: .flv, video: nil, audio: .copy), to: output
        ) { _ in }
        var copied = try FLVDemuxer(url: output)
        var timestamps: [Int64] = []
        while let packet = try copied.nextPacket() {
            if packet.track == FLV.audioTrack { timestamps.append(packet.timestamp) }
        }
        try #require(timestamps.count > 1)
        #expect(timestamps[0] == gap)
        #expect(timestamps[1] > timestamps[0])
    }

    @Test func heAACMatroskaFLVCopyKeepsContiguousPackets() async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-heaac.mp4", withExtension: nil, subdirectory: "Resources"))
        let matroska = directory.appending(path: "heaac.mkv")
        try await Transcoder.run(
            try await MediaInput.open(original), plan: TranscodePlan(container: .mkv, video: .copy, audio: .copy),
            to: matroska
        ) { _ in }
        let input = try await MediaInput.open(matroska)
        let track = try #require(input.audio)
        let stage = try await PacketCopyStage(
            input: input, track: track, number: 2, start: 0, end: .max, destination: .flv)
        var packets: [MediaPacket] = []
        while stage.nextTime != nil { packets += try await stage.pull() }
        try #require(packets.count > 2)
        let frameDuration = Double(2_048) / 44_100 * Double(Nanoseconds.perSecond)
        let tolerance = Double(Nanoseconds.perMillisecond)
        var source = try MatroskaDemuxer(url: matroska)
        var sourcePackets = 0
        while let packet = try source.nextPacket() {
            if packet.track == track.number { sourcePackets += 1 }
        }
        let primingPackets = Int(Double(track.codecDelay) / frameDuration)
        #expect(packets.count == sourcePackets - primingPackets)
        #expect(packets.first?.timestamp == 0)
        for (previous, next) in zip(packets, packets.dropFirst()) {
            #expect(next.timestamp > previous.timestamp)
            #expect(abs(Double(next.timestamp - previous.timestamp) - frameDuration) <= tolerance)
        }
        let output = directory.appending(path: "heaac.flv")
        try await Transcoder.run(
            input, plan: TranscodePlan(container: .flv, video: .copy, audio: .copy), to: output
        ) { _ in }
        var demuxer = try FLVDemuxer(url: output)
        var timestamps: [Int64] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == 2 { timestamps.append(packet.timestamp) }
        }
        #expect(timestamps.count == packets.count)
        for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
            #expect(next > previous)
            #expect(abs(Double(next - previous) - frameDuration) <= tolerance)
        }
    }

    @Test(arguments: [(UInt8(0x90), Int64(1_024), Int64(22)), (0x94, 960, 20)])
    func aacCodecDelayWithoutBlockDurationCopiesWholePackets(
        configTail: UInt8, frameSamples: Int64, secondPacketMilliseconds: Int64
    ) async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "durationless.mkv")
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2), codec: .aac,
            codecPrivate: Data([0x11, configTail]))
        track.codecDelay = frameSamples * Nanoseconds.perSecond / 48_000
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        for index in 0..<3 {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(index) * track.codecDelay,
                    isKeyframe: true, payload: Data([UInt8(index)])))
        }
        try muxer.finish()
        var demuxer = try MatroskaDemuxer(url: url)
        #expect(try demuxer.nextPacket()?.duration == nil)
        let input = try await MediaInput.open(url)
        let stage = try await PacketCopyStage(
            input: input, track: try #require(input.audio), number: 1, start: 0, end: .max, destination: .flv)
        var packets: [MediaPacket] = []
        while stage.nextTime != nil { packets += try await stage.pull() }
        #expect(packets.map(\.payload) == [Data([1]), Data([2])])
        #expect(packets.map(\.timestamp) == [0, secondPacketMilliseconds * Nanoseconds.perMillisecond])
    }

    @Test func excessiveCodecDelayThrowsInsteadOfOverflowing() async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "overflow-delay.mkv")
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2), codec: .aac,
            codecPrivate: Data([0x11, 0x90]))
        track.codecDelay = .max
        track.defaultDuration = 1_024 * Nanoseconds.perSecond / 48_000
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data([0])))
        try muxer.finish()
        let input = try await MediaInput.open(url)
        let stage = try await PacketCopyStage(
            input: input, track: try #require(input.audio), number: 1, start: 0, end: .max, destination: .flv)
        await #expect(throws: EngineError.audioCopyTimingUnsupported) { try await stage.pull() }
    }
}

extension AudioCopyTimingTests {
    @Test func excessiveNativePrimingFailsWithinBufferBound() async throws {
        let directory = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        var movie = try Data(contentsOf: original)
        let primingPackets = 65
        let framesPerPacket = 1_024
        let edit = try #require(movie.range(of: Data("elst".utf8), options: .backwards))
        let roll = try #require(movie.range(of: Data("sgpd".utf8)))
        let editMediaTimeOffset = edit.lowerBound + 16
        let rollDistanceOffset = roll.lowerBound + 20
        var mediaTime = Data()
        mediaTime.appendBigEndian(UInt32(primingPackets * framesPerPacket))
        movie.replaceSubrange(editMediaTimeOffset..<(editMediaTimeOffset + 4), with: mediaTime)
        var rollDistance = Data()
        rollDistance.appendBigEndian(Int16(-primingPackets))
        movie.replaceSubrange(rollDistanceOffset..<(rollDistanceOffset + 2), with: rollDistance)
        let url = directory.appending(path: "long-priming.mp4")
        try movie.write(to: url)
        let input = try await MediaInput.open(url)
        let track = try #require(input.audio)
        let asset = AVURLAsset(url: url)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let verification = try AssetTrackReader(asset: asset, track: audio, number: 1, mode: .packets)
        var fullyTrimmed = 0
        while let packets = try await verification.nextPackets() {
            fullyTrimmed += packets.filter { $0.trimDurationAtStart == $0.duration }.count
        }
        try #require(fullyTrimmed == primingPackets)
        let stage = try await PacketCopyStage(
            input: input, track: track, number: 1, start: 0, end: .max, destination: .mkv)
        await #expect(throws: EngineError.audioCopyTimingUnsupported) { try await stage.pull() }
    }
}
