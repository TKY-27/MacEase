import CoreMedia
import Foundation
import Testing

@testable import Formats

@Suite struct MatroskaTests {
    private static let tagNameID: UInt32 = 0x45A3
    private static let tagStringID: UInt32 = 0x4487

    private func syntheticPackets() -> (tracks: [MediaTrack], packets: [MediaPacket]) {
        var video = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .vp9)
        video.hasAlpha = true
        var audio = MediaTrack(
            number: 2, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus, codecPrivate: Data("OpusHead".utf8))
        audio.codecDelay = 6_500_000
        audio.seekPreRoll = 80_000_000
        var random = FixtureRandom(seed: 9)
        var packets: [MediaPacket] = []
        for frame in 0..<300 {
            let videoTime = Int64(frame) * 40 * Nanoseconds.perMillisecond
            let payload = Data((0..<(50 + Int(random.next() % 400))).map { _ in UInt8(random.next() & 0xFF) })
            let alpha = frame % 3 == 0 ? Data([1, 2, 3, UInt8(frame & 0xFF)]) : nil
            packets.append(
                MediaPacket(
                    track: 1, timestamp: videoTime, isKeyframe: frame % 50 == 0, payload: payload, additional: alpha))
            for half in 0..<2 {
                let audioTime = videoTime + Int64(half) * 20 * Nanoseconds.perMillisecond
                packets.append(
                    MediaPacket(
                        track: 2, timestamp: audioTime, isKeyframe: true,
                        payload: Data([UInt8(frame & 0xFF), UInt8(half)])))
            }
        }
        return ([video, audio], packets)
    }

    @Test func roundTripPreservesPacketsAndTimestamps() throws {
        let (tracks, packets) = syntheticPackets()
        let url = ContainerFixtures.temporaryURL("round.webm")
        var muxer = try MatroskaMuxer(url: url, tracks: tracks, webm: true)
        for packet in packets { try muxer.write(packet) }
        try muxer.finish()

        var demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.docType == "webm")
        #expect(demuxer.tracks.map(\.codec) == [.vp9, .opus])
        #expect(demuxer.tracks[0].hasAlpha)
        #expect(demuxer.tracks[1].codecDelay == 6_500_000)
        var read: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { read.append(packet) }
        #expect(read.count == packets.count)
        for (original, decoded) in zip(packets, read) {
            #expect(decoded.track == original.track)
            #expect(decoded.timestamp == original.timestamp)
            #expect(decoded.isKeyframe == original.isKeyframe)
            #expect(decoded.payload == original.payload)
            #expect(decoded.additional == original.additional)
        }
        let duration = try #require(demuxer.duration)
        #expect(abs(duration - 299 * 40 * Nanoseconds.perMillisecond) <= 40 * Nanoseconds.perMillisecond)
    }

    @Test func detectsTitlesAndTagsBeyondTheFirstCluster() throws {
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let track = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: 64)
                        + EBML.element(MatroskaID.pixelHeight, unsigned: 48)))
        let provenance = EBML.element(MatroskaID.info, EBML.element(MatroskaID.muxingApp, string: "MacEase"))
        let tracks = EBML.element(MatroskaID.tracks, track)
        let title = EBML.element(MatroskaID.info, EBML.element(MatroskaID.title, string: "Holiday"))
        let tags = EBML.element(
            MatroskaID.tags,
            EBML.element(
                MatroskaID.tag,
                EBML.element(
                    MatroskaID.simpleTag,
                    EBML.element(Self.tagNameID, string: "COLLECTION")
                        + EBML.element(
                            MatroskaID.simpleTag,
                            EBML.element(Self.tagNameID, string: "DESCRIPTION")
                                + EBML.element(Self.tagStringID, string: "Holiday"))))
                + EBML.element(
                    MatroskaID.tag,
                    EBML.element(
                        MatroskaID.targets,
                        EBML.element(MatroskaID.tagTrackUID, unsigned: 23))
                        + EBML.element(
                            MatroskaID.simpleTag,
                            EBML.element(Self.tagNameID, string: "PERFORMER")
                                + EBML.element(Self.tagStringID, string: "Artist"))))
        let segment = provenance + tracks + EBML.encodeID(MatroskaID.cluster) + [0xFF] + title + tags
        let url = ContainerFixtures.temporaryURL("metadata.mkv")
        try Data(header + EBML.element(MatroskaID.segment, segment)).write(to: url)
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.hasDescriptiveMetadata)
        #expect(demuxer.hasTrackMetadata)

        let tagsOnlyURL = ContainerFixtures.temporaryURL("tags-only.mkv")
        try Data(header + EBML.element(MatroskaID.segment, provenance + tracks + tags)).write(to: tagsOnlyURL)
        let tagsOnly = try MatroskaDemuxer(url: tagsOnlyURL)
        #expect(tagsOnly.hasDescriptiveMetadata)
        #expect(tagsOnly.hasTrackMetadata)

        let titleOnlyURL = ContainerFixtures.temporaryURL("title-only.mkv")
        try Data(header + EBML.element(MatroskaID.segment, provenance + tracks + title)).write(to: titleOnlyURL)
        let titleOnly = try MatroskaDemuxer(url: titleOnlyURL)
        #expect(titleOnly.hasDescriptiveMetadata)
        #expect(!titleOnly.hasTrackMetadata)
    }

    @Test func ignoresMuxerAndWriterProvenance() throws {
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "webm"))
        let track = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: 64)
                        + EBML.element(MatroskaID.pixelHeight, unsigned: 48)))
        let segment =
            EBML.element(
                MatroskaID.info,
                EBML.element(MatroskaID.muxingApp, string: "muxer")
                    + EBML.element(MatroskaID.writingApp, string: "writer"))
            + EBML.element(MatroskaID.tracks, track)
        let url = ContainerFixtures.temporaryURL("provenance.webm")
        try Data(header + EBML.element(MatroskaID.segment, segment)).write(to: url)
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(!demuxer.hasDescriptiveMetadata)
        #expect(!demuxer.hasTrackMetadata)
    }

    @Test(arguments: [true, false])
    func trackNameAndBCP47LanguageOverrideLegacyInEitherOrder(bcp47First: Bool) throws {
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let languages =
            bcp47First
            ? EBML.element(MatroskaID.languageBCP47, string: "ja-JP")
                + EBML.element(MatroskaID.language, string: "eng")
            : EBML.element(MatroskaID.language, string: "eng")
                + EBML.element(MatroskaID.languageBCP47, string: "ja-JP")
        let track = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + EBML.element(MatroskaID.name, string: "Japanese picture")
                + languages
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: 64)
                        + EBML.element(MatroskaID.pixelHeight, unsigned: 48)))
        let url = ContainerFixtures.temporaryURL("named-language-\(bcp47First).mkv")
        try Data(header + EBML.element(MatroskaID.segment, EBML.element(MatroskaID.tracks, track))).write(to: url)
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.hasTrackMetadata)
        #expect(demuxer.tracks.first?.language == "ja-JP")
        #expect(!demuxer.hasDescriptiveMetadata)
    }

    @Test func legacyTrackLanguageRemainsReadable() throws {
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let track = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + EBML.element(MatroskaID.language, string: "jpn")
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: 64)
                        + EBML.element(MatroskaID.pixelHeight, unsigned: 48)))
        let url = ContainerFixtures.temporaryURL("legacy-language.mkv")
        try Data(header + EBML.element(MatroskaID.segment, EBML.element(MatroskaID.tracks, track))).write(to: url)
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.tracks.first?.language == "jpn")
        #expect(!demuxer.hasTrackMetadata)
    }

    @Test func webmRefusesCodecsOutsideTheProfile() {
        let track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .h264)
        #expect(throws: FormatError.self) {
            try MatroskaMuxer(url: ContainerFixtures.temporaryURL("bad.webm"), tracks: [track], webm: true)
        }
    }

    @Test func unlacesXiphEBMLAndFixedLacing() throws {
        let frames: [[UInt8]] = [[1, 2, 3], [4, 5], [6, 7, 8, 9]]
        let header: [UInt8] = [0x81, 0, 0, 0]
        let xiph = header + [2, 3, 2] + frames.joined()
        #expect(try MatroskaDemuxer.unlace(xiph, from: 4, lacing: 1) == frames)
        // Sizes 3, then -1 biased by 63.
        let ebml = header + [2, 0x83, 0xBE] + frames.joined()
        #expect(try MatroskaDemuxer.unlace(ebml, from: 4, lacing: 3) == frames)
        let fixed = header + [2, 1, 1, 2, 2, 3, 3]
        #expect(try MatroskaDemuxer.unlace(fixed, from: 4, lacing: 2) == [[1, 1], [2, 2], [3, 3]])
    }

    @Test func rejectsTruncatedFiles() throws {
        let (tracks, packets) = syntheticPackets()
        let url = ContainerFixtures.temporaryURL("cut.mkv")
        var muxer = try MatroskaMuxer(url: url, tracks: tracks, webm: false)
        for packet in packets.prefix(20) { try muxer.write(packet) }
        try muxer.finish()
        let bytes = try Data(contentsOf: url)
        let cut = ContainerFixtures.temporaryURL("cut2.mkv")
        try bytes.prefix(bytes.count / 2).write(to: cut)
        #expect(throws: FormatError.self) {
            var demuxer = try MatroskaDemuxer(url: cut)
            while try demuxer.nextPacket() != nil {}
        }
    }

    @Test func readsFFmpegFileAndSkipsSubtitles() throws {
        var demuxer = try MatroskaDemuxer(url: ContainerFixtures.resource("ffmpeg-mpeg4-ac3-srt.mkv"))
        #expect(demuxer.tracks.map(\.codec) == [.mpeg4Part2, .ac3])
        #expect(demuxer.tracks[0].kind == .video(width: 96, height: 64))
        let packets = try ContainerFixtures.packets(&demuxer)
        #expect(Set(packets.map(\.track)) == [1, 2])
        let video = packets.filter { $0.track == 1 }
        #expect(video.count == 60)
        #expect(video.prefix(4).map(\.timestamp) == [0, 33, 67, 100].map { $0 * Nanoseconds.perMillisecond })
        #expect(video.map(\.isKeyframe) == (0..<60).map { $0 % 10 == 0 })
        #expect(packets.filter { $0.track == 2 }.count == 63)
    }

    @Test func roundsTimestampsAndKeepsDiscardPadding() throws {
        var video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        video.hasAlpha = true
        let audio = MediaTrack(number: 2, kind: .audio(sampleRate: 48_000, channels: 1), codec: .opus)
        let frame: Int64 = 33_366_666
        var packets = (0..<10).map { index in
            MediaPacket(
                track: 1, timestamp: Int64(index) * frame, isKeyframe: index == 0, payload: Data([UInt8(index)]),
                additional: Data([9]))
        }
        var last = MediaPacket(
            track: 2, timestamp: 9 * frame, isKeyframe: true, payload: Data([1]))
        last.discardPadding = 12_500_000
        packets.append(last)
        let url = ContainerFixtures.temporaryURL("round.webm")
        defer { try? FileManager.default.removeItem(at: url) }
        var muxer = try MatroskaMuxer(url: url, tracks: [video, audio], webm: true)
        for packet in packets { try muxer.write(packet) }
        try muxer.finish()

        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data([0x55, 0xEE, 0x81, 0x01])) != nil)
        var demuxer = try MatroskaDemuxer(url: url)
        let read = try ContainerFixtures.packets(&demuxer)
        let expected = packets.map { ($0.timestamp + Nanoseconds.perMillisecond / 2) / Nanoseconds.perMillisecond }
        #expect(read.map { $0.timestamp / Nanoseconds.perMillisecond } == expected)
        #expect(read.last?.discardPadding == 12_500_000)
        #expect(read.dropLast().allSatisfy { $0.discardPadding == nil && $0.additional == Data([9]) })
    }

    @Test func refusesTrackNumberZero() {
        let track = MediaTrack(number: 0, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus)
        #expect(throws: FormatError.self) {
            try MatroskaMuxer(url: ContainerFixtures.temporaryURL("zero.webm"), tracks: [track], webm: true)
        }
    }

    @Test(arguments: [(0, 16), (16, 0), (16_385, 16), (16, 16_385), (Int.max, Int.max)])
    func rejectsInvalidVideoDimensions(width: Int, height: Int) throws {
        let url = ContainerFixtures.temporaryURL("dimensions.mkv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        let track = MediaTrack(number: 1, kind: .video(width: width, height: height), codec: .vp9)
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        try muxer.finish()
        #expect(throws: FormatError.corrupt("video dimensions out of range")) {
            try MatroskaDemuxer(url: url)
        }
    }

    @Test func acceptsMaximumVideoDimension() throws {
        let url = ContainerFixtures.temporaryURL("maximum-dimension.mkv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        let track = MediaTrack(number: 1, kind: .video(width: 16_384, height: 1), codec: .vp9)
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        try muxer.finish()
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.tracks[0].kind == track.kind)
    }

    @Test func ebmlLacingWithOneFrameHasNoSizes() throws {
        let block: [UInt8] = [0x81, 0, 0, 0x06, 0, 5, 6, 7]
        #expect(try MatroskaDemuxer.unlace(block, from: 4, lacing: 3) == [[5, 6, 7]])
    }

    @Test func readsAndRemuxesIndependentDisplayElements() throws {
        let geometryElements =
            EBML.element(0x54B0, unsigned: 1220)
            + EBML.element(0x54BA, unsigned: 470)
            + EBML.element(0x54B2, unsigned: 0)
            + EBML.element(0x54BB, unsigned: 8)
            + EBML.element(0x54AA, unsigned: 2)
            + EBML.element(0x54CC, unsigned: 10)
            + EBML.element(0x54DD, unsigned: 20)
        let video = EBML.element(
            MatroskaID.video,
            EBML.element(MatroskaID.pixelWidth, unsigned: 640)
                + EBML.element(MatroskaID.pixelHeight, unsigned: 480)
                + geometryElements)
        let entry = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + video)
        let input = ContainerFixtures.temporaryURL("display-input.mkv")
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        try Data(header + EBML.element(MatroskaID.segment, EBML.element(MatroskaID.tracks, entry))).write(to: input)
        let track = try #require(MatroskaDemuxer(url: input).tracks.first)
        #expect(
            track.displayGeometry
                == VideoDisplayGeometry(
                    displayWidth: 1220, displayHeight: 470, cropTop: 8, cropBottom: 2, cropLeft: 10, cropRight: 20))
        let output = ContainerFixtures.temporaryURL("display-output.mkv")
        var muxer = try MatroskaMuxer(url: output, tracks: [track], webm: false)
        try muxer.finish()
        let remuxed = try Data(contentsOf: output)
        #expect(remuxed.range(of: Data(geometryElements)) != nil)
        #expect(try MatroskaDemuxer(url: output).tracks.first?.displayGeometry == track.displayGeometry)
    }

    @Test func rejectsEmptyCropAndMissingRatioDimensions() throws {
        #expect(throws: FormatError.self) {
            try VideoDisplayGeometry(cropLeft: 320, cropRight: 320).validate(width: 640, height: 480)
        }
        #expect(throws: FormatError.self) {
            try VideoDisplayGeometry(displayWidth: 16, displayUnit: 3).validate(width: 640, height: 480)
        }
        #expect(throws: FormatError.self) {
            try VideoDisplayGeometry(displayHeight: 0).validate(width: 640, height: 480)
        }
        #expect(
            VideoDisplayGeometry(displayWidth: Int.max, displayHeight: 1)
                .pixelAspectRatio(width: 640, height: 480) == nil)
        let defaults = VideoDisplayGeometry(displayHeight: 600, cropLeft: 10, cropRight: 20)
        #expect(defaults.presentationSize(width: 640, height: 480) == CGSize(width: 610, height: 600))
        #expect(defaults.pixelAspectRatio(width: 640, height: 480)?.horizontal == 4)
        #expect(defaults.pixelAspectRatio(width: 640, height: 480)?.vertical == 5)
    }

    @Test func usesFinalTimestampScaleWhenTracksPrecedeInfo() throws {
        let entry = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: 64)
                        + EBML.element(MatroskaID.pixelHeight, unsigned: 48)))
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let segment = EBML.element(
            MatroskaID.segment,
            EBML.element(MatroskaID.tracks, entry)
                + EBML.element(MatroskaID.info, EBML.element(MatroskaID.timestampScale, unsigned: 500_000)))
        let url = ContainerFixtures.temporaryURL("late-timestamp-scale.mkv")
        try Data(header + segment).write(to: url)
        #expect(try MatroskaDemuxer(url: url).tracks.first?.timestampQuantum == 500_000)
    }

    @Test func rejectsInvalidCropInExternalMatroska() throws {
        let video = EBML.element(
            MatroskaID.video,
            EBML.element(MatroskaID.pixelWidth, unsigned: 64)
                + EBML.element(MatroskaID.pixelHeight, unsigned: 48)
                + EBML.element(0x54CC, unsigned: 64))
        let entry = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + video)
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let url = ContainerFixtures.temporaryURL("invalid-display-crop.mkv")
        try Data(header + EBML.element(MatroskaID.segment, EBML.element(MatroskaID.tracks, entry))).write(to: url)
        #expect(throws: FormatError.corrupt(String(localized: "Video dimensions out of range"))) {
            try MatroskaDemuxer(url: url)
        }
    }

    @Test func nativeDescriptionCarriesCropAndPixelAspect() throws {
        var track = MediaTrack(number: 1, kind: .video(width: 640, height: 480), codec: .vp9)
        track.displayGeometry = VideoDisplayGeometry(
            displayWidth: 1218, displayHeight: 469, cropTop: 9, cropBottom: 2, cropLeft: 11, cropRight: 20)
        let description = try VideoFormat.description(for: track)
        let aperture = CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: false)
        #expect(aperture == CGRect(x: 11, y: 2, width: 609, height: 469))
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
            description, usePixelAspectRatio: true, useCleanAperture: true)
        #expect(abs(presentation.width - 1218) < 0.01)
        #expect(abs(presentation.height - 469) < 0.01)
    }

    @Test func unknownUnitSurvivesMatroskaButHasNoPresentation() throws {
        var track = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .vp9)
        track.displayGeometry = VideoDisplayGeometry(displayWidth: 100, displayHeight: 50, displayUnit: 4)
        let geometry = try #require(track.displayGeometry)
        try geometry.validate(width: 64, height: 48)
        #expect(geometry.presentationSize(width: 64, height: 48) == nil)
        let output = ContainerFixtures.temporaryURL("unknown-unit.mkv")
        var muxer = try MatroskaMuxer(url: output, tracks: [track], webm: false)
        try muxer.finish()
        #expect(try MatroskaDemuxer(url: output).tracks.first?.displayGeometry == geometry)
    }
}
