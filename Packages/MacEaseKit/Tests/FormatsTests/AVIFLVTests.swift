import Foundation
import Testing

@testable import Formats

private typealias Fixture = ContainerFixtures

@Suite struct AVITests {
    @Test func rejectsRepeatedAndOverlappingOpenDMLIndexes() throws {
        var track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        track.defaultDuration = 40 * Nanoseconds.perMillisecond
        let url = Fixture.temporaryURL("repeated-index.avi")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try AVIMuxer(url: url, tracks: [track])
        for frame in 0..<2 {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(frame) * 40 * Nanoseconds.perMillisecond,
                    isKeyframe: frame == 0, payload: Data([UInt8(frame)])))
        }
        try muxer.finish()

        var valid = try AVIDemuxer(url: url)
        #expect(try Fixture.packets(&valid).map(\.isKeyframe) == [true, false])

        let original = try Data(contentsOf: url)
        let indexChunk = try #require(original.range(of: Data("indx".utf8)))
        let firstEntry = indexChunk.lowerBound + 8 + AVI.indexHeaderSize
        let secondEntry = firstEntry + AVI.superIndexEntrySize
        let bytes = [UInt8](original)
        let offset =
            UInt64(UInt32(littleEndian: bytes, at: firstEntry))
            | UInt64(UInt32(littleEndian: bytes, at: firstEntry + 4)) << 32
        for delta in [UInt64(0), 1] {
            var malformed = original
            malformed.replaceSubrange(
                (indexChunk.lowerBound + 12)..<(indexChunk.lowerBound + 16),
                with: [2, 0, 0, 0])
            malformed.replaceSubrange(
                secondEntry..<(secondEntry + AVI.superIndexEntrySize),
                with: original[firstEntry..<(firstEntry + AVI.superIndexEntrySize)])
            var repeatedOffset = Data()
            repeatedOffset.appendLittleEndian(offset - delta)
            malformed.replaceSubrange(secondEntry..<(secondEntry + 8), with: repeatedOffset)
            try malformed.write(to: url)
            #expect(throws: FormatError.corrupt("overlapping AVI index references")) {
                try AVIDemuxer(url: url)
            }
        }

        let shortIndexSize = AVI.indexHeaderSize + AVI.superIndexEntrySize
        let fullIndexSize = Int(UInt32(littleEndian: bytes, at: indexChunk.lowerBound + 4))
        var duplicate = original
        var shortSize = Data()
        shortSize.appendLittleEndian(UInt32(shortIndexSize))
        duplicate.replaceSubrange((indexChunk.lowerBound + 4)..<(indexChunk.lowerBound + 8), with: shortSize)
        var followingIndex = Data("indx".utf8)
        followingIndex.appendLittleEndian(UInt32(fullIndexSize - shortIndexSize - 8))
        followingIndex.append(original[(indexChunk.lowerBound + 8)..<(indexChunk.lowerBound + 8 + shortIndexSize)])
        duplicate.replaceSubrange(secondEntry..<(secondEntry + followingIndex.count), with: followingIndex)
        try duplicate.write(to: url)
        #expect(throws: FormatError.corrupt("duplicate AVI stream index")) {
            try AVIDemuxer(url: url)
        }
    }

    @Test func cancelledInitializationStopsBeforeIndexTraversal() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try AVIDemuxer(url: Fixture.resource("ffmpeg-mjpeg-pcm.avi"))
            }
        }
        await task.value
    }

    @Test(arguments: [Data([0, 0, 0, 0]), Data([1, 64, 0, 0])])
    func rejectsInvalidVideoWidth(bytes: Data) throws {
        var avi = try Data(contentsOf: Fixture.resource("ffmpeg-mjpeg-pcm.avi"))
        let formatChunk = try #require(avi.range(of: Data("strf".utf8)))
        let widthOffset = formatChunk.lowerBound + 12
        avi.replaceSubrange(widthOffset..<(widthOffset + 4), with: bytes)
        let url = Fixture.temporaryURL("invalid-width.avi")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        try avi.write(to: url)
        #expect(throws: FormatError.corrupt("video dimensions out of range")) {
            try AVIDemuxer(url: url)
        }
    }

    @Test func readsFFmpegMotionJPEGWithPCM() throws {
        var demuxer = try AVIDemuxer(url: Fixture.resource("ffmpeg-mjpeg-pcm.avi"))
        #expect(demuxer.tracks.map(\.codec) == [.mjpeg, .pcm(bits: 16, float: false, bigEndian: false)])
        #expect(demuxer.tracks.map(\.number) == [1, 2])
        #expect(demuxer.tracks[0].kind == .video(width: 96, height: 64))
        #expect(demuxer.tracks[1].kind == .audio(sampleRate: 8000, channels: 1))
        #expect(demuxer.duration == Nanoseconds.perSecond)
        let packets = try Fixture.packets(&demuxer)
        let video = packets.filter { $0.track == 1 }
        #expect(video.map(\.timestamp) == (0..<10).map { Int64($0) * 100 * Nanoseconds.perMillisecond })
        #expect(video.allSatisfy { $0.isKeyframe })
        let frame = try Fixtures.decode(video[3].payload)
        #expect(frame.width == 96 && frame.height == 64)
        let audio = packets.filter { $0.track == 2 }
        #expect(audio.reduce(0) { $0 + $1.payload.count } == 16_000)
        #expect(audio.last.map { $0.timestamp > 800 * Nanoseconds.perMillisecond } == true)
    }

    @Test func readsKeyframeFlagsAndCodecTags() throws {
        var demuxer = try AVIDemuxer(url: Fixture.resource("ffmpeg-mpeg4-ac3.avi"))
        #expect(demuxer.tracks.map(\.codec) == [.mpeg4Part2, .ac3])
        let packets = try Fixture.packets(&demuxer)
        let video = packets.filter { $0.track == 1 }
        #expect(video.map(\.isKeyframe) == (0..<20).map { $0 % 5 == 0 })
        #expect(packets.filter { $0.track == 2 }.count == 63)
    }

    @Test func remuxKeepsPayloadsTimingAndDroppedFrames() throws {
        var source = try AVIDemuxer(url: Fixture.resource("ffmpeg-mjpeg-pcm.avi"))
        let packets = try Fixture.packets(&source).filter {
            $0.track == 2 || $0.timestamp != 500 * Nanoseconds.perMillisecond
        }
        let url = Fixture.temporaryURL("remux.avi")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try AVIMuxer(url: url, tracks: source.tracks)
        for packet in packets { try muxer.write(packet) }
        try muxer.finish()

        var demuxer = try AVIDemuxer(url: url)
        #expect(demuxer.tracks == source.tracks)
        #expect(demuxer.duration == Nanoseconds.perSecond)
        let read = try Fixture.packets(&demuxer)
        #expect(read.map(\.payload) == packets.map(\.payload))
        #expect(read.map(\.timestamp) == packets.map(\.timestamp))
        #expect(read.map(\.isKeyframe) == packets.map(\.isKeyframe))
    }

    @Test func keyframeFlagsSurviveOpenDMLSegmentsPastOneGigabyte() throws {
        var track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        track.defaultDuration = 40 * Nanoseconds.perMillisecond
        let url = Fixture.temporaryURL("large.avi")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try AVIMuxer(url: url, tracks: [track])
        let payload = Data(count: 96 << 20)
        let keyframes = (0..<12).map { $0 % 3 == 0 }
        for (frame, keyframe) in keyframes.enumerated() {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(frame) * 40 * Nanoseconds.perMillisecond, isKeyframe: keyframe,
                    payload: payload))
        }
        try muxer.finish()

        var demuxer = try AVIDemuxer(url: url)
        #expect(demuxer.segments.count == 2)
        #expect(demuxer.duration == Int64(keyframes.count) * 40 * Nanoseconds.perMillisecond)
        var flags: [Bool] = []
        while let packet = try demuxer.nextPacket() {
            #expect(packet.payload.count == payload.count)
            #expect(packet.timestamp == Int64(flags.count) * 40 * Nanoseconds.perMillisecond)
            flags.append(packet.isKeyframe)
        }
        #expect(flags == keyframes)
    }

    @Test func fillsAudioGapsWithSilence() throws {
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 1000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        let url = Fixture.temporaryURL("gap.avi")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try AVIMuxer(url: url, tracks: [track])
        let tone = Data(repeating: 7, count: 200)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: tone))
        try muxer.write(
            MediaPacket(track: 1, timestamp: 200 * Nanoseconds.perMillisecond, isKeyframe: true, payload: tone))
        #expect(throws: FormatError.self) {
            try muxer.write(
                MediaPacket(track: 1, timestamp: 250 * Nanoseconds.perMillisecond, isKeyframe: true, payload: tone))
        }
        try muxer.finish()

        var demuxer = try AVIDemuxer(url: url)
        let read = try Fixture.packets(&demuxer)
        #expect(read.map(\.timestamp) == [0, 100, 200].map { $0 * Nanoseconds.perMillisecond })
        #expect(read.map(\.payload) == [tone, Data(count: 200), tone])
    }

    @Test func refusesUnrepresentableInput() throws {
        var h264 = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .h264)
        h264.defaultDuration = Nanoseconds.perSecond / 30
        #expect(throws: FormatError.self) { try AVIMuxer(url: Fixture.temporaryURL("x.avi"), tracks: [h264]) }
        let mp3 = MediaTrack(number: 1, kind: .audio(sampleRate: 44_100, channels: 2), codec: .mp3)
        #expect(throws: FormatError.self) { try AVIMuxer(url: Fixture.temporaryURL("y.avi"), tracks: [mp3]) }
        let empty = MediaTrack(
            number: 1, kind: .audio(sampleRate: 44_100, channels: 2),
            codec: .pcm(bits: 0, float: false, bigEndian: false))
        #expect(throws: FormatError.self) { try AVIMuxer(url: Fixture.temporaryURL("z.avi"), tracks: [empty]) }

        var video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        video.defaultDuration = 40 * Nanoseconds.perMillisecond
        let url = Fixture.temporaryURL("close.avi")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try AVIMuxer(url: url, tracks: [video])
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data([1])))
        #expect(throws: FormatError.self) {
            try muxer.write(
                MediaPacket(track: 1, timestamp: 10 * Nanoseconds.perMillisecond, isKeyframe: true, payload: Data([2])))
        }
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let url = Fixture.temporaryURL("existing.avi")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        var track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        track.defaultDuration = 40 * Nanoseconds.perMillisecond
        #expect(throws: FormatError.self) { try AVIMuxer(url: url, tracks: [track]) }
        #expect(try Data(contentsOf: url) == Data("original".utf8))
    }
}

@Suite struct FLVTests {
    @Test func rejectsOversizedSPSDimensions() throws {
        let oversizedSPS: [UInt8] = [0x67, 0x42, 0, 0x33, 0xF4, 0, 0x20, 0x0F, 0x20]
        let pictureParameters: [UInt8] = [0x28, 0xEE, 0x3C, 0xB0]
        let configuration: [UInt8] =
            [1, 0x42, 0, 0x33, 0xFF, 0xE1, 0, UInt8(oversizedSPS.count)] + oversizedSPS
            + [1, 0, UInt8(pictureParameters.count)] + pictureParameters
        let body: [UInt8] = [0x17, 0, 0, 0, 0] + configuration
        let tagSize = body.count
        var tag: [UInt8] = [
            9, UInt8(tagSize >> 16), UInt8(tagSize >> 8), UInt8(tagSize),
            0, 0, 0, 0, 0, 0, 0,
        ]
        tag += body
        var flv = Data([0x46, 0x4C, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0])
        flv.append(contentsOf: tag)
        flv.append(contentsOf: [0, 0, 0, UInt8(tag.count)])
        let url = Fixture.temporaryURL("oversized.flv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        try flv.write(to: url)
        #expect(throws: FormatError.corrupt("video dimensions out of range")) {
            try FLVDemuxer(url: url)
        }
    }

    @Test func readsFFmpegH264WithAAC() throws {
        var demuxer = try FLVDemuxer(url: Fixture.resource("ffmpeg-h264-aac.flv"))
        #expect(demuxer.tracks.map(\.codec) == [.h264, .aac])
        #expect(demuxer.tracks[0].kind == .video(width: 96, height: 64))
        #expect(demuxer.tracks[1].kind == .audio(sampleRate: 44_100, channels: 2))
        #expect(demuxer.tracks.allSatisfy { $0.codecPrivate != nil })
        let duration = try #require(demuxer.duration)
        #expect(abs(duration - 2_023 * Nanoseconds.perMillisecond) < 5 * Nanoseconds.perMillisecond)
        let packets = try Fixture.packets(&demuxer)
        let video = packets.filter { $0.track == FLV.videoTrack }
        #expect(video.first?.timestamp == 23 * Nanoseconds.perMillisecond)
        #expect(video.map(\.isKeyframe) == (0..<20).map { $0 % 5 == 0 })
        #expect(packets.filter { $0.track == FLV.audioTrack }.count == 88)
    }

    @Test func remuxKeepsCompositionOffsets() throws {
        var source = try FLVDemuxer(url: Fixture.resource("ffmpeg-h264-aac.flv"))
        var packets = try Fixture.packets(&source)
        for index in packets.indices where packets[index].track == FLV.videoTrack {
            let decode = packets[index].timestamp
            packets[index].decodeTimestamp = decode
            packets[index].timestamp = decode + Int64(index % 3) * 100 * Nanoseconds.perMillisecond
        }
        let url = Fixture.temporaryURL("remux.flv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try FLVMuxer(url: url, tracks: source.tracks)
        for packet in packets { try muxer.write(packet) }
        try muxer.finish()

        var demuxer = try FLVDemuxer(url: url)
        #expect(demuxer.tracks == source.tracks)
        let read = try Fixture.packets(&demuxer)
        #expect(read.count == packets.count)
        for (original, decoded) in zip(packets, read) {
            #expect(decoded.track == original.track)
            #expect(decoded.timestamp == original.timestamp)
            #expect(decoded.decodeTimestamp == original.decodeTimestamp)
            #expect(decoded.isKeyframe == original.isKeyframe)
            #expect(decoded.payload == original.payload)
        }
        #expect(demuxer.duration == packets.map(\.timestamp).max())
    }

    @Test func metadataToleratesOptionalAMFValues() throws {
        func key(_ name: String) -> [UInt8] { [0, UInt8(name.utf8.count)] + Array(name.utf8) }
        let five = withUnsafeBytes(of: Double(5).bitPattern.bigEndian, Array.init)
        let typed = [2] + key("onMetaData") + [16] + key("Info") + key("duration") + [0] + five
        let body = typed + key("reference") + [7, 0, 1] + key("unsupported") + [13] + [0, 0, 9]
        #expect(try FLV.metadata(body) == ["duration": 5])
        #expect(try FLV.metadata([1, 1]).isEmpty)
    }

    @Test func encoderWrittenMetadataIsRegeneratedButTitlesAreNot() throws {
        func key(_ name: String) -> [UInt8] { [0, UInt8(name.utf8.count)] + Array(name.utf8) }
        func number(_ name: String) -> [UInt8] {
            key(name) + [0] + withUnsafeBytes(of: Double(1).bitPattern.bigEndian, Array.init)
        }
        func text(_ name: String, _ value: String) -> [UInt8] { key(name) + [2] + key(value) }
        let technical =
            [
                "duration", "width", "height", "videodatarate", "framerate", "videocodecid", "audiodatarate",
                "audiosamplerate", "audiosamplesize", "audiocodecid", "filesize",
            ]
            .flatMap(number) + key("stereo") + [1, 1] + text("encoder", "Lavf63.1.102")
        let header = [2] + key("onMetaData") + [8, 0, 0, 0, 13]
        let end: [UInt8] = [0, 0, 9]
        #expect(try FLV.isRegeneratedMetadata(header + technical + end))
        #expect(try !FLV.isRegeneratedMetadata(header + technical + text("title", "Holiday") + end))
    }

    @Test func refusesStreamsTheProbeNeverSaw() throws {
        var source = try FLVDemuxer(url: Fixture.resource("ffmpeg-h264-aac.flv"))
        let audio = try Fixture.packets(&source).filter { $0.track == FLV.audioTrack }
        let url = Fixture.temporaryURL("late.flv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try FLVMuxer(url: url, tracks: [source.tracks[1]])
        for round in 0..<25 {
            for packet in audio {
                var shifted = packet
                shifted.timestamp += Int64(round) * 3 * Nanoseconds.perSecond
                try muxer.write(shifted)
            }
        }
        try muxer.finish()
        var bytes = try Data(contentsOf: url)
        let body: [UInt8] = [0x17, 1, 0, 0, 0, 0, 0, 0, 1, 0x65]
        bytes += [FLV.videoTag, 0, 0, UInt8(body.count), 0, 0, 0, 0, 0, 0, 0] + body
        bytes += [0, 0, 0, UInt8(FLV.tagHeaderSize + body.count)]
        try bytes.write(to: url)

        var demuxer = try FLVDemuxer(url: url)
        #expect(demuxer.tracks.map(\.codec) == [.aac])
        #expect(throws: FormatError.self) { _ = try Fixture.packets(&demuxer) }
    }

    @Test func refusesUnsupportedInput() throws {
        let vp9 = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9, codecPrivate: Data([1]))
        #expect(throws: FormatError.self) { try FLVMuxer(url: Fixture.temporaryURL("v.flv"), tracks: [vp9]) }

        var source = try FLVDemuxer(url: Fixture.resource("ffmpeg-h264-aac.flv"))
        let url = Fixture.temporaryURL("negative.flv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try FLVMuxer(url: url, tracks: source.tracks)
        var packet = try #require(try source.nextPacket())
        packet.decodeTimestamp = -Nanoseconds.perMillisecond
        #expect(throws: FormatError.self) { try muxer.write(packet) }
    }
}

@Suite struct TimeScalingTests {
    @Test func scalesWithoutIntermediateOverflow() throws {
        let ticks: Int64 = 9_224 * 1_000_000
        #expect(try Nanoseconds.scale(ticks, by: Nanoseconds.perSecond, over: 25_000_000) == 368_960_000_000)
        #expect(throws: FormatError.self) { try Nanoseconds.scale(.max / 2, by: 3, over: 1) }
        #expect(throws: FormatError.self) { try Nanoseconds.from(seconds: .nan) }
        #expect(throws: FormatError.self) { try Nanoseconds.from(seconds: 1e300) }
    }
}
