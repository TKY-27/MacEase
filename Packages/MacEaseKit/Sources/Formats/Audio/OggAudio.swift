import Foundation

/// RFC 7845 identification header fields.
struct OpusHead {
    static let magic = Data("OpusHead".utf8)
    static let tagsMagic = Data("OpusTags".utf8)
    /// Output gain is Q7.8 decibels.
    private static let gainScale = 256.0

    let channels: Int
    let preSkip: Int64
    let gain: Float

    init(_ packet: Data) throws {
        var cursor = ByteCursor(packet.dropFirst(Self.magic.count))
        _ = try cursor.uint8()
        channels = Int(try cursor.uint8())
        preSkip = Int64(try cursor.uint16LE())
        _ = try cursor.uint32LE()
        let decibels = Double(Int16(bitPattern: try cursor.uint16LE())) / Self.gainScale
        gain = Float(pow(10, decibels / 20))
        guard try cursor.uint8() == 0 else { throw FormatError.unsupported("Opus with \(channels) channels") }
    }
}

/// Ogg Vorbis or Opus, trimmed by granule.
public final class OggAudioReader: PCMSource {
    private static let vorbisMagic = Data([1]) + Data("vorbis".utf8)
    private static let vorbisHeaderCount = 3

    public let codec: MediaCodec
    public let sampleRate: Double
    public let channels: Int
    public let tags: AudioTags
    /// From the last granule position, when present.
    public let frameCount: Int64?
    private let reader: OggPacketReader
    private let decode: (Data) throws -> [Float]
    private let preSkip: Int64
    private let gain: Float
    private var pending: [Float] = []
    /// First pending frame's granule, once known.
    private var position: Int64?
    private var finished = false

    public init(url: URL) throws {
        reader = try OggPacketReader(url: url)
        guard let first = try reader.next() else { throw FormatError.corrupt("empty Ogg stream") }
        if first.data.starts(with: OpusHead.magic) {
            let head = try OpusHead(first.data)
            guard let tagsPacket = try reader.next(), tagsPacket.data.starts(with: OpusHead.tagsMagic) else {
                throw FormatError.corrupt("Opus tags missing")
            }
            let decoder = try OpusAudioDecoder(channels: head.channels)
            codec = .opus
            sampleRate = Double(OpusAudioEncoder.sampleRate)
            channels = head.channels
            tags = try VorbisComment.decode(tagsPacket.data.dropFirst(OpusHead.tagsMagic.count))
            decode = decoder.decode
            preSkip = head.preSkip
            gain = head.gain
        } else if first.data.starts(with: Self.vorbisMagic) {
            var headers = [first.data]
            while headers.count < Self.vorbisHeaderCount {
                guard let header = try reader.next() else { throw FormatError.corrupt("Vorbis headers missing") }
                headers.append(header.data)
            }
            let decoder = try VorbisAudioDecoder(headers: headers)
            codec = .vorbis
            sampleRate = Double(decoder.sampleRate)
            channels = decoder.channels
            tags = decoder.tags
            decode = decoder.decode
            preSkip = 0
            gain = 1
        } else {
            throw FormatError.unsupported(Self.codecName(first.data))
        }
        if let granule = try reader.lastGranule() {
            frameCount = max(0, granule - preSkip)
        } else {
            frameCount = nil
        }
    }

    private static func codecName(_ header: Data) -> String {
        if header.starts(with: Data([0x7F]) + Data("FLAC".utf8)) { return "Ogg FLAC" }
        if header.starts(with: Data("Speex".utf8)) { return "Speex" }
        return "an unknown Ogg codec"
    }

    public func read() throws -> [Float]? {
        while !finished {
            guard let packet = try reader.next() else {
                finished = true
                return emit(pageEnd: nil, endsStream: false)
            }
            pending += try decode(packet.data)
            guard packet.granule >= 0 else { continue }
            finished = packet.endsStream
            let samples = emit(pageEnd: packet.granule, endsStream: packet.endsStream)
            if !samples.isEmpty { return samples }
        }
        return nil
    }

    /// Drops pre-skip and end padding (RFC 7845).
    private func emit(pageEnd: Int64?, endsStream: Bool) -> [Float] {
        let frames = Int64(pending.count / channels)
        let start = position ?? max(0, (pageEnd ?? frames) - frames)
        var end = start + frames
        if endsStream, let pageEnd { end = min(end, pageEnd) }
        position = start + frames
        let first = max(preSkip, start)
        defer { pending = [] }
        guard end > first else { return [] }
        let kept = pending[Int(first - start) * channels..<Int(end - start) * channels]
        return gain == 1 ? Array(kept) : kept.map { $0 * gain }
    }
}

/// Ogg Vorbis or Ogg Opus with tags.
public final class OggAudioWriter {
    private enum Encoder {
        case vorbis(VorbisAudioEncoder)
        case opus(OpusAudioEncoder)
    }

    private let writer: OggPacketWriter
    private let encoder: Encoder
    private let channels: Int
    private var held: XiphPacket?
    private var inputFrames: Int64 = 0
    private var opusPackets: Int64 = 0

    /// Opus needs 48 kHz input.
    public init(url: URL, codec: MediaCodec, sampleRate: Int, channels: Int, bitrate: Int, tags: AudioTags) throws {
        self.channels = channels
        switch codec {
        case .vorbis:
            let vorbis = try VorbisAudioEncoder(
                sampleRate: sampleRate, channels: channels, bitrate: bitrate, tags: tags)
            encoder = .vorbis(vorbis)
            writer = try OggPacketWriter(url: url)
            for header in vorbis.headers { try writer.writeHeader(header) }
        case .opus:
            guard sampleRate == OpusAudioEncoder.sampleRate else {
                throw FormatError.unsupported("Opus at \(sampleRate) Hz")
            }
            let opus = try OpusAudioEncoder(channels: channels, bitrate: bitrate)
            encoder = .opus(opus)
            writer = try OggPacketWriter(url: url)
            try writer.writeHeader(opus.identificationHeader)
            try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(tags))
        default:
            throw FormatError.unsupported("\(codec.displayName) in Ogg")
        }
    }

    public func write(_ interleaved: [Float]) throws {
        inputFrames += Int64(interleaved.count / channels)
        switch encoder {
        case .vorbis(let vorbis): try queue(try vorbis.encode(interleaved))
        case .opus(let opus): try queue(opusPackets(try opus.encode(interleaved)))
        }
    }

    public func finish() throws {
        switch encoder {
        case .vorbis(let vorbis):
            try queue(try vorbis.finish())
        case .opus(let opus):
            try queue(opusPackets(try opus.finishWithLookahead()))
        }
        guard var last = held else { throw FormatError.encoderFailure("no audio packets") }
        if case .opus(let opus) = encoder {
            last = XiphPacket(data: last.data, granule: Int64(opus.preSkip) + inputFrames)
        }
        try writer.write(last.data, granule: last.granule, last: true)
        try writer.close()
    }

    private func opusPackets(_ packets: [Data]) -> [XiphPacket] {
        packets.map { packet in
            opusPackets += 1
            return XiphPacket(data: packet, granule: opusPackets * Int64(OpusAudioEncoder.frameSamples))
        }
    }

    /// Holds one back to flag the end.
    private func queue(_ packets: [XiphPacket]) throws {
        for packet in packets {
            if let held { try writer.write(held.data, granule: held.granule, last: false) }
            held = packet
        }
    }
}
