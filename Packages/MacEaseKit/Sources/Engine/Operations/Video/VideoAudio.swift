import AVFoundation
import AudioToolbox
import CoreMedia
import Formats
import Foundation

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
                let timestamp = max(0, packet.timestamp - codecDelay)
                if timestamp >= end { return nil }
                guard let decoder else { throw EngineError.decodeFailed("missing audio decoder") }
                let samples = try decoder.decode(packet)
                let discarded = max(
                    0, Int((Double(start - timestamp) * sampleRate / Double(Nanoseconds.perSecond)).rounded()))
                let kept = min(
                    samples.count / channels,
                    Int((Double(end - timestamp) * sampleRate / Double(Nanoseconds.perSecond)).rounded()))
                if kept > discarded {
                    return (Array(samples[discarded * channels..<kept * channels]), max(timestamp, start))
                }
            }
            return nil
        }
    }
}

final class AudioEncodeStage: StreamStage {
    private static let silenceChunkFrames = 4_096

    private let source: VideoPCMSource
    private let encoder: AudioPacketEncoder?
    private let converter: PCMConverter?
    private let channels: Int
    private let sampleRate: Int
    private let start: Int64
    private let number: Int
    private var position: Int64
    private var clockOrigin: Int64?
    private var sourceCursor: Int64?
    private var pendingChunk: (samples: [Float], timestamp: Int64)?
    private var inputFrames: Int64 = 0
    private var encodedFrames: Int64 = 0
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
                let missing = Int(
                    (Double(chunk.timestamp - sourceCursor) * source.sampleRate / Double(Nanoseconds.perSecond))
                        .rounded())
                if missing > 1 {
                    let frames = min(missing, Self.silenceChunkFrames)
                    pendingChunk = chunk
                    self.sourceCursor =
                        sourceCursor
                        + Int64(
                            (Double(frames) * Double(Nanoseconds.perSecond) / source.sampleRate).rounded())
                    let silence = [Float](repeating: 0, count: frames * source.channels)
                    let converted = try converter?.convert(silence) ?? silence
                    let packets = try encoded(converted)
                    if !packets.isEmpty { return packets }
                    continue
                }
            }
            sourceCursor =
                chunk.timestamp
                + Int64(
                    (Double(chunk.samples.count / source.channels) * Double(Nanoseconds.perSecond) / source.sampleRate)
                        .rounded())
            let converted = try converter?.convert(chunk.samples) ?? chunk.samples
            let packets = try encoded(converted)
            if !packets.isEmpty { return packets }
        }
        let tail = try converter?.finish() ?? []
        var packets = try encoded(tail)
        if let encoder { packets += timed(try encoder.finish()) }
        if output?.track.codec == .opus, let encoder, !packets.isEmpty {
            let padding = max(0, encodedFrames - inputFrames - Int64(encoder.delay))
            packets[packets.count - 1].discardPadding = padding * Nanoseconds.perSecond / Int64(sampleRate)
        }
        sourceEnded = true
        return packets
    }

    private func encoded(_ samples: [Float]) throws -> [MediaPacket] {
        guard !samples.isEmpty else { return [] }
        inputFrames += Int64(samples.count / channels)
        if let encoder { return timed(try encoder.encode(samples)) }
        var bytes = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var word = Int16(
                clamping: Int((Double(min(max(sample, -1), 1)) * Double(Int16.max)).rounded())
            ).littleEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        return timed([EncodedAudioPacket(data: bytes, frames: samples.count / channels)])
    }

    private func timed(_ encoded: [EncodedAudioPacket]) -> [MediaPacket] {
        encoded.map { packet in
            let origin = clockOrigin ?? start
            let timestamp = origin + encodedFrames * Nanoseconds.perSecond / Int64(sampleRate)
            encodedFrames += Int64(packet.frames)
            position = origin + encodedFrames * Nanoseconds.perSecond / Int64(sampleRate)
            let duration = position - timestamp
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

    static func extract(_ format: AudioFormat, url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        guard let track = input.audio, case .audio(let sampleRate, _) = track.kind else {
            throw EngineError.invalidInput(.malformed("no audio track"))
        }
        let name = url.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        let output = try context.stagingURL(for: url, name: name)
        if canCopy(track, to: format) {
            try await copy(input, track: track, format: format, to: output, progress: context.progress)
        } else {
            let target = AudioTarget.defaults(for: format, settings: context.settings.audio)
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
        let bitDepth: Int?
        let isFloat: Bool
        if case .pcm(let bits, let float, _) = track.codec {
            bitDepth = bits
            isFloat = float
        } else {
            bitDepth = nil
            isFloat = false
        }
        let source = try VideoPCMSource(input: input, track: track, start: 0, end: .max)
        let encoder = try AudioFileEncoder(
            url: output, target: target, sampleRate: source.sampleRate, channels: source.channels,
            bitDepth: bitDepth, isFloat: isFloat)
        var frames: Int64 = 0
        let expectedFrames = max(sampleRate * Double(input.duration) / Double(Nanoseconds.perSecond), 1)
        while let chunk = try await source.next() {
            try Task.checkCancellation()
            let due = try Nanoseconds.scale(chunk.timestamp, by: Int64(source.sampleRate), over: Nanoseconds.perSecond)
            if due - frames > gapToleranceFrames {
                try await encoder.write([Float](repeating: 0, count: Int(due - frames) * source.channels))
                frames = due
            }
            try await encoder.write(chunk.samples)
            frames += Int64(chunk.samples.count / source.channels)
            progress(min(1, Double(frames) / expectedFrames))
        }
        try await encoder.finish()
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
                    let end = held.timestamp + (held.duration ?? max(packet.timestamp - held.timestamp, 0))
                    let granule = max(0, end * Int64(rate) / Nanoseconds.perSecond)
                    try writer.write(held.payload, granule: granule, last: false)
                }
                held = packet
                progress(Double(packet.timestamp) / Double(max(input.duration, 1)))
            }
        }
        guard let held else { throw EngineError.decodeFailed("empty audio stream") }
        let end = held.timestamp + (held.duration ?? max(input.duration - held.timestamp, 0))
        let padding = (held.discardPadding ?? 0) * Int64(rate) / Nanoseconds.perSecond
        let granule = max(0, end * Int64(rate) / Nanoseconds.perSecond - padding)
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
            while stage.nextTime != nil {
                try Task.checkCancellation()
                for packet in try await stage.pull() {
                    guard packet.payload.count.isMultiple(of: bytesPerFrame) else {
                        throw EngineError.decodeFailed("unaligned PCM packet")
                    }
                    let expectedPackets = UInt32(packet.payload.count / bytesPerFrame)
                    var packetCount = expectedPackets
                    let status = packet.payload.withUnsafeBytes { bytes in
                        guard let address = bytes.baseAddress else {
                            return OSStatus(kAudioFileInvalidPacketOffsetError)
                        }
                        return AudioFileWritePackets(
                            audioFile, false, UInt32(bytes.count), nil, packetNumber, &packetCount, address)
                    }
                    guard status == noErr, packetCount == expectedPackets else {
                        throw EngineError.encodeFailed("AudioFileWritePackets \(status)")
                    }
                    packetNumber += Int64(packetCount)
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
}
