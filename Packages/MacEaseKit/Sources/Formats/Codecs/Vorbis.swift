import COgg
import CVorbis
import Foundation

/// A packet and its end sample position.
public struct XiphPacket: Sendable {
    public let data: Data
    public let granule: Int64
}

/// Vorbis I channel order against WAV order.
enum VorbisChannels {
    /// Vorbis channel feeding each WAV-ordered channel.
    static func order(_ channels: Int) -> [Int] {
        switch channels {
        case 3: [0, 2, 1]
        case 5: [0, 2, 1, 3, 4]
        case 6: [0, 2, 1, 5, 3, 4]
        case 7: [0, 2, 1, 6, 3, 4, 5]
        case 8: [0, 2, 1, 7, 3, 4, 5, 6]
        default: Array(0..<channels)
        }
    }
}

/// libvorbis with average-bitrate management.
public final class VorbisAudioEncoder {
    static let commentPrefix = Data([3]) + Data("vorbis".utf8)
    private static let framingBit: UInt8 = 1

    private let info = UnsafeMutablePointer<vorbis_info>.allocate(capacity: 1)
    private let state = UnsafeMutablePointer<vorbis_dsp_state>.allocate(capacity: 1)
    private let block = UnsafeMutablePointer<vorbis_block>.allocate(capacity: 1)
    public let channels: Int
    /// Identification, comment and setup.
    public let headers: [Data]

    public init(sampleRate: Int, channels: Int, bitrate: Int, tags: AudioTags = AudioTags()) throws {
        self.channels = channels
        vorbis_info_init(info)
        let status = vorbis_encode_init(info, channels, sampleRate, -1, bitrate, -1)
        guard status == 0, vorbis_analysis_init(state, info) == 0 else {
            vorbis_info_clear(info)
            Self.release(info, state, block)
            throw FormatError.unsupported("Vorbis at \(bitrate / 1000) kbps, \(sampleRate) Hz, \(channels) channels")
        }
        vorbis_block_init(state, block)
        var comment = vorbis_comment()
        vorbis_comment_init(&comment)
        var identification = ogg_packet()
        var libraryComment = ogg_packet()
        var setup = ogg_packet()
        let headerStatus = vorbis_analysis_headerout(state, &comment, &identification, &libraryComment, &setup)
        vorbis_comment_clear(&comment)
        headers = [
            Data(bytes: identification.packet, count: identification.bytes),
            Self.commentPrefix + VorbisComment.encode(tags) + Data([Self.framingBit]),
            Data(bytes: setup.packet, count: setup.bytes),
        ]
        guard headerStatus == 0 else { throw FormatError.encoderFailure("vorbis_analysis_headerout \(headerStatus)") }
    }

    deinit {
        vorbis_block_clear(block)
        vorbis_dsp_clear(state)
        vorbis_info_clear(info)
        Self.release(info, state, block)
    }

    /// libvorbis's managed modes cover limited ranges.
    public static func accepts(sampleRate: Int, channels: Int, bitrate: Int) -> Bool {
        var info = vorbis_info()
        vorbis_info_init(&info)
        defer { vorbis_info_clear(&info) }
        return vorbis_encode_init(&info, channels, sampleRate, -1, bitrate, -1) == 0
    }

    private static func release(
        _ info: UnsafeMutablePointer<vorbis_info>, _ state: UnsafeMutablePointer<vorbis_dsp_state>,
        _ block: UnsafeMutablePointer<vorbis_block>
    ) {
        info.deallocate()
        state.deallocate()
        block.deallocate()
    }

    /// Matroska CodecPrivate: the headers in Xiph lacing.
    public var codecPrivate: Data {
        var laced = Data([UInt8(headers.count - 1)])
        for header in headers.dropLast() {
            laced.append(contentsOf: [UInt8](repeating: 255, count: header.count / 255))
            laced.append(UInt8(header.count % 255))
        }
        return headers.reduce(into: laced) { $0.append($1) }
    }

    public func encode(_ interleaved: [Float]) throws -> [XiphPacket] {
        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }
        guard let buffer = vorbis_analysis_buffer(state, Int32(frames)) else {
            throw FormatError.encoderFailure("vorbis_analysis_buffer")
        }
        for (channel, vorbisChannel) in VorbisChannels.order(channels).enumerated() {
            guard let destination = buffer[vorbisChannel] else {
                throw FormatError.encoderFailure("Vorbis channel buffer")
            }
            for frame in 0..<frames { destination[frame] = interleaved[frame * channels + channel] }
        }
        vorbis_analysis_wrote(state, Int32(frames))
        return try drain()
    }

    public func finish() throws -> [XiphPacket] {
        vorbis_analysis_wrote(state, 0)
        return try drain()
    }

    private func drain() throws -> [XiphPacket] {
        var packets: [XiphPacket] = []
        while vorbis_analysis_blockout(state, block) == 1 {
            guard vorbis_analysis(block, nil) == 0, vorbis_bitrate_addblock(block) == 0 else {
                throw FormatError.encoderFailure("vorbis_analysis")
            }
            var packet = ogg_packet()
            while vorbis_bitrate_flushpacket(state, &packet) == 1 {
                packets.append(
                    XiphPacket(data: Data(bytes: packet.packet, count: packet.bytes), granule: packet.granulepos))
            }
        }
        return packets
    }
}

public final class VorbisAudioDecoder {
    private static let headerCount = 3

    private let info = UnsafeMutablePointer<vorbis_info>.allocate(capacity: 1)
    private let state = UnsafeMutablePointer<vorbis_dsp_state>.allocate(capacity: 1)
    private let block = UnsafeMutablePointer<vorbis_block>.allocate(capacity: 1)
    public let sampleRate: Int
    public let channels: Int
    public let tags: AudioTags
    private let order: [Int]
    private var packetNumber: Int64 = 0

    public init(headers: [Data]) throws {
        do {
            guard headers.count == Self.headerCount else { throw FormatError.corrupt("Vorbis needs three headers") }
            tags = try VorbisComment.decode(headers[1].dropFirst(VorbisAudioEncoder.commentPrefix.count))
        } catch {
            info.deallocate()
            state.deallocate()
            block.deallocate()
            throw error
        }
        let info = self.info
        vorbis_info_init(info)
        var comment = vorbis_comment()
        vorbis_comment_init(&comment)
        defer { vorbis_comment_clear(&comment) }
        for (index, header) in headers.enumerated() {
            var bytes = [UInt8](header)
            let status = bytes.withUnsafeMutableBufferPointer { buffer in
                var packet = ogg_packet(
                    packet: buffer.baseAddress, bytes: buffer.count, b_o_s: index == 0 ? 1 : 0, e_o_s: 0,
                    granulepos: 0, packetno: Int64(index))
                return vorbis_synthesis_headerin(info, &comment, &packet)
            }
            guard status == 0 else {
                vorbis_info_clear(info)
                info.deallocate()
                state.deallocate()
                block.deallocate()
                throw FormatError.corrupt("Vorbis header \(index + 1) rejected")
            }
        }
        sampleRate = info.pointee.rate
        channels = Int(info.pointee.channels)
        order = VorbisChannels.order(channels)
        vorbis_synthesis_init(state, info)
        vorbis_block_init(state, block)
        packetNumber = Int64(Self.headerCount)
    }

    deinit {
        vorbis_block_clear(block)
        vorbis_dsp_clear(state)
        vorbis_info_clear(info)
        info.deallocate()
        state.deallocate()
        block.deallocate()
    }

    /// Splits Matroska's Xiph-laced CodecPrivate.
    public static func headers(codecPrivate: Data) throws -> [Data] {
        var cursor = ByteCursor(codecPrivate)
        let count = Int(try cursor.uint8()) + 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var size = 0
            var lace: UInt8 = 255
            while lace == 255 {
                lace = try cursor.uint8()
                size += Int(lace)
            }
            sizes.append(size)
        }
        var headers = try sizes.map { Data(try cursor.take($0)) }
        headers.append(Data(try cursor.take(cursor.remaining)))
        return headers
    }

    /// Interleaved samples; the first packet yields none.
    public func decode(_ packet: Data) throws -> [Float] {
        var bytes = [UInt8](packet)
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            var oggPacket = ogg_packet(
                packet: buffer.baseAddress, bytes: buffer.count, b_o_s: 0, e_o_s: 0, granulepos: -1,
                packetno: packetNumber)
            return vorbis_synthesis(block, &oggPacket)
        }
        packetNumber += 1
        guard status == 0, vorbis_synthesis_blockin(state, block) == 0 else {
            throw FormatError.corrupt("Vorbis packet rejected")
        }
        var output: [Float] = []
        var pcm: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
        var frames = Int(vorbis_synthesis_pcmout(state, &pcm))
        while frames > 0, let channelBuffers = pcm {
            let start = output.count
            output += [Float](repeating: 0, count: frames * channels)
            for (channel, vorbisChannel) in order.enumerated() {
                guard let source = channelBuffers[vorbisChannel] else {
                    throw FormatError.corrupt("Vorbis channel missing")
                }
                for frame in 0..<frames { output[start + frame * channels + channel] = source[frame] }
            }
            vorbis_synthesis_read(state, Int32(frames))
            frames = Int(vorbis_synthesis_pcmout(state, &pcm))
        }
        return output
    }
}
