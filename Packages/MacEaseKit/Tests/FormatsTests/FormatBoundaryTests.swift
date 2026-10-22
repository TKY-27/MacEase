import Foundation
import Testing

@testable import Formats

@Suite struct FormatBoundaryTests {
    @Test(arguments: [(32, 1, 4, 4), (1, 256, 4, 4), (1, 1, 65_536, 4), (1, 1, 4, 65_536)])
    func avcRejectsUnrepresentableParameterSets(spsCount: Int, ppsCount: Int, spsLength: Int, ppsLength: Int) {
        let keyframe = annexB(spsCount: spsCount, ppsCount: ppsCount, spsLength: spsLength, ppsLength: ppsLength)
        #expect(throws: FormatError.corrupt(String(localized: "H.264 parameter sets out of range"))) {
            try VideoFormat.avcConfiguration(annexB: keyframe)
        }
    }

    @Test func avcAcceptsMaximumParameterSetFields() throws {
        let keyframe = annexB(spsCount: 31, ppsCount: 255, spsLength: 65_535, ppsLength: 65_535)
        let record = try VideoFormat.avcConfiguration(annexB: keyframe)
        let sequenceBytes = 31 * (2 + 65_535)
        #expect(record[5] == 0xFF)
        #expect(record[6..<8] == Data([0xFF, 0xFF]))
        #expect(record[6 + sequenceBytes] == 255)
        #expect(record.count == 7 + sequenceBytes + 255 * (2 + 65_535))
    }

    private func annexB(spsCount: Int, ppsCount: Int, spsLength: Int, ppsLength: Int) -> Data {
        let startCode = Data([0, 0, 1])
        let sequence = startCode + Data([0x67]) + Data(repeating: 0x42, count: spsLength - 1)
        let picture = startCode + Data([0x68]) + Data(repeating: 0x42, count: ppsLength - 1)
        var keyframe = Data()
        for _ in 0..<spsCount { keyframe.append(sequence) }
        for _ in 0..<ppsCount { keyframe.append(picture) }
        return keyframe
    }

    @Test(arguments: [(Int64.max, Int64(0)), (Int64.max, Int64.max), (1920, 960), (960, 3000)])
    func opusRejectsInvalidGranules(firstGranule: Int64, lastGranule: Int64) throws {
        let url = ContainerFixtures.temporaryURL("granules.opus")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let packets = try encoder.encode([Float](repeating: 0, count: OpusAudioEncoder.frameSamples * 2))
        #expect(packets.count == 2)
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(encoder.identificationHeader)
        try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        try writer.writeHeader(try #require(packets.first))
        try writer.write(try #require(packets.last), granule: lastGranule, last: true)
        try writer.close()
        try setFirstAudioGranule(firstGranule, at: url)
        let reader = try OggAudioReader(url: url)
        #expect(throws: FormatError.corrupt(String(localized: "Ogg granule out of range"))) {
            while try reader.read() != nil {}
        }
    }

    private func setFirstAudioGranule(_ granule: Int64, at url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        let pageHeaderBytes = 27
        let granuleOffset = 6
        let checksumOffset = 22
        let segmentCountOffset = 26
        let checksumPolynomial: UInt32 = 0x04C1_1DB7
        var offset = 0
        for _ in 0..<2 {
            let segments = Int(bytes[offset + segmentCountOffset])
            let bodyBytes = bytes[(offset + pageHeaderBytes)..<(offset + pageHeaderBytes + segments)].reduce(0) {
                $0 + Int($1)
            }
            offset += pageHeaderBytes + segments + bodyBytes
        }
        let segments = Int(bytes[offset + segmentCountOffset])
        let bodyBytes = bytes[(offset + pageHeaderBytes)..<(offset + pageHeaderBytes + segments)].reduce(0) {
            $0 + Int($1)
        }
        let end = offset + pageHeaderBytes + segments + bodyBytes
        for octet in 0..<MemoryLayout<Int64>.size {
            bytes[offset + granuleOffset + octet] = UInt8(truncatingIfNeeded: granule >> (octet * 8))
        }
        for octet in 0..<MemoryLayout<UInt32>.size { bytes[offset + checksumOffset + octet] = 0 }
        var checksum: UInt32 = 0
        for byte in bytes[offset..<end] {
            checksum ^= UInt32(byte) << 24
            for _ in 0..<8 {
                checksum = checksum & 0x8000_0000 == 0 ? checksum << 1 : (checksum << 1) ^ checksumPolynomial
            }
        }
        for octet in 0..<MemoryLayout<UInt32>.size {
            bytes[offset + checksumOffset + octet] = UInt8(truncatingIfNeeded: checksum >> (octet * 8))
        }
        try Data(bytes).write(to: url)
        let packets = try OggPacketReader(url: url)
        _ = try packets.next()
        _ = try packets.next()
        #expect(try packets.next()?.granule == granule)
    }

    @Test func icnsRejectsDuplicateImageTypesBeforeDecoding() throws {
        let png = try Fixtures.encode(Fixtures.photo(width: 16, height: 16), as: .png)
        var body = Data()
        for payload in [Data(), png] {
            body.append(Data("ic10".utf8))
            body.appendBigEndian(UInt32(payload.count + 8))
            body.append(payload)
        }
        var icns = Data("icns".utf8)
        icns.appendBigEndian(UInt32(body.count + 8))
        icns.append(body)
        #expect(throws: FormatError.corrupt(String(localized: "Duplicate ICNS element type"))) {
            try ICNSFile.read(icns)
        }
    }

    @Test(arguments: [16, 24])
    func aviWritesBoundedSilenceChunks(bits: Int) throws {
        let rate = 48_000
        let channels = 2
        let blockAlign = channels * bits / 8
        let gapSeconds: Int64 = 8
        let maximumChunkBytes = 1 << 20
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(rate), channels: channels),
            codec: .pcm(bits: bits, float: false, bigEndian: false))
        let url = ContainerFixtures.temporaryURL("silence.avi")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try AVIMuxer(url: url, tracks: [track])
        let tone = Data(repeating: 7, count: blockAlign)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: tone))
        try muxer.write(
            MediaPacket(track: 1, timestamp: gapSeconds * Nanoseconds.perSecond, isKeyframe: true, payload: tone))
        try muxer.finish()
        var demuxer = try AVIDemuxer(url: url)
        let packets = try ContainerFixtures.packets(&demuxer)
        #expect(packets.first?.payload == tone)
        #expect(packets.last?.payload == tone)
        #expect(packets.last?.timestamp == gapSeconds * Nanoseconds.perSecond)
        let silence = packets.dropFirst().dropLast()
        #expect(silence.count > 1)
        #expect(silence.allSatisfy { $0.payload.count <= maximumChunkBytes && $0.payload.count % blockAlign == 0 })
        #expect(silence.allSatisfy { $0.payload.allSatisfy { $0 == 0 } })
        #expect(silence.reduce(0) { $0 + $1.payload.count } == (Int(gapSeconds) * rate - 1) * blockAlign)
    }

    @Test func aviRefusesUnrepresentableAudioLengthBeforeWritingSilence() throws {
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        let url = ContainerFixtures.temporaryURL("audio-length.avi")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try AVIMuxer(url: url, tracks: [track])
        let initialBytes = try Data(contentsOf: url)
        #expect(throws: FormatError.encoderFailure(String(localized: "AVI stream length out of range"))) {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: 90_000 * Nanoseconds.perSecond, isKeyframe: true, payload: Data(count: 4)))
        }
        #expect(try Data(contentsOf: url) == initialBytes)
    }

    @Test func matroskaRefusesOverflowingTimestampSpan() throws {
        let track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp8)
        let url = ContainerFixtures.temporaryURL("span.webm")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: true)
        let extreme: Int64 = 8_000_000_000_000_000_000
        try muxer.write(MediaPacket(track: 1, timestamp: -extreme, isKeyframe: true, payload: Data([1])))
        #expect(throws: FormatError.encoderFailure(String(localized: "Matroska timestamp out of range"))) {
            try muxer.write(MediaPacket(track: 1, timestamp: extreme, isKeyframe: true, payload: Data([2])))
        }
    }

    @Test func matroskaRefusesOverflowingPacketEnd() throws {
        let track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp8)
        let url = ContainerFixtures.temporaryURL("end.webm")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: true)
        #expect(throws: FormatError.encoderFailure(String(localized: "Matroska timestamp out of range"))) {
            try muxer.write(MediaPacket(track: 1, timestamp: .max, duration: 1, isKeyframe: true, payload: Data([1])))
        }
    }

    @Test func matroskaRoundsMaximumTimestampWithoutOverflow() throws {
        let track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp8)
        let url = ContainerFixtures.temporaryURL("maximum-time.webm")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: true)
        try muxer.write(MediaPacket(track: 1, timestamp: .max, isKeyframe: true, payload: Data([1])))
        try muxer.finish()
        let expectedMilliseconds: UInt64 = 9_223_372_036_855
        let clusterTime = Data(EBML.element(MatroskaID.clusterTimestamp, unsigned: expectedMilliseconds))
        #expect(try Data(contentsOf: url).range(of: clusterTime) != nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, Double(Int32.max) / 1000 + 1])
    func webPRejectsInvalidDurationBeforeAddingFrame(duration: Double) throws {
        let encoder = try WebPAnimationEncoder(width: 1, height: 1, quality: 100, loops: true)
        let pixels = PixelBuffer(width: 1, height: 1, rgba: [0, 0, 0, 255])
        #expect(throws: FormatError.encoderFailure(String(localized: "WebP animation duration out of range"))) {
            try encoder.add(pixels, duration: duration)
        }
        #expect(encoder.frameCount == 0)
        try encoder.add(pixels, duration: 0.1)
        #expect(!(try encoder.finish()).isEmpty)
    }

    @Test func webPRejectsCumulativeDurationOverflow() throws {
        let encoder = try WebPAnimationEncoder(width: 1, height: 1, quality: 100, loops: true)
        let duration = 655.35
        let validFrames = 3276
        for frame in 0..<validFrames {
            let shade = UInt8(frame % 2)
            try encoder.add(PixelBuffer(width: 1, height: 1, rgba: [shade, 0, 0, 255]), duration: duration)
        }
        #expect(throws: FormatError.encoderFailure(String(localized: "WebP animation duration out of range"))) {
            try encoder.add(PixelBuffer(width: 1, height: 1, rgba: [0, 0, 0, 255]), duration: duration)
        }
        #expect(encoder.frameCount == validFrames)
        #expect(!(try encoder.finish()).isEmpty)
    }
}
