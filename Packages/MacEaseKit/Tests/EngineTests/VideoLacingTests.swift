import CoreVideo
import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite(.serialized) struct VideoLacingTests {
    @Test(arguments: [OutputContainer.avi, .flv], [Int64?.none, 0])
    func containerCopiesAcceptAbsentOrZeroTrims(container: OutputContainer, trim: Int64?) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let codec: MediaCodec = container == .avi ? .pcm(bits: 16, float: false, bigEndian: false) : .aac
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: codec,
            codecPrivate: container == .flv ? Data([0x11, 0x88]) : nil)
        let output = folder.appending(path: "untrimmed.\(container.fileExtension)")
        var sink = try Sinks.make(
            container, url: output, tracks: [OutputTrack(track: track, format: nil)], transform: .identity)
        var packet = MediaPacket(
            track: 1, timestamp: 0, duration: 20_000_000, isKeyframe: true,
            payload: Data(repeating: 1, count: 1_920))
        packet.discardPadding = trim
        packet.trimDurationAtStart = trim
        try await sink.write(packet)
        try await sink.finish()
        let input = try await MediaInput.open(output)
        var demuxer = try #require(try input.demuxer)
        let first = try demuxer.nextPacket()
        let copied = try #require(first)
        #expect(copied.payload == packet.payload)
        #expect(copied.timestamp == packet.timestamp)
        let following = try demuxer.nextPacket()
        #expect(following == nil)
    }

    @Test(arguments: [OutputContainer.avi, .flv])
    func containerCopiesRefuseUnrepresentedStartTrim(container: OutputContainer) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let codec: MediaCodec = container == .avi ? .pcm(bits: 16, float: false, bigEndian: false) : .aac
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: codec,
            codecPrivate: container == .flv ? Data([0x11, 0x88]) : nil)
        let output = folder.appending(path: "trimmed.\(container.fileExtension)")
        var sink = try Sinks.make(
            container, url: output, tracks: [OutputTrack(track: track, format: nil)], transform: .identity)
        var packet = MediaPacket(
            track: 1, timestamp: 0, duration: 20_000_000, isKeyframe: true,
            payload: Data(repeating: 1, count: 1_920))
        packet.trimDurationAtStart = 5_000_000
        await #expect(throws: EngineError.unsupportedCodec(codec.displayName)) {
            try await sink.write(packet)
        }
        sink.cancel()
    }

    @Test(arguments: [OutputContainer.avi, .flv], [Int64(-5_000_000), 5_000_000])
    func containerCopiesRefuseUnsupportedPadding(container: OutputContainer, padding: Int64) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let codec: MediaCodec = container == .avi ? .pcm(bits: 16, float: false, bigEndian: false) : .aac
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: codec,
            codecPrivate: container == .flv ? Data([0x11, 0x88]) : nil)
        let source = folder.appending(path: "padded.mkv")
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        var packet = MediaPacket(
            track: 1, timestamp: 0, duration: 20_000_000, isKeyframe: true,
            payload: Data(repeating: 1, count: 1_920))
        packet.discardPadding = padding
        try muxer.write(packet)
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let output = folder.appending(path: "copied.\(container.fileExtension)")
        let input = try await MediaInput.open(source)
        await #expect(throws: EngineError.unsupportedCodec(codec.displayName)) {
            try await Transcoder.run(
                input, plan: TranscodePlan(container: container, video: nil, audio: .copy), to: output
            ) { _ in }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [AudioFormat.aac, .m4aAAC])
    func compressedCopiesRefuseUnrepresentableLeadingPadding(format: AudioFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "padded-aac.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .aac,
            codecPrivate: Data([0x11, 0x88]))
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        var packet = MediaPacket(
            track: 1, timestamp: 0, duration: 21_333_333, isKeyframe: true, payload: Data([1]))
        packet.discardPadding = -5_000_000
        try muxer.write(packet)
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.unsupportedCodec("AAC")) {
            try await VideoAudio.extract(format, url: source, context: context)
        }
        try expectDiscardedStaging(context, in: folder)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [Int64(-5_000_000), 5_000_000])
    func opusCopyRefusesPaddingBeforeFinalPacket(padding: Int64) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "padded-opus.mkv")
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let payloads = try encoder.encode([Float](repeating: 0.25, count: 2 * OpusAudioEncoder.frameSamples))
        try #require(payloads.count == 2)
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .opus,
            codecPrivate: encoder.identificationHeader)
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        for (index, payload) in payloads.enumerated() {
            var packet = MediaPacket(
                track: 1, timestamp: Int64(index) * 20_000_000, duration: 20_000_000,
                isKeyframe: true, payload: payload)
            if index == 0 { packet.discardPadding = padding }
            try muxer.write(packet)
        }
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.unsupportedCodec("Opus")) {
            try await VideoAudio.extract(.opus, url: source, context: context)
        }
        try expectDiscardedStaging(context, in: folder)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [UInt8(1), 2, 3], [Int64(-25_000_000), -5_000_000, 5_000_000, 25_000_000])
    func signedPaddingKeepsSameSamplesInCopyAndReencodedExtraction(lacing: UInt8, padding: Int64) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "padded.mkv")
        let untrimmed = try writeLacedPCM(
            to: source, lacing: lacing, laceCount: 2, gapFrames: nil, discardPadding: padding)
        let original = try Data(contentsOf: source)
        let trimFrames = abs(Int(padding / 1_000_000)) * 48
        let expected =
            padding < 0
            ? [Float](repeating: 0, count: trimFrames) + untrimmed.dropFirst(trimFrames)
            : Array(untrimmed.dropLast(trimFrames))
        for kilobits in [Int?.none, 0] {
            let context = ItemContext(
                settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
            defer { context.removeStaging() }
            guard
                case .derived(_, let outputs) = try await VideoAudio.extract(
                    .wav, kilobits: kilobits, url: source, context: context)
            else {
                Issue.record("expected extracted WAV")
                return
            }
            let samples = try AudioSignals.decode(#require(outputs.first).url).samples
            #expect(samples.count == expected.count)
            #expect(samples.elementsEqual(expected))
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [Int64(-25_000_000), -5_000_000, 5_000_000, 25_000_000])
    func unresolvedPaddingUsesWholeDecodedLaceGroup(padding: Int64) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "unresolved-padded.mkv")
        let untrimmed = try writeLacedPCM(
            to: source, lacing: 1, laceCount: 3, gapFrames: nil, codecID: "A_UNKNOWN", discardPadding: padding)
        let input = try await MediaInput.open(source)
        var track = try #require(input.audio)
        track.codec = .pcm(bits: 16, float: false, bigEndian: false)
        let output = folder.appending(path: "decoded.wav")
        try await VideoAudio.encode(
            input, track: track, sampleRate: 48_000,
            target: AudioTarget.defaults(for: .wav, settings: AudioSettings()), to: output
        ) { _ in }
        let trimFrames = abs(Int(padding / 1_000_000)) * 48
        let expected =
            padding < 0
            ? [Float](repeating: 0, count: trimFrames) + untrimmed.dropFirst(trimFrames)
            : Array(untrimmed.dropLast(trimFrames))
        let samples = try AudioSignals.decode(output).samples
        #expect(samples.count == expected.count)
        #expect(samples.elementsEqual(expected))
    }

    @Test(arguments: [Int64(-25_000_000), 25_000_000])
    func vorbisPaddingSpansDecodedLacesAndSurvivesRemux(padding: Int64) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "padded-vorbis.mkv")
        let untrimmed = try writeVorbisLaces(to: source, discardPadding: padding)
        let trimFrames = 1_200
        try #require(untrimmed.count > trimFrames)
        let expected =
            padding < 0
            ? [Float](repeating: 0, count: 480 + trimFrames) + untrimmed.dropFirst(trimFrames)
            : [Float](repeating: 0, count: 480) + untrimmed.dropLast(trimFrames)
        let copied = folder.appending(path: "padded-vorbis.webm")
        let input = try await MediaInput.open(source)
        try await Transcoder.run(
            input, plan: TranscodePlan(container: .webm, video: nil, audio: .copy), to: copied
        ) { _ in }
        for url in [source, copied] {
            let context = ItemContext(
                settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
            defer { context.removeStaging() }
            guard case .derived(_, let outputs) = try await VideoAudio.extract(.wav, url: url, context: context) else {
                Issue.record("expected extracted WAV")
                return
            }
            let samples = try AudioSignals.decode(#require(outputs.first).url).samples
            #expect(samples.count == expected.count)
            let maximumDifference = zip(samples, expected).map { abs($0 - $1) }.max() ?? 0
            #expect(maximumDifference < 1.0 / 32_768)
        }
    }

    @Test(arguments: [UInt8(1), 2, 3], [Int?.none, 0, 480])
    func pcmCopyExtractionKeepsEveryLaceAndOnlyRealBlockGaps(lacing: UInt8, gapFrames: Int?) async throws {
        try await checkLacedAudio(lacing: lacing, gapFrames: gapFrames, output: .copy)
    }

    @Test(arguments: [UInt8(1), 2, 3], [Int?.none, 0, 480])
    func reencodedExtractionKeepsEveryLaceAndOnlyRealBlockGaps(lacing: UInt8, gapFrames: Int?) async throws {
        try await checkLacedAudio(lacing: lacing, gapFrames: gapFrames, output: .reencode)
    }

    @Test(arguments: [UInt8(1), 2, 3], [Int?.none, 0, 480])
    func aviConversionKeepsEveryLaceAndOnlyRealBlockGaps(lacing: UInt8, gapFrames: Int?) async throws {
        try await checkLacedAudio(lacing: lacing, gapFrames: gapFrames, output: .avi)
    }

    @Test(arguments: [UInt8(1), 2, 3], [Int?.none, 0, 480])
    func aviAudioEncodingKeepsEveryLaceAndOnlyRealBlockGaps(lacing: UInt8, gapFrames: Int?) async throws {
        try await checkLacedAudio(lacing: lacing, gapFrames: gapFrames, output: .aviAudio)
    }

    @Test(arguments: [false, true])
    func unresolvedVorbisLacesAllowRemuxAndRemoveAudio(removesAudio: Bool) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "vorbis.mkv")
        _ = try writeLacedPCM(to: source, lacing: 1, laceCount: 3, gapFrames: nil, codecID: "A_VORBIS")
        let original = try Data(contentsOf: source)
        var input = try MatroskaDemuxer(url: source)
        var expected: [MediaPacket] = []
        while let packet = try input.nextPacket() { expected.append(packet) }
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let operation: VideoOperation = removesAudio ? .removeAudio : .convert(.webm)
        guard case .replace(_, let output) = try await VideoEdits.run(operation, url: source, context: context) else {
            Issue.record("expected staged video")
            return
        }
        var demuxer = try MatroskaDemuxer(url: output.url)
        var written: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { written.append(packet) }
        let kept = expected.filter { !removesAudio || $0.track == 1 }
        #expect(written.map(\.payload) == kept.map(\.payload))
        #expect(written.map(\.continuesPrevious) == kept.map(\.continuesPrevious))
        #expect(demuxer.tracks.count == (removesAudio ? 1 : 2))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [Int?.none, 0, 480])
    func unresolvedLacesAdvanceByDecodedPCMSamples(gapFrames: Int?) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "unresolved.mkv")
        let expected = try writeLacedPCM(
            to: source, lacing: 1, laceCount: 3, gapFrames: gapFrames, codecID: "A_UNKNOWN")
        let input = try await MediaInput.open(source)
        var track = try #require(input.audio)
        track.codec = .pcm(bits: 16, float: false, bigEndian: false)
        let output = folder.appending(path: "decoded.wav")
        try await VideoAudio.encode(
            input, track: track, sampleRate: 48_000,
            target: AudioTarget.defaults(for: .wav, settings: AudioSettings()), to: output
        ) { _ in }
        let samples = try AudioSignals.decode(output).samples
        #expect(samples.count == expected.count)
        #expect(samples.elementsEqual(expected))

        let stage = try AudioEncodeStage(
            input: input, track: track, number: 1, codec: track.codec, kilobits: 0, start: 0, end: .max)
        let decoder = try AudioPacketDecoder(track: track)
        var encoded: [Float] = []
        while stage.nextTime != nil {
            for packet in try await stage.pull() { encoded += try decoder.decode(packet) }
        }
        #expect(encoded.count == expected.count)
        #expect(encoded.elementsEqual(expected))

        let clipped = try VideoPCMSource(input: input, track: track, start: 15_000_000, end: 35_000_000)
        var excerpt: [Float] = []
        while let chunk = try await clipped.next() { excerpt += chunk.samples }
        #expect(excerpt.elementsEqual(expected[720..<1_680]))
    }

    @Test func timedVorbisCopyRefusesWithoutOutputAndKeepsOriginal() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "unresolved.mkv")
        _ = try writeVorbisLaces(to: source)
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.unsupportedCodec("Vorbis")) {
            try await VideoAudio.extract(.ogg, url: source, context: context)
        }
        try expectDiscardedStaging(context, in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "unresolved.ogg").path))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func vorbisDecodeExtractionRetainsEveryLacedPacketAfterPriming() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "vorbis.mkv")
        let expected = try writeVorbisLaces(to: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .derived(_, let outputs) = try await VideoAudio.extract(.wav, url: source, context: context) else {
            Issue.record("expected extracted WAV")
            return
        }
        let output = try #require(outputs.first)
        let samples = try AudioSignals.decode(output.url).samples
        try #require(samples.count == 480 + expected.count)
        #expect(samples.prefix(480).allSatisfy { $0 == 0 })
        let maximumDifference = zip(samples.dropFirst(480), expected).map { abs($0 - $1) }.max() ?? 0
        #expect(maximumDifference < 1.0 / 32_768)
    }

    @Test func unknownVideoLacesRemuxWithoutInferredDurationAndRefuseTimedEdits() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .vp9)
        let source = folder.appending(path: "video-laces.mkv")
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        for timestamp in [Int64(0), 80_000_000] {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: timestamp, isKeyframe: true, payload: Data([1]), remainingLaceFrames: 1))
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: timestamp, isKeyframe: true, payload: Data([2, 3]), continuesPrevious: true))
        }
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let input = try await MediaInput.open(source)
        let output = folder.appending(path: "copied.webm")
        try await Transcoder.run(input, plan: TranscodePlan(container: .webm, video: .copy), to: output) { _ in }
        var written = try MatroskaDemuxer(url: output)
        #expect(written.tracks.first?.defaultDuration == nil)
        var packets: [MediaPacket] = []
        while let packet = try written.nextPacket() { packets.append(packet) }
        #expect(packets.map(\.continuesPrevious) == [false, true, false, true])
        #expect(packets.map(\.duration) == [nil, nil, nil, nil])
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.unsupportedCodec("VP9")) {
            try await VideoEdits.run(.frameRate(30), url: source, context: context)
        }
        try expectDiscardedStaging(context, in: folder)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [Int64?.none, 40_000_000])
    func rangeCopiesKeepWholeLacesAndRefuseCutsWithoutOutput(laceDuration: Int64?) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let track = MediaTrack(number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .vorbis)
        let source = folder.appending(path: "bounded-laces.mkv")
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data([1])))
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: 100_000_000, isKeyframe: true, payload: Data([2]),
                remainingLaceFrames: 1, laceDuration: laceDuration))
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: 100_000_000, isKeyframe: true, payload: Data([3, 4]), continuesPrevious: true))
        try muxer.write(MediaPacket(track: 1, timestamp: 140_000_000, isKeyframe: true, payload: Data([5])))
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let input = try await MediaInput.open(source)
        let copies: [(Range<Int64>, [Data])] = [
            (0..<100_000_000, [Data([1])]),
            (140_000_000..<200_000_000, [Data([5])]),
            (100_000_000..<140_000_000, [Data([2]), Data([3, 4])]),
        ]
        for (range, expected) in copies {
            let output = folder.appending(path: "copied-\(range.lowerBound).mkv")
            try await Transcoder.run(
                input, plan: TranscodePlan(container: .mkv, audio: .copy, range: range), to: output
            ) { _ in }
            var demuxer = try MatroskaDemuxer(url: output)
            var packets: [MediaPacket] = []
            while let packet = try demuxer.nextPacket() { packets.append(packet) }
            #expect(packets.map(\.payload) == expected)
            if range.lowerBound == 100_000_000 {
                #expect(packets.map(\.continuesPrevious) == [false, true])
                #expect(packets.map(\.laceDuration) == [laceDuration, nil])
            }
        }
        let refused: [(OutputContainer, Range<Int64>)] = [
            (.mp4, 100_000_000..<140_000_000),
            (.mkv, 100_000_000..<120_000_000),
            (.mkv, 120_000_000..<140_000_000),
        ]
        for (container, range) in refused {
            let context = ItemContext(
                settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
            defer { context.removeStaging() }
            let plan = try await VideoProperties.prepare(
                TranscodePlan(container: container, audio: .copy, range: range), input: input, context: context)
            let output = try context.stagingURL(for: source, name: "refused.\(container.fileExtension)")
            await #expect(throws: EngineError.unsupportedCodec("Vorbis")) {
                try await Transcoder.run(input, plan: plan, to: output) { _ in }
            }
            try expectDiscardedStaging(context, in: folder)
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(try Data(contentsOf: source) == original)
        }
    }

    private func expectDiscardedStaging(_ context: ItemContext, in folder: URL) throws {
        let registry = folder.appending(path: "staging.json")
        let directories = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        #expect(!directories.isEmpty)
        context.removeStaging()
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    private func writeVorbisLaces(to source: URL, discardPadding: Int64? = nil) throws -> [Float] {
        let encoder = try VorbisAudioEncoder(sampleRate: 48_000, channels: 1, bitrate: 64_000)
        let signal = (0..<4_096).map { Float(sin(Double($0) * 0.1)) * 0.25 }
        let encoded = try encoder.encode(signal) + encoder.finish()
        try #require(encoded.count > 2)
        let decoder = try VorbisAudioDecoder(headers: encoder.headers)
        let decoded = try encoded.map { try decoder.decode($0.data) }
        #expect(decoded[0].isEmpty)
        let expected = decoded.flatMap { $0 }
        try #require(!expected.isEmpty)
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .vorbis,
            codecPrivate: encoder.codecPrivate)
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        for (index, packet) in encoded.enumerated() {
            var frame = MediaPacket(
                track: 1, timestamp: 10_000_000, isKeyframe: true, payload: packet.data,
                continuesPrevious: index > 0, remainingLaceFrames: encoded.count - index - 1)
            if index == 0 { frame.discardPadding = discardPadding }
            try muxer.write(frame)
        }
        try muxer.finish()
        return expected
    }

    private enum Output { case copy, reencode, avi, aviAudio }

    private func checkLacedAudio(lacing: UInt8, gapFrames: Int?, output: Output) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        for laceCount in 2...3 {
            let source = folder.appending(path: "laced-\(laceCount).mkv")
            let expected = try writeLacedPCM(
                to: source, lacing: lacing, laceCount: laceCount, gapFrames: gapFrames)
            let original = try Data(contentsOf: source)
            let context = ItemContext(
                settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
            defer { context.removeStaging() }
            let samples: [Float]
            switch output {
            case .copy, .reencode:
                guard
                    case .derived(_, let outputs) = try await VideoAudio.extract(
                        .wav, kilobits: output == .copy ? nil : 0, url: source, context: context)
                else {
                    Issue.record("expected extracted WAV")
                    return
                }
                let extracted = try #require(outputs.first)
                samples = try AudioSignals.decode(extracted.url).samples
            case .avi, .aviAudio:
                let converted: URL
                if output == .avi {
                    guard
                        case .replace(_, let staged) = try await VideoEdits.run(
                            .convert(.avi), url: source, context: context)
                    else {
                        Issue.record("expected staged AVI")
                        return
                    }
                    converted = staged.url
                } else {
                    converted = folder.appending(path: "audio-\(laceCount).avi")
                    let input = try await MediaInput.open(source)
                    try await Transcoder.run(
                        input,
                        plan: TranscodePlan(
                            container: .avi, video: nil,
                            audio: .encode(.pcm(bits: 16, float: false, bigEndian: false), kilobits: 0)),
                        to: converted
                    ) { _ in }
                }
                var demuxer = try AVIDemuxer(url: converted)
                let track = try #require(demuxer.tracks.first { !$0.isVideo })
                let decoder = try AudioPacketDecoder(track: track)
                var decoded: [Float] = []
                while let packet = try demuxer.nextPacket() {
                    if packet.track == track.number { decoded += try decoder.decode(packet) }
                }
                samples = decoded
            }
            #expect(samples.count == expected.count)
            let preservesSamples = samples.elementsEqual(expected)
            #expect(preservesSamples)
            #expect(try Data(contentsOf: source) == original)
        }
    }

    private func writeLacedPCM(
        to url: URL, lacing: UInt8, laceCount: Int, gapFrames: Int?, codecID: String = "A_PCM/INT/LIT",
        discardPadding: Int64? = nil
    ) throws -> [Float] {
        let frameCounts = lacing == 2 ? [960, 960, 960] : [960, 480, 1_440]
        let laces = frameCounts.prefix(laceCount).enumerated().map { index, count in
            (0..<count).map { Int16((index + 1) * 1_000 + $0) }
        }
        let payloads = laces.map { samples in
            samples.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
        }
        var laceHeader: [UInt8] = [UInt8(laceCount - 1)]
        switch lacing {
        case 1:
            for payload in payloads.dropLast() {
                laceHeader += [UInt8](repeating: 255, count: payload.count / 255)
                laceHeader.append(UInt8(payload.count % 255))
            }
        case 3:
            laceHeader += EBML.encodeSize(Int64(payloads[0].count))
            if laceCount == 3 {
                let signedVintBias = (1 << 13) - 1
                let delta = payloads[1].count - payloads[0].count
                laceHeader += EBML.encodeSize(Int64(delta + signedVintBias), width: 2)
            }
        default: break
        }
        let audioTrack = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 2)
                + EBML.element(MatroskaID.trackType, unsigned: 2)
                + EBML.element(MatroskaID.codecID, string: codecID)
                + EBML.element(
                    MatroskaID.audio,
                    EBML.element(MatroskaID.samplingFrequency, float: 48_000)
                        + EBML.element(MatroskaID.channels, unsigned: 1)
                        + EBML.element(MatroskaID.bitDepth, unsigned: 16)))
        let width = 16
        let height = 16
        var created: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let image = try #require(created)
        try #require(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(image, []) }
            let pixels = try #require(CVPixelBufferGetBaseAddress(image))
            pixels.initializeMemory(as: UInt8.self, repeating: 255, count: CVPixelBufferGetBytesPerRow(image) * height)
        }
        let encoding = VideoEncoding(codec: .vp9, width: width, height: height, frameDuration: 40_000_000, bitrate: nil)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        let encoded = try encoder.encode(image, timestamp: 0) + encoder.finish()
        let videoPacket = try #require(encoded.first)
        let videoTrack = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_VP9")
                + EBML.element(MatroskaID.defaultDuration, unsigned: 40_000_000)
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: UInt64(width))
                        + EBML.element(MatroskaID.pixelHeight, unsigned: UInt64(height))))
        var blocks = EBML.element(MatroskaID.simpleBlock, [0x81, 0, 0, 0x80] + videoPacket.payload)
        let lacedBlock = [0x82, 0, 0, 0x80 | lacing << 1] + laceHeader + payloads.flatMap { $0 }
        if let discardPadding {
            blocks += EBML.element(
                MatroskaID.blockGroup,
                EBML.element(MatroskaID.block, lacedBlock)
                    + EBML.element(MatroskaID.discardPadding, signed: discardPadding))
        } else {
            blocks += EBML.element(MatroskaID.simpleBlock, lacedBlock)
        }
        var expected = laces.flatMap { $0 }.map { Float($0) / 32_768 }
        if let gapFrames {
            let nextMilliseconds = (expected.count + gapFrames) / 48
            let following: [UInt8] = [0x82, 0, UInt8(nextMilliseconds), 0x80]
            let nextPayload = (0..<960).flatMap { _ in [UInt8(0x10), UInt8(0x27)] }
            blocks += EBML.element(MatroskaID.simpleBlock, following + nextPayload)
            expected += [Float](repeating: 0, count: gapFrames)
            expected += [Float](repeating: 10_000 / 32_768, count: 960)
        }
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let segment =
            EBML.element(
                MatroskaID.info,
                EBML.element(MatroskaID.timestampScale, unsigned: 1_000_000)
                    + EBML.element(MatroskaID.duration, float: Double(expected.count) / 48))
            + EBML.element(MatroskaID.tracks, videoTrack + audioTrack)
            + EBML.element(MatroskaID.cluster, EBML.element(MatroskaID.clusterTimestamp, unsigned: 0) + blocks)
        try Data(header + EBML.element(MatroskaID.segment, segment)).write(to: url)
        return expected
    }
}
