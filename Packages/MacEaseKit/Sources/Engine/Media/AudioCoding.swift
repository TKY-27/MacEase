import AVFoundation
import AudioToolbox
import Formats
import Foundation

/// Speaker layouts make downmixing possible.
enum PCMFormat {
    static func make(sampleRate: Double, channels: Int) throws -> AVAudioFormat {
        let tag: AudioChannelLayoutTag =
            switch channels {
            case 1: kAudioChannelLayoutTag_Mono
            case 2: kAudioChannelLayoutTag_Stereo
            case 3: kAudioChannelLayoutTag_MPEG_3_0_A
            case 4: kAudioChannelLayoutTag_Quadraphonic
            case 5: kAudioChannelLayoutTag_MPEG_5_0_A
            case 6: kAudioChannelLayoutTag_MPEG_5_1_A
            case 7: kAudioChannelLayoutTag_MPEG_6_1_A
            case 8: kAudioChannelLayoutTag_MPEG_7_1_C
            default: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            }
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else {
            throw EngineError.unsupportedCodec("\(channels) audio channels")
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: true, channelLayout: layout)
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let channels = Int(format.channelCount)
        let frames = AVAudioFrameCount(samples.count / channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)),
            let destination = buffer.floatChannelData?[0]
        else { throw EngineError.encodeFailed("no PCM buffer") }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: Int(frames) * channels)
        }
        buffer.frameLength = frames
        return buffer
    }

    static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        guard count > 0, let source = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: source, count: count))
    }
}

/// One input per call; `nil` ends.
private func convert(
    _ converter: AVAudioConverter, input: AVAudioBuffer?, makeOutput: () throws -> AVAudioBuffer,
    collect: (AVAudioBuffer) -> Void
) throws {
    var supplied = false
    while true {
        let output = try makeOutput()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let input, !supplied else {
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw EngineError.encodeFailed(error.map { "AudioConverter \($0.code)" } ?? "AudioConverter failed")
        }
        collect(output)
        if status != .haveData { return }
    }
}

/// Resamples and downmixes interleaved float PCM.
public final class PCMConverter {
    private static let slackFrames = 4_096

    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat

    public init(sampleRate: Double, channels: Int, toSampleRate targetRate: Double, channels targetChannels: Int) throws
    {
        input = try PCMFormat.make(sampleRate: sampleRate, channels: channels)
        output = try PCMFormat.make(sampleRate: targetRate, channels: targetChannels)
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw EngineError.unsupportedCodec("\(channels)-channel \(sampleRate) Hz to \(targetRate) Hz conversion")
        }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
    }

    public func convert(_ samples: [Float]) throws -> [Float] {
        try run(PCMFormat.buffer(samples, format: input), frames: samples.count / Int(input.channelCount))
    }

    public func finish() throws -> [Float] {
        try run(nil, frames: 0)
    }

    private func run(_ buffer: AVAudioPCMBuffer?, frames: Int) throws -> [Float] {
        let capacity =
            AVAudioFrameCount(Double(frames) * output.sampleRate / input.sampleRate) + 2
            * AVAudioFrameCount(Self.slackFrames)
        var result: [Float] = []
        try Engine.convert(
            converter, input: buffer,
            makeOutput: {
                guard let output = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                    throw EngineError.encodeFailed("no PCM buffer")
                }
                return output
            },
            collect: { output in
                if let output = output as? AVAudioPCMBuffer { result += PCMFormat.samples(output) }
            })
        return result
    }
}

/// AAC-LC packets from AudioToolbox, without container framing.
final class AACEncoder {
    static let framesPerPacket = 1_024
    private static let packetBatch: AVAudioPacketCount = 32
    private static let lowComplexity = 2
    private static let rates = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000,
    ]

    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    let sampleRate: Int
    let channels: Int

    init(sampleRate: Int, channels: Int, kilobits: Int) throws {
        input = try PCMFormat.make(sampleRate: Double(sampleRate), channels: channels)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]
        guard let output = AVAudioFormat(settings: settings), let converter = AVAudioConverter(from: input, to: output)
        else { throw EngineError.unsupportedCodec("AAC at \(sampleRate) Hz with \(channels) channels") }
        let requested = kilobits * 1_000
        let applicable = (converter.applicableEncodeBitRates ?? []).map(\.intValue).sorted()
        converter.bitRate = applicable.last { $0 <= requested } ?? applicable.first ?? requested
        self.output = output
        self.converter = converter
        self.sampleRate = sampleRate
        self.channels = channels
    }

    static func applicableKilobits(sampleRate: Int, channels: Int) -> [Int] {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]
        guard let input = try? PCMFormat.make(sampleRate: Double(sampleRate), channels: channels),
            let output = AVAudioFormat(settings: settings),
            let converter = AVAudioConverter(from: input, to: output)
        else { return [] }
        return (converter.applicableEncodeBitRates ?? []).map { $0.intValue / 1_000 }.sorted()
    }

    /// Two-byte AudioSpecificConfig for AAC-LC.
    var audioSpecificConfig: Data {
        let value = Self.lowComplexity << 11 | frequencyIndex << 7 | channels << 3
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private var frequencyIndex: Int { Self.rates.firstIndex(of: sampleRate) ?? 0 }

    /// ISO/IEC 13818-7 header without CRC.
    func adtsHeader(payloadLength: Int) -> Data {
        let length = payloadLength + 7
        let profile = Self.lowComplexity - 1
        return Data([
            0xFF, 0xF1, UInt8(profile << 6 | frequencyIndex << 2 | channels >> 2),
            UInt8((channels & 3) << 6 | length >> 11), UInt8(length >> 3 & 0xFF), UInt8((length & 7) << 5 | 0x1F), 0xFC,
        ])
    }

    func encode(_ samples: [Float]) throws -> [Data] {
        try run(PCMFormat.buffer(samples, format: input))
    }

    func finish() throws -> [Data] {
        try run(nil)
    }

    private func run(_ buffer: AVAudioPCMBuffer?) throws -> [Data] {
        var packets: [Data] = []
        try Engine.convert(
            converter, input: buffer,
            makeOutput: {
                AVAudioCompressedBuffer(
                    format: output, packetCapacity: Self.packetBatch,
                    maximumPacketSize: converter.maximumOutputPacketSize)
            },
            collect: { output in
                guard let output = output as? AVAudioCompressedBuffer, let descriptions = output.packetDescriptions
                else { return }
                for index in 0..<Int(output.packetCount) {
                    let description = descriptions[index]
                    packets.append(
                        Data(
                            bytes: output.data + Int(description.mStartOffset), count: Int(description.mDataByteSize)))
                }
            })
        return packets
    }
}

public struct EncodedAudioPacket: Sendable {
    public let data: Data
    /// Duration in samples at the encoder's rate.
    public let frames: Int
}

/// Packets and codec private data for muxers.
public final class AudioPacketEncoder {
    private enum Backend {
        case aac(AACEncoder)
        case opus(OpusAudioEncoder)
        case vorbis(VorbisAudioEncoder)
    }

    private let backend: Backend
    public let sampleRate: Int
    public let channels: Int
    /// AudioSpecificConfig, OpusHead or Xiph-laced Vorbis headers.
    public let codecPrivate: Data
    private var vorbisGranule: Int64 = 0

    /// Opus takes 48 kHz only.
    public init(codec: MediaCodec, sampleRate: Int, channels: Int, kilobits: Int) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        do {
            switch codec {
            case .aac:
                let aac = try AACEncoder(sampleRate: sampleRate, channels: channels, kilobits: kilobits)
                backend = .aac(aac)
                codecPrivate = aac.audioSpecificConfig
            case .opus where sampleRate == OpusAudioEncoder.sampleRate:
                let opus = try OpusAudioEncoder(channels: channels, bitrate: kilobits * 1_000)
                backend = .opus(opus)
                codecPrivate = opus.identificationHeader
            case .vorbis:
                let vorbis = try VorbisAudioEncoder(
                    sampleRate: sampleRate, channels: channels, bitrate: kilobits * 1_000)
                backend = .vorbis(vorbis)
                codecPrivate = vorbis.codecPrivate
            default:
                throw EngineError.unsupportedCodec("\(codec.displayName) at \(sampleRate) Hz")
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    /// Samples the decoder drops first.
    public var delay: Int {
        if case .opus(let opus) = backend { opus.preSkip } else { 0 }
    }

    public func encode(_ interleaved: [Float]) throws -> [EncodedAudioPacket] {
        do {
            switch backend {
            case .aac(let aac): return try aac.encode(interleaved).map(Self.aacPacket)
            case .opus(let opus): return try opus.encode(interleaved).map(Self.opusPacket)
            case .vorbis(let vorbis): return vorbisPackets(try vorbis.encode(interleaved))
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    public func finish() throws -> [EncodedAudioPacket] {
        do {
            switch backend {
            case .aac(let aac): return try aac.finish().map(Self.aacPacket)
            case .opus(let opus):
                let flush = [Float](repeating: 0, count: opus.preSkip * channels)
                return try (opus.encode(flush) + opus.finish()).map(Self.opusPacket)
            case .vorbis(let vorbis): return vorbisPackets(try vorbis.finish())
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    private static func aacPacket(_ data: Data) -> EncodedAudioPacket {
        EncodedAudioPacket(data: data, frames: AACEncoder.framesPerPacket)
    }

    private static func opusPacket(_ data: Data) -> EncodedAudioPacket {
        EncodedAudioPacket(data: data, frames: OpusAudioEncoder.frameSamples)
    }

    private func vorbisPackets(_ packets: [XiphPacket]) -> [EncodedAudioPacket] {
        packets.map { packet in
            defer { vorbisGranule = packet.granule }
            return EncodedAudioPacket(data: packet.data, frames: Int(packet.granule - vorbisGranule))
        }
    }
}

/// Demuxed audio packets to float PCM.
public final class AudioPacketDecoder {
    private enum Backend {
        case toolbox(AVAudioConverter, AVAudioFormat)
        case opus(OpusAudioDecoder)
        case vorbis(VorbisAudioDecoder)
        case pcm(bits: Int, float: Bool, bigEndian: Bool)
    }

    private static let maximumFrames: AVAudioFrameCount = 1 << 16
    /// After "fLaC" and the block header.
    private static let flacStreamInfoOffset = 8
    private static let flacStreamInfoLength = 34

    private let backend: Backend
    private let output: AVAudioFormat
    public let sampleRate: Double
    public let channels: Int
    /// Opus codec delay left to drop.
    private var leadingFrames: Int

    public init(track: MediaTrack) throws {
        guard case .audio(let sampleRate, let channels) = track.kind else {
            throw EngineError.decodeFailed("not an audio track")
        }
        self.sampleRate = track.codec == .opus ? Double(OpusAudioEncoder.sampleRate) : sampleRate
        self.channels = channels
        leadingFrames = 0
        do {
            output = try PCMFormat.make(sampleRate: self.sampleRate, channels: channels)
            switch track.codec {
            case .opus:
                backend = .opus(try OpusAudioDecoder(channels: channels))
                leadingFrames = Int(track.codecDelay * Int64(OpusAudioEncoder.sampleRate) / Nanoseconds.perSecond)
            case .vorbis:
                let headers = try VorbisAudioDecoder.headers(codecPrivate: track.codecPrivate ?? Data())
                backend = .vorbis(try VorbisAudioDecoder(headers: headers))
            case .pcm(let bits, let float, let bigEndian):
                guard [8, 16, 24, 32].contains(bits) else { throw EngineError.unsupportedCodec("\(bits)-bit PCM") }
                backend = .pcm(bits: bits, float: float, bigEndian: bigEndian)
            case .aac, .mp3, .ac3, .flac:
                backend = try Self.toolbox(track, sampleRate: sampleRate, channels: channels, output: output)
            case .unsupported(let name):
                throw EngineError.unsupportedCodec(name)
            default:
                throw EngineError.unsupportedCodec(track.codec.displayName)
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    private static func toolbox(_ track: MediaTrack, sampleRate: Double, channels: Int, output: AVAudioFormat) throws
        -> Backend
    {
        let (formatID, framesPerPacket, flags): (AudioFormatID, UInt32, UInt32) =
            switch track.codec {
            case .aac: (kAudioFormatMPEG4AAC, 1_024, 0)
            case .mp3: (kAudioFormatMPEGLayer3, 1_152, 0)
            case .ac3: (kAudioFormatAC3, 1_536, 0)
            default: try flacLayout(track.codecPrivate ?? Data())
            }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: flags, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
            let converter = AVAudioConverter(from: input, to: output)
        else { throw EngineError.unsupportedCodec(track.codec.displayName) }
        if let cookie = track.codecPrivate, !cookie.isEmpty {
            converter.magicCookie = track.codec == .flac ? flacCookie(cookie) : cookie
        }
        return .toolbox(converter, input)
    }

    /// Block size and depth flag.
    private static func flacLayout(_ codecPrivate: Data) throws -> (AudioFormatID, UInt32, UInt32) {
        let streamInfo = [UInt8](codecPrivate.dropFirst(flacStreamInfoOffset))
        guard streamInfo.count >= flacStreamInfoLength else {
            throw EngineError.decodeFailed("FLAC STREAMINFO missing")
        }
        let maximumBlock = UInt32(streamInfo[2]) << 8 | UInt32(streamInfo[3])
        let bits = Int((streamInfo[12] & 1) << 4 | streamInfo[13] >> 4) + 1
        let flag: UInt32 = [16: 1, 20: 2, 24: 3, 32: 4][bits] ?? 0
        return (kAudioFormatFLAC, maximumBlock, flag)
    }

    /// AudioToolbox expects a `dfLa` box body.
    private static func flacCookie(_ codecPrivate: Data) -> Data {
        Data([0, 0, 0, 0]) + (codecPrivate.starts(with: Data("fLaC".utf8)) ? codecPrivate.dropFirst(4) : codecPrivate)
    }

    public func decode(_ packet: MediaPacket) throws -> [Float] {
        var samples: [Float]
        do {
            switch backend {
            case .toolbox(let converter, let input): samples = try decode(packet.payload, converter, input)
            case .opus(let opus): samples = try opus.decode(packet.payload)
            case .vorbis(let vorbis): samples = try vorbis.decode(packet.payload)
            case .pcm(let bits, let float, let bigEndian):
                samples = Self.pcm(packet.payload, bits: bits, float: float, bigEndian: bigEndian)
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
        if let padding = packet.discardPadding, padding > 0 {
            let frames = Int(padding * Int64(sampleRate) / Nanoseconds.perSecond)
            samples.removeLast(min(samples.count, frames * channels))
        }
        if leadingFrames > 0 {
            let dropped = min(samples.count / channels, leadingFrames)
            samples.removeFirst(dropped * channels)
            leadingFrames -= dropped
        }
        return samples
    }

    private func decode(_ payload: Data, _ converter: AVAudioConverter, _ input: AVAudioFormat) throws -> [Float] {
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: payload.count)
        payload.copyBytes(to: packet.data.assumingMemoryBound(to: UInt8.self), count: payload.count)
        packet.packetCount = 1
        packet.byteLength = UInt32(payload.count)
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
        var samples: [Float] = []
        var supplied = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: Self.maximumFrames) else {
                throw EngineError.decodeFailed("no PCM buffer")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return packet
            }
            if status == .error { throw EngineError.decodeFailed("AudioConverter \(error?.code ?? 0)") }
            samples += PCMFormat.samples(output)
            if status != .haveData { return samples }
        }
    }

    private static func pcm(_ payload: Data, bits: Int, float: Bool, bigEndian: Bool) -> [Float] {
        let width = bits / 8
        let bytes = [UInt8](payload)
        return stride(from: 0, to: bytes.count - width + 1, by: width).map { offset in
            var value: UInt32 = 0
            for index in 0..<width {
                let byte = UInt32(bytes[offset + (bigEndian ? index : width - 1 - index)])
                value = value << 8 | byte
            }
            if float { return Float(bitPattern: value) }
            if width == 1 { return (Float(value) - 128) / 128 }
            let shift = UInt32(32 - bits)
            return Float(Int32(bitPattern: value << shift)) / Float(Int32.max)
        }
    }
}
