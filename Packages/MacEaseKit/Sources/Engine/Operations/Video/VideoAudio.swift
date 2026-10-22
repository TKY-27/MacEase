import AVFoundation
import AudioToolbox
import CoreMedia
import Formats
import Foundation

private let silenceChunkFrames = 4_096
private let maximumSynthesizedSilence = 600 * Nanoseconds.perSecond

final class VideoPCMSource {
    private enum Source {
        case asset(AssetTrackReader)
        case container(any MediaDemuxer, track: Int)
    }

    private var source: Source
    private let decoder: AudioPacketDecoder?
    private let start: Int64
    private let end: Int64
    private let codecDelay: Int64
    let sampleRate: Double
    let channels: Int

    init(input: MediaInput, track: MediaTrack, start: Int64, end: Int64) throws {
        guard case .audio(let sampleRate, let channels) = track.kind else {
            throw EngineError.decodeFailed("not an audio track")
        }
        try AudioMetadata.validate(sampleRate: sampleRate, channels: channels)
        self.start = start
        self.end = end
        codecDelay = track.codec == .opus ? track.codecDelay : 0
        switch input.backend {
        case .asset(let asset, _, let audio):
            guard let audio else { throw EngineError.decodeFailed("missing audio track") }
            let range = CMTimeRange(
                start: CMTime(value: start, timescale: SampleBuffers.nanosecondScale),
                end: Transcoder.readerTime(end))
            source = .asset(
                try AssetTrackReader(asset: asset, track: audio, number: track.number, mode: .pcm, range: range))
            decoder = nil
            self.sampleRate = sampleRate
            self.channels = channels
        default:
            guard let demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
            source = .container(demuxer, track: track.number)
            let decoder = try AudioPacketDecoder(track: track)
            self.decoder = decoder
            self.sampleRate = decoder.sampleRate
            self.channels = decoder.channels
        }
    }

    func next() async throws -> (samples: [Float], timestamp: Int64)? {
        switch source {
        case .asset(let reader):
            while let sample = try await reader.nextSample() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw EngineError.decodeFailed("PCM sample has no data")
                }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes.isMultiple(of: MemoryLayout<Float>.size) else {
                    throw EngineError.decodeFailed("invalid PCM sample length")
                }
                var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
                let status = samples.withUnsafeMutableBytes { bytes in
                    guard let destination = bytes.baseAddress else {
                        return OSStatus(kCMBlockBufferBadLengthParameterErr)
                    }
                    return CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: bytes.count, destination: destination)
                }
                guard status == noErr else { throw EngineError.decodeFailed("PCM block copy (\(status))") }
                guard samples.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
                if !samples.isEmpty {
                    return (samples, SampleBuffers.nanoseconds(sample.presentationTimeStamp))
                }
            }
            return nil
        case .container(var demuxer, let track):
            defer { source = .container(demuxer, track: track) }
            while let packet = try demuxer.nextPacket() {
                try Task.checkCancellation()
                guard packet.track == track else { continue }
                let (adjustedTimestamp, timestampOverflow) = packet.timestamp.subtractingReportingOverflow(codecDelay)
                guard !timestampOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
                let timestamp = max(0, adjustedTimestamp)
                if timestamp >= end { return nil }
                guard let decoder else { throw EngineError.decodeFailed("missing audio decoder") }
                let samples = try decoder.decode(packet)
                let availableFrames = samples.count / channels
                let discarded = Int(
                    min(
                        Double(availableFrames),
                        max(
                            0,
                            ((Double(start) - Double(timestamp)) * sampleRate / Double(Nanoseconds.perSecond)).rounded()
                        )))
                let kept = Int(
                    min(
                        Double(availableFrames),
                        max(
                            0,
                            ((Double(end) - Double(timestamp)) * sampleRate / Double(Nanoseconds.perSecond)).rounded()))
                )
                if kept > discarded {
                    return (Array(samples[discarded * channels..<kept * channels]), max(timestamp, start))
                }
            }
            return nil
        }
    }
}

final class AudioEncodeStage: StreamStage {
    private let source: VideoPCMSource
    private let encoder: AudioPacketEncoder?
    private let converter: PCMConverter?
    private let channels: Int
    private let sampleRate: Int
    private let start: Int64
    private let number: Int
    private let maximumSilenceFrames: Int64
    private var position: Int64
    private var clockOrigin: Int64?
    private var sourceCursor: Int64?
    private var pendingChunk: (samples: [Float], timestamp: Int64)?
    private var inputFrames: Int64 = 0
    private var encodedFrames: Int64 = 0
    private var synthesizedSilenceFrames: Int64 = 0
    private var sourceEnded = false
    private(set) var output: OutputTrack?

    init(input: MediaInput, track: MediaTrack, number: Int, codec: MediaCodec, kilobits: Int, start: Int64, end: Int64)
        throws
    {
        source = try VideoPCMSource(input: input, track: track, start: start, end: end)
        self.start = start
        self.number = number
        position = start
        let format: AudioFormat
        switch codec {
        case .aac: format = .m4aAAC
        case .opus: format = .opus
        case .vorbis: format = .ogg
        case .pcm(bits: 16, float: false, bigEndian: false): format = .wav
        default: throw EngineError.unsupportedCodec(codec.displayName)
        }
        sampleRate = Int(format.outputSampleRate(source.sampleRate))
        maximumSilenceFrames = Int64(
            (Double(maximumSynthesizedSilence) * source.sampleRate / Double(Nanoseconds.perSecond)).rounded(.down))
        channels = format.outputChannels(source.channels)
        converter =
            Double(sampleRate) == source.sampleRate && channels == source.channels
            ? nil
            : try PCMConverter(
                sampleRate: source.sampleRate, channels: source.channels, toSampleRate: Double(sampleRate),
                channels: channels)
        encoder =
            codec.isPCM
            ? nil
            : try AudioPacketEncoder(
                codec: codec, sampleRate: sampleRate, channels: channels, kilobits: kilobits)
        var described = MediaTrack(
            number: number, kind: .audio(sampleRate: Double(sampleRate), channels: channels), codec: codec,
            codecPrivate: encoder?.codecPrivate)
        if codec == .opus, let encoder {
            described.codecDelay = Int64(encoder.delay) * Nanoseconds.perSecond / Int64(sampleRate)
            described.seekPreRoll = 80 * Nanoseconds.perMillisecond
        }
        output = OutputTrack(track: described, format: nil)
    }

    var nextTime: Int64? { sourceEnded ? nil : position }

    func pull() async throws -> [MediaPacket] {
        guard !sourceEnded else { return [] }
        while true {
            try Task.checkCancellation()
            let chunk: (samples: [Float], timestamp: Int64)
            if let pendingChunk {
                chunk = pendingChunk
            } else if let next = try await source.next() {
                chunk = next
            } else {
                break
            }
            pendingChunk = nil
            if clockOrigin == nil {
                clockOrigin = max(start, chunk.timestamp)
                position = clockOrigin ?? start
                sourceCursor = chunk.timestamp
            }
            if let sourceCursor, chunk.timestamp > sourceCursor {
                let (gap, gapOverflow) = chunk.timestamp.subtractingReportingOverflow(sourceCursor)
                guard !gapOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
                let missingEstimate =
                    (Double(gap) * source.sampleRate / Double(Nanoseconds.perSecond)).rounded()
                guard missingEstimate < Double(Int.max) else {
                    throw EngineError.decodeFailed("media timestamp out of range")
                }
                let missing = Int(missingEstimate)
                if missing > 1 {
                    let (projected, budgetOverflow) = synthesizedSilenceFrames.addingReportingOverflow(Int64(missing))
                    guard !budgetOverflow, projected <= maximumSilenceFrames else {
                        throw EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")
                    }
                    let frames = min(missing, silenceChunkFrames)
                    pendingChunk = chunk
                    let elapsed = try roundedElapsed(frames)
                    let (following, overflow) = sourceCursor.addingReportingOverflow(elapsed)
                    guard !overflow else { throw EngineError.decodeFailed("media timestamp out of range") }
                    self.sourceCursor = following
                    let silence = [Float](repeating: 0, count: frames * source.channels)
                    let converted = try converter?.convert(silence) ?? silence
                    let packets = try encoded(converted)
                    let (total, totalOverflow) = synthesizedSilenceFrames.addingReportingOverflow(Int64(frames))
                    guard !totalOverflow else { throw EngineError.decodeFailed("audio frame count out of range") }
                    synthesizedSilenceFrames = total
                    if !packets.isEmpty { return packets }
                    continue
                }
            }
            let elapsed = try roundedElapsed(chunk.samples.count / source.channels)
            let (following, overflow) = chunk.timestamp.addingReportingOverflow(elapsed)
            guard !overflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            sourceCursor = following
            let converted = try converter?.convert(chunk.samples) ?? chunk.samples
            let packets = try encoded(converted)
            if !packets.isEmpty { return packets }
        }
        let tail = try converter?.finish() ?? []
        var packets = try encoded(tail)
        if let encoder { packets += try timed(try encoder.finish()) }
        if output?.track.codec == .opus, let encoder, !packets.isEmpty {
            let (excess, excessOverflow) = encodedFrames.subtractingReportingOverflow(inputFrames)
            let (unpadded, delayOverflow) = excess.subtractingReportingOverflow(Int64(encoder.delay))
            guard !excessOverflow, !delayOverflow else {
                throw EngineError.encodeFailed("audio frame count out of range")
            }
            packets[packets.count - 1].discardPadding = try Nanoseconds.scale(
                max(0, unpadded), by: Nanoseconds.perSecond, over: Int64(sampleRate))
        }
        sourceEnded = true
        return packets
    }

    private func encoded(_ samples: [Float]) throws -> [MediaPacket] {
        guard !samples.isEmpty else { return [] }
        guard samples.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
        let (following, overflow) = inputFrames.addingReportingOverflow(Int64(samples.count / channels))
        guard !overflow else { throw EngineError.encodeFailed("audio frame count out of range") }
        inputFrames = following
        if let encoder { return try timed(try encoder.encode(samples)) }
        var bytes = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var word = Int16(
                clamping: Int((Double(min(max(sample, -1), 1)) * Double(Int16.max)).rounded())
            ).littleEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        return try timed([EncodedAudioPacket(data: bytes, frames: samples.count / channels)])
    }

    private func roundedElapsed(_ frames: Int) throws -> Int64 {
        let estimate = (Double(frames) * Double(Nanoseconds.perSecond) / source.sampleRate).rounded()
        guard estimate.isFinite, abs(estimate) < Double(Int64.max) else {
            throw EngineError.decodeFailed("media timestamp out of range")
        }
        return Int64(estimate)
    }

    private func timed(_ encoded: [EncodedAudioPacket]) throws -> [MediaPacket] {
        try encoded.map { packet in
            let origin = clockOrigin ?? start
            let offset = try Nanoseconds.scale(encodedFrames, by: Nanoseconds.perSecond, over: Int64(sampleRate))
            let (timestamp, timestampOverflow) = origin.addingReportingOverflow(offset)
            let (followingFrames, framesOverflow) = encodedFrames.addingReportingOverflow(Int64(packet.frames))
            guard !timestampOverflow, !framesOverflow else {
                throw EngineError.encodeFailed("audio timestamp out of range")
            }
            let followingOffset = try Nanoseconds.scale(
                followingFrames, by: Nanoseconds.perSecond, over: Int64(sampleRate))
            let (following, followingOverflow) = origin.addingReportingOverflow(followingOffset)
            let (duration, durationOverflow) = following.subtractingReportingOverflow(timestamp)
            guard !followingOverflow, !durationOverflow else {
                throw EngineError.encodeFailed("audio timestamp out of range")
            }
            encodedFrames = followingFrames
            position = following
            return MediaPacket(
                track: number, timestamp: timestamp, duration: duration, isKeyframe: true, payload: packet.data)
        }
    }
}

enum VideoAudio {
    private static let aacLowComplexity = 2
    private static let adtsHeaderLength = 7
    private static let adtsMaximumFrameLength = (1 << 13) - 1
    private static let flacStreamInfoLength = 34
    private static let flacMarkerLength = 4
    private static let flacBlockHeaderLength = 4
    private static let opusSampleRate = 48_000
    /// Rounding jitter, not a real gap.
    private static let gapToleranceFrames: Int64 = 2

    static func extract(
        _ format: AudioFormat, kilobits: Int? = nil, url: URL, context: ItemContext
    ) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        guard let track = input.audio, case .audio(let sampleRate, _) = track.kind else {
            throw EngineError.invalidInput(.malformed("no audio track"))
        }
        let metadata = try await VideoMetadata.load(from: input)
        let losses = metadata.losses(for: nil, includingVideo: false, includingAudio: true)
        if !losses.isEmpty { context.warn(.videoMetadataDropped(losses)) }
        let copiesPackets = kilobits == nil && canCopy(track, to: format)
        if !copiesPackets { _ = try await encodingPrecision(input, track: track, format: format) }
        let name = url.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        let output = try context.stagingURL(for: url, name: name)
        if copiesPackets {
            try await copy(input, track: track, format: format, to: output, progress: context.progress)
        } else {
            var target = AudioTarget.defaults(for: format, settings: context.settings.audio)
            if let kilobits {
                target.kilobits = kilobits
                target.variableQuality = nil
            }
            try await encode(input, track: track, sampleRate: sampleRate, target: target, to: output) {
                context.progress($0)
            }
        }
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .audio)])
    }

    static func encode(
        _ input: MediaInput, track: MediaTrack, sampleRate: Double, target: AudioTarget, to output: URL,
        progress: (Double) -> Void
    ) async throws {
        let precision = try await encodingPrecision(input, track: track, format: target.format)
        let source = try VideoPCMSource(input: input, track: track, start: 0, end: .max)
        let encoder = try AudioFileEncoder(
            url: output, target: target, sampleRate: source.sampleRate, channels: source.channels,
            bitDepth: precision.bits, isFloat: precision.float)
        var frames: Int64 = 0
        var synthesizedSilenceFrames: Int64 = 0
        let expectedFrames = max(sampleRate * Double(input.duration) / Double(Nanoseconds.perSecond), 1)
        let maximumSilenceFrames = Int64(
            (Double(maximumSynthesizedSilence) * source.sampleRate / Double(Nanoseconds.perSecond)).rounded(.down))
        while let chunk = try await source.next() {
            try Task.checkCancellation()
            let due = try Nanoseconds.scale(chunk.timestamp, by: Int64(source.sampleRate), over: Nanoseconds.perSecond)
            let (gap, gapOverflow) = due.subtractingReportingOverflow(frames)
            guard !gapOverflow else { throw EngineError.decodeFailed("audio frame count out of range") }
            if gap > gapToleranceFrames {
                let (projected, budgetOverflow) = synthesizedSilenceFrames.addingReportingOverflow(gap)
                guard !budgetOverflow, projected <= maximumSilenceFrames else {
                    throw EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")
                }
                while frames < due {
                    try Task.checkCancellation()
                    let count = Int(min(due - frames, Int64(silenceChunkFrames)))
                    try await encoder.write([Float](repeating: 0, count: count * source.channels))
                    let (following, overflow) = frames.addingReportingOverflow(Int64(count))
                    guard !overflow else { throw EngineError.encodeFailed("audio frame count out of range") }
                    frames = following
                    let (total, totalOverflow) = synthesizedSilenceFrames.addingReportingOverflow(Int64(count))
                    guard !totalOverflow else { throw EngineError.decodeFailed("audio frame count out of range") }
                    synthesizedSilenceFrames = total
                }
            }
            try await encoder.write(chunk.samples)
            let (following, overflow) = frames.addingReportingOverflow(Int64(chunk.samples.count / source.channels))
            guard !overflow else { throw EngineError.encodeFailed("audio frame count out of range") }
            frames = following
            progress(min(1, Double(frames) / expectedFrames))
        }
        try await encoder.finish()
    }

    private static func encodingPrecision(_ input: MediaInput, track: MediaTrack, format: AudioFormat) async throws
        -> (bits: Int?, float: Bool)
    {
        var bits: Int?
        var float = false
        switch track.codec {
        case .pcm(let depth, let floatingPoint, _):
            bits = depth
            float = floatingPoint
        case .alac, .flac:
            if case .asset(_, _, let audio) = input.backend, let audio {
                let descriptions = try await audio.load(.formatDescriptions)
                let depths = descriptions.map { description -> Int? in
                    guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                        return nil
                    }
                    if basic.mBitsPerChannel > 0 { return Int(basic.mBitsPerChannel) }
                    switch basic.mFormatFlags {
                    case kAppleLosslessFormatFlag_16BitSourceData: return 16
                    case kAppleLosslessFormatFlag_20BitSourceData: return 20
                    case kAppleLosslessFormatFlag_24BitSourceData: return 24
                    case kAppleLosslessFormatFlag_32BitSourceData: return 32
                    default: return nil
                    }
                }
                if !depths.isEmpty, depths.allSatisfy({ $0 != nil }) { bits = depths.compactMap { $0 }.max() }
            } else if track.codec == .flac, validFLACHeader(track.codecPrivate), let header = track.codecPrivate {
                let packedDepthOffset = flacMarkerLength + flacBlockHeaderLength + 12
                let bytes = [UInt8](header)
                bits = Int(bytes[packedDepthOffset] & 1) << 4 | Int(bytes[packedDepthOffset + 1] >> 4)
                bits = bits.map { $0 + 1 }
            }
            if bits == nil, !format.isLossy {
                throw EngineError.unsupportedCodec(
                    String(
                        localized: "Unknown audio bit depth", comment: "Lossless extraction requires known precision"))
            }
        default: break
        }
        let maximumIntegerDepth = 24
        let maximumFloatDepth = 32
        if !format.isLossy, let bits, bits > (float ? maximumFloatDepth : maximumIntegerDepth) {
            throw EngineError.unsupportedCodec(
                String(
                    localized: "Audio precision cannot be preserved", comment: "Extraction exceeds decoder precision"))
        }
        return (bits, float)
    }

    private static func canCopy(_ track: MediaTrack, to format: AudioFormat) -> Bool {
        switch format {
        case .m4aAAC: return track.codec == .aac
        case .aac: return track.codec == .aac && aacConfiguration(track.codecPrivate) != nil
        case .m4aALAC: return track.codec == .alac
        case .mp3: return track.codec == .mp3
        case .ogg: return track.codec == .vorbis
        case .opus: return track.codec == .opus
        case .flac: return track.codec == .flac && validFLACHeader(track.codecPrivate)
        case .wav:
            if case .pcm(let bits, let float, let bigEndian) = track.codec {
                return !bigEndian && [8, 16, 24, 32].contains(bits) && (!float || bits == 32)
            }
            return false
        case .aiff:
            if case .pcm(let bits, let float, let bigEndian) = track.codec {
                return bigEndian && !float && [16, 24, 32].contains(bits)
            }
            return false
        default: return false
        }
    }

    private static func aacConfiguration(_ codecPrivate: Data?) -> (frequency: Int, channels: Int)? {
        guard let codecPrivate, codecPrivate.count == 2 else { return nil }
        let bytes = [UInt8](codecPrivate)
        let profile = Int(bytes[0] >> 3)
        let frequency = Int(bytes[0] & 7) << 1 | Int(bytes[1] >> 7)
        let channels = Int(bytes[1] >> 3 & 15)
        guard profile == aacLowComplexity, frequency < 13, channels > 0 else { return nil }
        return (frequency, channels)
    }

    private static func validFLACHeader(_ codecPrivate: Data?) -> Bool {
        guard let codecPrivate, codecPrivate.starts(with: Data("fLaC".utf8)) else { return false }
        let bytes = [UInt8](codecPrivate)
        var cursor = flacMarkerLength
        var first = true
        while cursor + flacBlockHeaderLength <= bytes.count {
            let flags = bytes[cursor]
            let length = Int(bytes[cursor + 1]) << 16 | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            if first && (flags & 0x7F != 0 || length != flacStreamInfoLength) { return false }
            cursor += flacBlockHeaderLength + length
            if cursor > bytes.count { return false }
            if flags & 0x80 != 0 { return cursor == bytes.count }
            first = false
        }
        return false
    }

    private static func copy(
        _ input: MediaInput, track: MediaTrack, format: AudioFormat, to output: URL,
        progress: (Double) -> Void
    ) async throws {
        let stage = try await PacketCopyStage(input: input, track: track, number: 1, start: 0, end: .max)
        switch format {
        case .m4aAAC, .m4aALAC:
            guard let outputTrack = stage.output else { throw EngineError.decodeFailed("missing audio track") }
            let sink = try AssetWriterSink(url: output, fileType: .m4a, tracks: [outputTrack], transform: .identity)
            while stage.nextTime != nil {
                try Task.checkCancellation()
                for packet in try await stage.pull() {
                    try await sink.write(packet)
                    progress(Double(packet.timestamp) / Double(max(input.duration, 1)))
                }
            }
            try await sink.finish()
        case .aac, .mp3, .flac:
            try Data().write(to: output, options: .withoutOverwriting)
            let file = try FileHandle(forWritingTo: output)
            defer { try? file.close() }
            if format == .flac, let codecPrivate = track.codecPrivate { try file.write(contentsOf: codecPrivate) }
            while stage.nextTime != nil {
                try Task.checkCancellation()
                for packet in try await stage.pull() {
                    if format == .aac {
                        try file.write(contentsOf: adtsHeader(track: track, payloadLength: packet.payload.count))
                    }
                    try file.write(contentsOf: packet.payload)
                    progress(Double(packet.timestamp) / Double(max(input.duration, 1)))
                }
            }
            try file.close()
        case .ogg, .opus:
            try await copyOgg(stage, input: input, track: track, format: format, to: output, progress: progress)
        case .wav, .aiff:
            try await copyPCM(stage, input: input, track: track, format: format, to: output, progress: progress)
        default:
            throw EngineError.unsupportedCodec(track.codec.displayName)
        }
    }

    private static func adtsHeader(track: MediaTrack, payloadLength: Int) throws -> Data {
        guard let config = aacConfiguration(track.codecPrivate),
            payloadLength <= adtsMaximumFrameLength - adtsHeaderLength
        else {
            throw EngineError.decodeFailed("AAC cannot be copied to ADTS")
        }
        let length = payloadLength + adtsHeaderLength
        let frequency = config.frequency
        let channels = config.channels
        return Data([
            0xFF, 0xF1, UInt8(1 << 6 | frequency << 2 | channels >> 2),
            UInt8((channels & 3) << 6 | length >> 11), UInt8(length >> 3 & 0xFF),
            UInt8((length & 7) << 5 | 0x1F), 0xFC,
        ])
    }

    private static func copyOgg(
        _ stage: PacketCopyStage, input: MediaInput, track: MediaTrack, format: AudioFormat, to output: URL,
        progress: (Double) -> Void
    ) async throws {
        guard let codecPrivate = track.codecPrivate,
            case .audio(let sampleRate, _) = track.kind
        else { throw EngineError.decodeFailed("missing Ogg codec headers") }
        let writer = try OggPacketWriter(url: output)
        if format == .opus {
            try writer.writeHeader(codecPrivate)
            try writer.writeHeader(Data("OpusTags".utf8) + VorbisComment.encode(AudioTags()))
        } else {
            for header in try VorbisAudioDecoder.headers(codecPrivate: codecPrivate) {
                try writer.writeHeader(header)
            }
        }
        var held: MediaPacket?
        let rate = format == .opus ? Self.opusSampleRate : Int(sampleRate)
        while stage.nextTime != nil {
            try Task.checkCancellation()
            for packet in try await stage.pull() {
                if let held {
                    let duration: Int64
                    if let declared = held.duration {
                        duration = declared
                    } else {
                        let (gap, gapOverflow) = packet.timestamp.subtractingReportingOverflow(held.timestamp)
                        guard !gapOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
                        duration = max(gap, 0)
                    }
                    let (end, endOverflow) = held.timestamp.addingReportingOverflow(duration)
                    guard !endOverflow else { throw EngineError.decodeFailed("media duration out of range") }
                    let granule = max(0, try Nanoseconds.scale(end, by: Int64(rate), over: Nanoseconds.perSecond))
                    try writer.write(held.payload, granule: granule, last: false)
                }
                held = packet
                progress(Double(packet.timestamp) / Double(max(input.duration, 1)))
            }
        }
        guard let held else { throw EngineError.decodeFailed("empty audio stream") }
        let duration: Int64
        if let declared = held.duration {
            duration = declared
        } else {
            let (gap, gapOverflow) = input.duration.subtractingReportingOverflow(held.timestamp)
            guard !gapOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            duration = max(gap, 0)
        }
        let (end, endOverflow) = held.timestamp.addingReportingOverflow(duration)
        guard !endOverflow else { throw EngineError.decodeFailed("media duration out of range") }
        let padding = try Nanoseconds.scale(held.discardPadding ?? 0, by: Int64(rate), over: Nanoseconds.perSecond)
        let endGranule = try Nanoseconds.scale(end, by: Int64(rate), over: Nanoseconds.perSecond)
        let (adjustedGranule, granuleOverflow) = endGranule.subtractingReportingOverflow(padding)
        guard !granuleOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        let granule = max(0, adjustedGranule)
        try writer.write(held.payload, granule: granule, last: true)
        try writer.close()
    }

    private static func copyPCM(
        _ stage: PacketCopyStage, input: MediaInput, track: MediaTrack, format: AudioFormat, to output: URL,
        progress: (Double) -> Void
    ) async throws {
        guard case .audio(let sampleRate, let channels) = track.kind,
            case .pcm(let bits, let float, let bigEndian) = track.codec
        else { throw EngineError.decodeFailed("not PCM audio") }
        let bytesPerFrame = bits / 8 * channels
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsPacked
                | (float ? kAudioFormatFlagIsFloat : bits == 8 ? 0 : kAudioFormatFlagIsSignedInteger)
                | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bits), mReserved: 0)
        var audioFile: AudioFileID?
        let type = format == .wav ? kAudioFileWAVEType : kAudioFileAIFFType
        let created = AudioFileCreateWithURL(output as CFURL, type, &description, [], &audioFile)
        guard created == noErr, let audioFile else { throw EngineError.encodeFailed("AudioFileCreate \(created)") }
        do {
            var packetNumber: Int64 = 0
            var synthesizedSilenceFrames: Int64 = 0
            let maximumSilenceFrames = try pcmFramePosition(maximumSynthesizedSilence, sampleRate: sampleRate)
            let codecDelay = try pcmFramePosition(track.codecDelay, sampleRate: sampleRate)
            func write(_ payload: Data) throws {
                guard !payload.isEmpty else { return }
                let expectedPackets = UInt32(payload.count / bytesPerFrame)
                var packetCount = expectedPackets
                let status = payload.withUnsafeBytes { bytes in
                    guard let address = bytes.baseAddress else {
                        return OSStatus(kAudioFileInvalidPacketOffsetError)
                    }
                    return AudioFileWritePackets(
                        audioFile, false, UInt32(bytes.count), nil, packetNumber, &packetCount, address)
                }
                guard status == noErr, packetCount == expectedPackets else {
                    throw EngineError.encodeFailed("AudioFileWritePackets \(status)")
                }
                let (following, overflow) = packetNumber.addingReportingOverflow(Int64(packetCount))
                guard !overflow else { throw EngineError.encodeFailed("audio frame count out of range") }
                packetNumber = following
            }
            while stage.nextTime != nil {
                try Task.checkCancellation()
                for packet in try await stage.pull() {
                    guard packet.payload.count.isMultiple(of: bytesPerFrame) else {
                        throw EngineError.decodeFailed("unaligned PCM packet")
                    }
                    let count = Int64(packet.payload.count / bytesPerFrame)
                    let leading = try pcmFramePosition(packet.trimDurationAtStart ?? 0, sampleRate: sampleRate)
                    let padding = try pcmFramePosition(packet.discardPadding ?? 0, sampleRate: sampleRate)
                    let first = min(count, max(0, leading) + max(0, -padding))
                    let last = count - min(count, max(0, padding))
                    guard last > first else { continue }
                    let presented = try pcmFramePosition(
                        packet.outputTimestamp ?? packet.timestamp, sampleRate: sampleRate)
                    let due = presented + (packet.outputTimestamp == nil ? first - codecDelay : 0)
                    let (gap, gapOverflow) = due.subtractingReportingOverflow(packetNumber)
                    guard !gapOverflow else { throw EngineError.decodeFailed("audio frame count out of range") }
                    if gap > 0 {
                        let (total, overflow) = synthesizedSilenceFrames.addingReportingOverflow(gap)
                        guard !overflow, total <= maximumSilenceFrames else {
                            throw EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")
                        }
                        while packetNumber < due {
                            try Task.checkCancellation()
                            let frames = Int(min(due - packetNumber, Int64(silenceChunkFrames)))
                            try write(Data(repeating: bits == 8 ? 128 : 0, count: frames * bytesPerFrame))
                        }
                        synthesizedSilenceFrames = total
                    }
                    let overlap = min(last - first, max(0, -gap))
                    if first + overlap < last {
                        try write(
                            packet.payload.subdata(in: Int(first + overlap) * bytesPerFrame..<Int(last) * bytesPerFrame)
                        )
                    }
                    progress(Double(packet.timestamp) / Double(max(input.duration, 1)))
                }
            }
        } catch {
            AudioFileClose(audioFile)
            throw error
        }
        let closed = AudioFileClose(audioFile)
        guard closed == noErr else { throw EngineError.encodeFailed("AudioFileClose \(closed)") }
    }

    private static func pcmFramePosition(_ timestamp: Int64, sampleRate: Double) throws -> Int64 {
        let time = CMTime(value: timestamp, timescale: SampleBuffers.nanosecondScale)
        let frames = CMTimeConvertScale(
            CMTimeMultiplyByFloat64(time, multiplier: sampleRate), timescale: 1, method: .roundHalfAwayFromZero)
        guard frames.isNumeric else { throw EngineError.decodeFailed("audio frame count out of range") }
        return frames.value
    }
}
