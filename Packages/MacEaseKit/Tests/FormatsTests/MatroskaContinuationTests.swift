import Foundation
import Testing

@testable import Formats

@Suite struct MatroskaContinuationTests {
    @Test func incompleteLacesBoundInterleavedPayloadMemory() throws {
        let video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        let audio = MediaTrack(number: 2, kind: .audio(sampleRate: 48_000, channels: 1), codec: .vorbis)
        let url = ContainerFixtures.temporaryURL("bounded-lace.mkv")
        var muxer = try MatroskaMuxer(url: url, tracks: [video, audio], webm: false)
        try muxer.write(
            MediaPacket(track: 2, timestamp: 0, isKeyframe: true, payload: Data([1]), remainingLaceFrames: 1))
        let packet = MediaPacket(
            track: 1, timestamp: 0, isKeyframe: true, payload: Data(repeating: 0, count: 5_000_000))
        for _ in 0..<49 { try muxer.write(packet) }
        #expect(throws: FormatError.corrupt(String(localized: "Matroska cluster too large"))) {
            try muxer.write(packet)
        }
    }

    @Test func interleavedSameTimestampRetainsLaceAndBlockAdditions() throws {
        var video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        video.hasAlpha = true
        let audio = MediaTrack(number: 2, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus)
        let alpha = Data([9, 8])
        let first = MediaPacket(
            track: 1, timestamp: 0, isKeyframe: true, payload: Data([1, 2, 3]), additional: alpha,
            remainingLaceFrames: 1)
        let between = MediaPacket(track: 2, timestamp: 0, isKeyframe: true, payload: Data([7]))
        let continuation = MediaPacket(
            track: 1, timestamp: 0, isKeyframe: true, payload: Data(repeating: 4, count: 255),
            additional: alpha, continuesPrevious: true, remainingLaceFrames: 0)
        let url = ContainerFixtures.temporaryURL("interleaved-lace.webm")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [video, audio], webm: true)
        for packet in [first, between, continuation] { try muxer.write(packet) }
        try muxer.finish()

        var demuxer = try MatroskaDemuxer(url: url)
        let packets = try ContainerFixtures.packets(&demuxer)
        let videoPackets = packets.filter { $0.track == 1 }
        #expect(videoPackets.map(\.payload) == [first.payload, continuation.payload])
        #expect(videoPackets.map(\.continuesPrevious) == [false, true])
        #expect(videoPackets.map(\.remainingLaceFrames) == [1, 0])
        #expect(videoPackets.map(\.timestamp) == [0, 0])
        #expect(videoPackets.map(\.duration) == [nil, nil])
        #expect(videoPackets.map(\.additional) == [alpha, alpha])
        #expect(packets.filter { $0.track == 2 }.map(\.payload) == [between.payload])
    }

    @Test func thresholdWithinLaceRetainsFinalPadding() throws {
        let audio = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2), codec: .aac,
            codecPrivate: Data([0x29, 0x90]))
        let video = MediaTrack(number: 2, kind: .video(width: 16, height: 16), codec: .vp9)
        let firstVideo = MediaPacket(
            track: 2, timestamp: 40_000_000, isKeyframe: true, payload: Data([1]))
        let first = MediaPacket(
            track: 1, timestamp: 40_000_000, isKeyframe: true,
            payload: Data(repeating: 0xA5, count: (5 << 20) + 1), remainingLaceFrames: 1)
        let reorderedVideo = MediaPacket(
            track: 2, timestamp: 0, isKeyframe: false, payload: Data([2]))
        var last = MediaPacket(
            track: 1, timestamp: 40_000_000, isKeyframe: true, payload: Data([0xB6]),
            continuesPrevious: true, remainingLaceFrames: 0)
        last.discardPadding = 12_000_000
        let url = ContainerFixtures.temporaryURL("large-lace.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [audio, video], webm: false)
        for packet in [firstVideo, first, reorderedVideo, last] { try muxer.write(packet) }
        try muxer.finish()

        var demuxer = try MatroskaDemuxer(url: url)
        let packets = try ContainerFixtures.packets(&demuxer)
        let audioPackets = packets.filter { $0.track == 1 }
        #expect(audioPackets.map(\.payload) == [first.payload, last.payload])
        #expect(audioPackets.map(\.continuesPrevious) == [false, true])
        #expect(audioPackets.map(\.remainingLaceFrames) == [1, 0])
        #expect(audioPackets.map(\.timestamp) == [40_000_000, 40_000_000])
        #expect(audioPackets.map(\.duration) == [nil, nil])
        #expect(audioPackets.map(\.discardPadding) == [nil, last.discardPadding])
        #expect(packets.filter { $0.track == 2 }.map(\.timestamp) == [40_000_000, 0])
    }

    @Test func refusesMoreThan256FramesInOneLace() throws {
        let video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        let url = ContainerFixtures.temporaryURL("oversized-lace.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [video], webm: false)
        for index in 0..<256 {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: 0, isKeyframe: true, payload: Data([UInt8(index)]),
                    continuesPrevious: index > 0, remainingLaceFrames: 255 - index))
        }
        #expect(throws: FormatError.encoderFailure(String(localized: "Matroska lace cannot be represented"))) {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: 0, isKeyframe: true, payload: Data([0]), continuesPrevious: true))
        }
        try muxer.finish()
        var demuxer = try MatroskaDemuxer(url: url)
        #expect(try ContainerFixtures.packets(&demuxer).count == 256)
    }

    @Test func refusesDifferentBlockAdditionsWithinLace() throws {
        var video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        video.hasAlpha = true
        let url = ContainerFixtures.temporaryURL("different-alpha.webm")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [video], webm: true)
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: 0, isKeyframe: true, payload: Data([1]), additional: Data([9]),
                remainingLaceFrames: 1))
        #expect(throws: FormatError.encoderFailure(String(localized: "Matroska lace cannot be represented"))) {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: 0, isKeyframe: true, payload: Data([2]),
                    additional: Data([8]), continuesPrevious: true))
        }
    }

    @Test func unequalLacesRetainWholeBlockDuration() throws {
        let audio = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2), codec: .aac,
            codecPrivate: Data([0x29, 0x90]))
        let first = MediaPacket(
            track: 1, timestamp: 10_000_000, isKeyframe: true, payload: Data([1]),
            remainingLaceFrames: 1, laceDuration: 61_000_000)
        let last = MediaPacket(
            track: 1, timestamp: 10_000_000, isKeyframe: true, payload: Data([2, 3]),
            continuesPrevious: true, remainingLaceFrames: 0)
        let url = ContainerFixtures.temporaryURL("unequal-duration.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [audio], webm: false)
        try muxer.write(first)
        try muxer.write(last)
        try muxer.finish()

        var demuxer = try MatroskaDemuxer(url: url)
        let packets = try ContainerFixtures.packets(&demuxer)
        #expect(packets.map(\.payload) == [first.payload, last.payload])
        #expect(packets.map(\.timestamp) == [10_000_000, 10_000_000])
        #expect(packets.map(\.duration) == [nil, nil])
        #expect(packets.map(\.continuesPrevious) == [false, true])
        #expect(packets.map(\.remainingLaceFrames) == [1, 0])
        #expect(packets.map(\.laceDuration) == [61_000_000, nil])
        #expect(demuxer.duration == 71_000_000)
    }

    @Test func refusesUnfinishedLaceAtFinish() throws {
        let video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        let url = ContainerFixtures.temporaryURL("unfinished-lace.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [video], webm: false)
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: 0, isKeyframe: true, payload: Data([1]), remainingLaceFrames: 1))
        #expect(throws: FormatError.encoderFailure(String(localized: "Matroska lace cannot be represented"))) {
            try muxer.finish()
        }
    }
}
