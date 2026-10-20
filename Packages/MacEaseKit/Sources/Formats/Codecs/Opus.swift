import COpus
import Foundation
import NativeShims

/// libopus at 48 kHz, 20 ms frames.
public final class OpusAudioEncoder {
    public static let sampleRate = 48_000
    public static let frameSamples = 960
    private static let maximumComplexity: Int32 = 10
    /// libopus's recommended output buffer.
    private static let maximumPacketBytes = 4_000

    private let encoder: OpaquePointer
    public let channels: Int
    /// Samples the decoder drops first.
    public let preSkip: Int
    private var pending: [Float] = []

    public init(channels: Int, bitrate: Int) throws {
        guard (1...2).contains(channels) else { throw FormatError.unsupported("Opus with \(channels) channels") }
        guard let bitrate = Int32(exactly: bitrate) else { throw FormatError.encoderFailure("Opus settings rejected") }
        var status: Int32 = 0
        guard
            let encoder = opus_encoder_create(Int32(Self.sampleRate), Int32(channels), OPUS_APPLICATION_AUDIO, &status),
            status == OPUS_OK
        else { throw FormatError.encoderFailure("opus_encoder_create \(status)") }
        self.encoder = encoder
        self.channels = channels
        guard macease_opus_set_bitrate(encoder, bitrate) == OPUS_OK,
            macease_opus_set_complexity(encoder, Self.maximumComplexity) == OPUS_OK
        else {
            opus_encoder_destroy(encoder)
            throw FormatError.encoderFailure("Opus settings rejected")
        }
        var lookahead: Int32 = 0
        guard macease_opus_get_lookahead(encoder, &lookahead) == OPUS_OK else {
            opus_encoder_destroy(encoder)
            throw FormatError.encoderFailure("Opus lookahead unavailable")
        }
        preSkip = Int(lookahead)
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    /// RFC 7845 identification header, also Matroska's CodecPrivate.
    public var identificationHeader: Data {
        var header = Data("OpusHead".utf8)
        header.append(1)
        header.append(UInt8(channels))
        header.appendLittleEndian(UInt16(preSkip))
        header.appendLittleEndian(UInt32(Self.sampleRate))
        header.appendLittleEndian(UInt16(0))
        header.append(0)
        return header
    }

    /// Interleaved 48 kHz in, whole packets out.
    public func encode(_ samples: [Float]) throws -> [Data] {
        pending += samples
        var packets: [Data] = []
        let block = Self.frameSamples * channels
        var start = 0
        while pending.count - start >= block {
            packets.append(try encodeFrame(Array(pending[start..<(start + block)])))
            start += block
        }
        pending.removeFirst(start)
        return packets
    }

    /// Flushes the lookahead so everything decodes.
    public func finishWithLookahead() throws -> [Data] {
        try encode([Float](repeating: 0, count: preSkip * channels)) + finish()
    }

    /// Silence-padded; callers set `discardPadding`.
    public func finish() throws -> [Data] {
        guard !pending.isEmpty else { return [] }
        let block = Self.frameSamples * channels
        let padded = pending + [Float](repeating: 0, count: block - pending.count)
        pending = []
        return [try encodeFrame(padded)]
    }

    private func encodeFrame(_ frame: [Float]) throws -> Data {
        var output = [UInt8](repeating: 0, count: Self.maximumPacketBytes)
        let written = opus_encode_float(encoder, frame, Int32(Self.frameSamples), &output, Int32(output.count))
        guard written > 0 else { throw FormatError.encoderFailure("opus_encode_float \(written)") }
        return Data(output.prefix(Int(written)))
    }
}

public final class OpusAudioDecoder {
    private static let maximumFrame = 5_760
    private let decoder: OpaquePointer
    public let channels: Int

    public init(channels: Int) throws {
        try AudioMetadata.validate(sampleRate: Double(OpusAudioEncoder.sampleRate), channels: channels)
        guard channels <= 2 else {
            throw FormatError.corrupt(
                String(localized: "Audio channel count out of range", comment: "Rejects unsafe audio metadata"))
        }
        var status: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(OpusAudioEncoder.sampleRate), Int32(channels), &status),
            status == OPUS_OK
        else { throw FormatError.corrupt("opus_decoder_create \(status)") }
        self.decoder = decoder
        self.channels = channels
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Interleaved 48 kHz samples.
    public func decode(_ packet: Data) throws -> [Float] {
        guard let packetBytes = Int32(exactly: packet.count) else {
            throw FormatError.corrupt(
                String(localized: "Audio packet size out of range", comment: "Rejects oversized audio packet"))
        }
        var output = [Float](repeating: 0, count: Self.maximumFrame * channels)
        let decoded = packet.withUnsafeBytes { bytes in
            opus_decode_float(
                decoder, bytes.bindMemory(to: UInt8.self).baseAddress, packetBytes, &output,
                Int32(Self.maximumFrame), 0
            )
        }
        guard decoded >= 0 else { throw FormatError.corrupt("opus_decode_float \(decoded)") }
        return Array(output.prefix(Int(decoded) * channels))
    }
}
