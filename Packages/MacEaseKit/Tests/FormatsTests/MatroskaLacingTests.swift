import Foundation
import Testing

@testable import Formats

@Suite struct MatroskaLacingTests {
    @Test(arguments: [8, 16, 24, 32, 64], [1, 2])
    func pcmLacesUseEachSampleCountAndChannelAlignment(bits: Int, channels: Int) throws {
        let frames = [960, 480, 1_440].map { [UInt8](repeating: 1, count: $0 * channels * (bits / 8)) }
        let packets = try readLaces(frames, bits: bits, channels: channels)
        #expect(packets.map(\.timestamp) == [0, 20_000_000, 30_000_000])
        #expect(packets.map(\.duration) == [20_000_000, 10_000_000, 30_000_000])
        #expect(packets.map(\.payload) == frames.map { Data($0) })
    }

    @Test func pcmLacesUseRestoredHeadersForSampleCounts() throws {
        let packets = try readLaces([[1, 2], [3, 4, 5, 6]], prefix: [9, 10])
        #expect(packets.map(\.timestamp) == [0, 41_666])
        #expect(packets.map(\.duration) == [41_666, 62_500])
        #expect(packets.map(\.payload) == [Data([9, 10, 1, 2]), Data([9, 10, 3, 4, 5, 6])])
    }

    @Test func fractionalSampleDurationsDoNotAccumulateRounding() throws {
        let packets = try readLaces([[UInt8]](repeating: [1, 0], count: 48))
        #expect(packets.last?.timestamp == 979_166)
        #expect(packets.compactMap(\.duration).reduce(0, +) == 1_000_000)
    }

    @Test func defaultDurationBelongsToEachLace() throws {
        let packets = try readLaces(
            [[1], [2, 3], [4, 5, 6]], codecID: "A_UNKNOWN", defaultDuration: 20_000_000, blockDuration: 60)
        #expect(packets.map(\.timestamp) == [0, 20_000_000, 40_000_000])
        #expect(packets.map(\.duration) == [20_000_000, 20_000_000, 20_000_000])
    }

    @Test(arguments: [UInt64(59), 60, 61])
    func pcmSampleCountsTakePriorityOverQuantizedBlockDuration(blockDuration: UInt64) throws {
        let packets = try readLaces(
            [[UInt8]](repeating: [UInt8](repeating: 1, count: 1_920), count: 3), blockDuration: blockDuration)
        #expect(packets.map(\.timestamp) == [0, 20_000_000, 40_000_000])
        #expect(packets.map(\.duration) == [20_000_000, 20_000_000, 20_000_000])
    }

    @Test func equalSizedLacesShareBlockDurationWithoutLosingRemainder() throws {
        let packets = try readLaces([[1], [2], [3]], codecID: "A_UNKNOWN", blockDuration: 61)
        #expect(packets.map(\.timestamp) == [0, 20_333_333, 40_666_666])
        #expect(packets.map(\.duration) == [20_333_333, 20_333_333, 20_333_334])
    }

    @Test func unequalLacesPreservePayloadsDespiteUnresolvedBlockDuration() throws {
        let packets = try readLaces([[1], [2, 3]], codecID: "A_UNKNOWN", blockDuration: 40)
        #expect(packets.map(\.payload) == [Data([1]), Data([2, 3])])
        #expect(packets.map(\.duration) == [nil, nil])
        #expect(packets.map(\.continuesPrevious) == [false, true])
        #expect(packets.map(\.laceDuration) == [40_000_000, nil])
        #expect(packets.map(\.remainingLaceFrames) == [1, 0])
    }

    @Test func vorbisLacesWithoutDefaultDurationDemuxWithoutError() throws {
        let packets = try readLaces([[1], [2]], codecID: "A_VORBIS")
        #expect(packets.map(\.payload) == [Data([1]), Data([2])])
        #expect(packets.map(\.duration) == [nil, nil])
        #expect(packets.map(\.continuesPrevious) == [false, true])
    }

    @Test func unalignedPCMLacesRefuseBeforeReturningPackets() throws {
        #expect(throws: FormatError.corrupt("unaligned PCM packet")) {
            try readLaces([[1, 2], [3]])
        }
    }

    @Test func zeroDefaultDurationRefuses() throws {
        #expect(throws: FormatError.corrupt("DefaultDuration out of range")) {
            try readLaces([[1, 2], [3, 4]], defaultDuration: 0)
        }
    }

    @Test func opusLacesUsePacketSampleCounts() throws {
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let frames = try encoder.encode([Float](repeating: 0.25, count: 2 * 960)).map { Array($0) }
        try #require(frames.count == 2)
        let packets = try readLaces(frames, codecID: "A_OPUS")
        #expect(packets.map(\.timestamp) == [0, 20_000_000])
        #expect(packets.map(\.duration) == [20_000_000, 20_000_000])
        #expect(packets.map(\.payload) == frames.map { Data($0) })
    }

    @Test func ac3LacesUseFixedSampleCounts() throws {
        var demuxer = try MatroskaDemuxer(url: ContainerFixtures.resource("ffmpeg-mpeg4-ac3-srt.mkv"))
        let track = try #require(demuxer.tracks.first { $0.codec == .ac3 })
        var frames: [[UInt8]] = []
        while frames.count < 2, let packet = try demuxer.nextPacket() {
            if packet.track == track.number { frames.append(Array(packet.payload)) }
        }
        try #require(frames.count == 2)
        let packets = try readLaces(frames, codecID: "A_AC3")
        #expect(packets.map(\.timestamp) == [0, 32_000_000])
        #expect(packets.map(\.duration) == [32_000_000, 32_000_000])
    }

    @Test(arguments: [false, true])
    func aacLacesRespectConfiguredFrameLength(shortFrames: Bool) throws {
        let configuration: [UInt8] = [0x11, shortFrames ? 0x94 : 0x90]
        let packets = try readLaces(
            [[1], [2, 3]], codecID: "A_AAC", channels: 2, codecPrivate: configuration)
        let frameDuration: Int64 = shortFrames ? 20_000_000 : 21_333_333
        #expect(packets.map(\.timestamp) == [0, frameDuration])
        #expect(packets.map(\.duration) == [frameDuration, frameDuration])
    }

    @Test func mp3LacesRespectMPEGVersionAndSamplingFrequency() throws {
        let configurations: [(UInt8, Double)] = [(0xFB, 44_100), (0xF3, 22_050), (0xE3, 11_025)]
        for (header, sampleRate) in configurations {
            let packets = try readLaces(
                [[0xFF, header, 0x90, 0], [0xFF, header, 0x90, 0]], codecID: "A_MPEG/L3", sampleRate: sampleRate)
            let frameDuration: Int64 = sampleRate == 11_025 ? 52_244_897 : 26_122_448
            #expect(packets.map(\.timestamp) == [0, frameDuration])
            #expect(packets.map(\.duration) == [frameDuration, frameDuration + 1])
        }
    }

    @Test func unsupportedAACConfigurationDoesNotInventFrameTiming() throws {
        let packets = try readLaces([[1], [2, 3]], codecID: "A_AAC", codecPrivate: [0x29, 0x90])
        #expect(packets.map(\.payload) == [Data([1]), Data([2, 3])])
        #expect(packets.map(\.duration) == [nil, nil])
        #expect(packets.map(\.continuesPrevious) == [false, true])
    }

    @Test(arguments: [[UInt8(0x17), 0x90], [0x11, 0x80], [0x16, 0x90]])
    func unreadableAACTimingRemainsAvailableToOtherTracks(configuration: [UInt8]) throws {
        let packets = try readLaces([[1], [2, 3]], codecID: "A_AAC", codecPrivate: configuration)
        #expect(packets.map(\.payload) == [Data([1]), Data([2, 3])])
        #expect(packets.map(\.duration) == [nil, nil])
        #expect(packets.map(\.continuesPrevious) == [false, true])
    }

    @Test func unreadableOpusTimingRemainsAvailableToOtherTracks() throws {
        let packets = try readLaces([[], [3]], codecID: "A_OPUS")
        #expect(packets.map(\.payload) == [Data(), Data([3])])
        #expect(packets.map(\.duration) == [nil, nil])
        #expect(packets.map(\.continuesPrevious) == [false, true])
    }

    private func readLaces(
        _ frames: [[UInt8]], codecID: String = "A_PCM/INT/LIT", bits: Int = 16, channels: Int = 1,
        sampleRate: Double = 48_000, codecPrivate: [UInt8]? = nil, defaultDuration: UInt64? = nil,
        blockDuration: UInt64? = nil, prefix: [UInt8]? = nil
    ) throws -> [MediaPacket] {
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        var properties =
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
            + EBML.element(MatroskaID.trackType, unsigned: 2)
            + EBML.element(MatroskaID.codecID, string: codecID)
            + EBML.element(
                MatroskaID.audio,
                EBML.element(MatroskaID.samplingFrequency, float: sampleRate)
                    + EBML.element(MatroskaID.channels, unsigned: UInt64(channels))
                    + EBML.element(MatroskaID.bitDepth, unsigned: UInt64(bits)))
        if let defaultDuration { properties += EBML.element(MatroskaID.defaultDuration, unsigned: defaultDuration) }
        if let codecPrivate { properties += EBML.element(MatroskaID.codecPrivate, codecPrivate) }
        if let prefix {
            properties += EBML.element(
                MatroskaID.contentEncodings,
                EBML.element(
                    MatroskaID.contentEncoding,
                    EBML.element(
                        MatroskaID.contentCompression,
                        EBML.element(MatroskaID.contentCompAlgo, unsigned: 3)
                            + EBML.element(MatroskaID.contentCompSettings, prefix))))
        }
        var block: [UInt8] = [0x81, 0, 0, 0x82, UInt8(frames.count - 1)]
        for frame in frames.dropLast() {
            block += [UInt8](repeating: 255, count: frame.count / 255)
            block.append(UInt8(frame.count % 255))
        }
        block += frames.flatMap { $0 }
        let element: [UInt8]
        if let blockDuration {
            block[3] &= 0x7F
            element = EBML.element(
                MatroskaID.blockGroup,
                EBML.element(MatroskaID.block, block)
                    + EBML.element(MatroskaID.blockDuration, unsigned: blockDuration))
        } else {
            element = EBML.element(MatroskaID.simpleBlock, block)
        }
        let segment =
            EBML.element(MatroskaID.tracks, EBML.element(MatroskaID.trackEntry, properties))
            + EBML.element(MatroskaID.cluster, EBML.element(MatroskaID.clusterTimestamp, unsigned: 0) + element)
        let url = ContainerFixtures.temporaryURL("laced.mkv")
        try Data(header + EBML.element(MatroskaID.segment, segment)).write(to: url)
        var demuxer = try MatroskaDemuxer(url: url)
        return try ContainerFixtures.packets(&demuxer)
    }
}
