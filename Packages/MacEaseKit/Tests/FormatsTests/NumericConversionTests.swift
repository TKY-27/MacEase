import Foundation
import Testing

@testable import Formats

@Suite struct NumericConversionTests {
    @Test func videoDescriptionRejectsUnrepresentableDimensions() {
        let track = MediaTrack(number: 1, kind: .video(width: Int.max, height: 16), codec: .mjpeg)
        #expect(throws: FormatError.corrupt(String(localized: "Video dimensions out of range"))) {
            try VideoFormat.description(for: track)
        }
    }

    @Test func videoEncoderRejectsUnrepresentableDimensions() {
        let settings = VideoEncoding(codec: .vp9, width: Int.max, height: 16, frameDuration: 40_000_000, bitrate: nil)
        #expect(throws: FormatError.corrupt(String(localized: "Video encoding settings out of range"))) {
            try VideoEncoders.make(settings, track: 1)
        }
    }

    @Test func webPAnimationRejectsUnrepresentableDimensions() {
        #expect(throws: FormatError.corrupt(String(localized: "WebP dimensions out of range"))) {
            try WebPAnimationEncoder(width: Int.max, height: 16, quality: 80, loops: true)
        }
    }

    @Test func matroskaRejectsNegativeDimensionsBeforeUnsignedEncoding() {
        let track = MediaTrack(number: 1, kind: .video(width: -1, height: 16), codec: .vp9)
        #expect(throws: FormatError.corrupt(String(localized: "Matroska video dimensions out of range"))) {
            try MatroskaMuxer(
                url: ContainerFixtures.temporaryURL("negative-dimensions.mkv"), tracks: [track], webm: false)
        }
    }

    @Test func aviRejectsUnrepresentableVideoHeader() {
        var track = MediaTrack(number: 1, kind: .video(width: 65_536, height: 16), codec: .mjpeg)
        track.defaultDuration = 40 * Nanoseconds.perMillisecond
        #expect(throws: FormatError.corrupt(String(localized: "AVI video metadata out of range"))) {
            try AVIMuxer(url: ContainerFixtures.temporaryURL("invalid-dimensions.avi"), tracks: [track])
        }
    }

    @Test func aviRejectsNonfiniteAudioRate() {
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: .infinity, channels: 2),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        #expect(throws: FormatError.corrupt(String(localized: "Audio sample rate out of range"))) {
            try AVIMuxer(url: ContainerFixtures.temporaryURL("invalid-rate.avi"), tracks: [track])
        }
    }

    @Test func aviRejectsUnrepresentableFrameTimestamp() throws {
        var track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        track.defaultDuration = 40 * Nanoseconds.perMillisecond
        let url = ContainerFixtures.temporaryURL("invalid-time.avi")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try AVIMuxer(url: url, tracks: [track])
        let before = try Data(contentsOf: url)
        #expect(throws: FormatError.corrupt(String(localized: "AVI timestamp out of range"))) {
            try muxer.write(MediaPacket(track: 1, timestamp: .max, isKeyframe: true, payload: Data([1])))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func flvRejectsUnrepresentableDecodeTimestamp() throws {
        var track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .h264)
        track.codecPrivate = Data([1, 2, 3, 4])
        let url = ContainerFixtures.temporaryURL("invalid-time.flv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try FLVMuxer(url: url, tracks: [track])
        let before = try Data(contentsOf: url)
        #expect(throws: FormatError.encoderFailure("FLV timestamps must be between 0 and 49 days")) {
            try muxer.write(
                MediaPacket(track: 1, timestamp: 0, decodeTimestamp: .max, isKeyframe: true, payload: Data([1])))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test(arguments: [0, 9, 4_294_967_296])
    func matroskaMuxerRejectsInvalidChannelsBeforeCreatingOutput(channels: Int) {
        let url = ContainerFixtures.temporaryURL("invalid-channels.mkv")
        let track = MediaTrack(number: 1, kind: .audio(sampleRate: 48_000, channels: channels), codec: .aac)
        #expect(throws: FormatError.corrupt("Audio channel count out of range")) {
            try MatroskaMuxer(url: url, tracks: [track], webm: false)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [-8_388_609, 8_388_608])
    func flvRejectsUnrepresentableCompositionTime(offset: Int64) throws {
        let track = MediaTrack(
            number: 1, kind: .video(width: 16, height: 16), codec: .h264,
            codecPrivate: Data([1, 2, 3, 4]))
        let url = ContainerFixtures.temporaryURL("invalid-offset.flv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try FLVMuxer(url: url, tracks: [track])
        let before = try Data(contentsOf: url)
        #expect(throws: FormatError.corrupt("FLV composition time out of range")) {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: max(offset, 0) * Nanoseconds.perMillisecond,
                    decodeTimestamp: max(-offset, 0) * Nanoseconds.perMillisecond,
                    isKeyframe: true, payload: Data([1])))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test(arguments: [-8_388_608, 8_388_607])
    func flvPreservesCompositionTimeLimits(offset: Int64) throws {
        let source = try FLVDemuxer(url: ContainerFixtures.resource("ffmpeg-h264-aac.flv"))
        let track = try #require(source.tracks.first { $0.isVideo })
        let url = ContainerFixtures.temporaryURL("offset-limit.flv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var muxer = try FLVMuxer(url: url, tracks: [track])
        let packet = MediaPacket(
            track: track.number, timestamp: max(offset, 0) * Nanoseconds.perMillisecond,
            decodeTimestamp: max(-offset, 0) * Nanoseconds.perMillisecond, isKeyframe: true, payload: Data([1]))
        try muxer.write(packet)
        try muxer.finish()
        var demuxer = try FLVDemuxer(url: url)
        let read = try #require(try demuxer.nextPacket())
        #expect(read.timestamp == packet.timestamp)
        #expect(read.decodeTimestamp == packet.decodeTimestamp)
    }

    @Test(arguments: [0, Int.max])
    func vpxRejectsUnrepresentableFrameRate(framesPerSecond: Int) {
        let settings = VPXEncoder.Settings(
            codec: .vp9, width: 16, height: 16,
            framesPerSecond: framesPerSecond, kilobitsPerSecond: nil)
        #expect(throws: FormatError.corrupt("VPX settings out of range")) {
            try VPXEncoder(settings: settings)
        }
    }

    @Test func icoRejectsUnrepresentableEntryCount() {
        let images = [(size: Int, png: Data)](repeating: (1, Data()), count: 65_536)
        #expect(throws: FormatError.encoderFailure("ICO entries must be 1 to 256 px")) {
            try ICOFile.write(images)
        }
    }

    @Test func aviRejectsUnrepresentableStreamCount() {
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        #expect(throws: FormatError.corrupt("AVI stream count out of range")) {
            try AVIMuxer(
                url: ContainerFixtures.temporaryURL("stream-count.avi"),
                tracks: [MediaTrack](repeating: track, count: 101))
        }
    }

    @Test func gifRejectsNonfiniteDuration() {
        let pixels = PixelBuffer(width: 1, height: 1, rgba: [0, 0, 0, 255])
        let frames = [GIFFrame(pixels: pixels, duration: 0.1), GIFFrame(pixels: pixels, duration: .nan)]
        #expect(throws: FormatError.corrupt(String(localized: "GIF frame duration out of range"))) {
            try GIFEncoder.encode(frames, options: GIFOptions())
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func avifRejectsNonFiniteQuality(quality: Double) {
        let pixels = PixelBuffer(width: 1, height: 1, rgba: [0, 0, 0, 255])
        #expect(throws: FormatError.encoderFailure("invalid AVIF quality")) {
            try AVIFEncoder.encode(pixels, quality: quality)
        }
    }

    @Test func pngRejectsUnrepresentableRasterBeforeFiltering() {
        let raster = PNGRaster(width: Int.max, height: 1, colorType: .rgba, bitDepth: 8, samples: [])
        #expect(throws: FormatError.corrupt(String(localized: "PNG raster out of range"))) {
            try PNGFile.encode(raster, strategy: .none, level: PNGFile.trialLevel)
        }
    }

    @Test func vorbisCommentsRejectOversizedDeclaredField() {
        let declaredVendorLength = Data([1, 0, 0, 1])
        #expect(throws: FormatError.corrupt(String(localized: "Audio metadata too large"))) {
            try VorbisComment.decode(declaredVendorLength)
        }
    }
}

@Suite struct AudioArtworkBoundaryTests {
    @Test func vorbisKeepsArtworkAcrossBase64Expansion() throws {
        let picture = Artwork(data: Data(repeating: 0x42, count: 12 << 20), mimeType: "image/jpeg")
        let tags = AudioTags(title: "Cover", artwork: picture)
        #expect(try VorbisComment.decode(VorbisComment.encode(tags)) == tags)
    }
}
