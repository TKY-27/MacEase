import Foundation

public struct FLVDemuxer: MediaDemuxer {
    /// Encoders put sequence headers first.
    private static let probeTags = 2_000
    private static let encryptedBit: UInt8 = 0x20
    private static let enhancedVideoBit: UInt8 = 0x80

    public private(set) var tracks: [MediaTrack] = []
    public private(set) var duration: Int64?

    private let file: RandomAccessFile
    private let firstTag: Int64
    private var position: Int64

    private struct Tag {
        let type: UInt8
        let timestamp: Int64
        let body: [UInt8]
    }

    public init(url: URL) throws {
        file = try RandomAccessFile(url: url)
        guard file.size >= Int64(FLV.fileHeaderSize + 4) else { throw FormatError.corrupt("not an FLV file") }
        let header = try file.bytes(at: 0, count: FLV.fileHeaderSize)
        guard header[0..<3].elementsEqual("FLV".utf8), header[3] == 1 else {
            throw FormatError.corrupt("not an FLV file")
        }
        firstTag = Int64(UInt32(bigEndian: header, at: 5)) + 4
        position = firstTag
        try probe()
        position = firstTag
    }

    private mutating func probe() throws {
        var metadata: [String: Double] = [:]
        var video: MediaTrack?
        var audio: MediaTrack?
        for _ in 0..<Self.probeTags {
            guard let tag = try nextTag() else { break }
            switch tag.type {
            case FLV.scriptTag:
                metadata.merge(try FLV.metadata(tag.body)) { first, _ in first }
            case FLV.videoTag where video == nil || video?.codec == .h264 && video?.codecPrivate == nil:
                video = try videoTrack(tag.body)
            case FLV.audioTag where audio == nil || audio?.codec == .aac && audio?.codecPrivate == nil:
                audio = try audioTrack(tag.body)
            default:
                break
            }
        }
        if let video {
            if video.codec == .h264, video.codecPrivate == nil { throw FormatError.corrupt("H.264 without avcC") }
            tracks.append(video)
        }
        if let audio {
            if audio.codec == .aac, audio.codecPrivate == nil {
                throw FormatError.corrupt("AAC without AudioSpecificConfig")
            }
            tracks.append(audio)
        }
        guard !tracks.isEmpty else { throw FormatError.corrupt("FLV without audio or video") }
        if let seconds = metadata["duration"], seconds > 0 { duration = try Nanoseconds.from(seconds: seconds) }
    }

    private func videoTrack(_ body: [UInt8]) throws -> MediaTrack? {
        guard let flags = body.first else { return nil }
        guard flags & Self.enhancedVideoBit == 0 else {
            return MediaTrack(
                number: FLV.videoTrack, kind: .video(width: 0, height: 0), codec: .unsupported("Enhanced FLV video"))
        }
        let codec = FLV.videoCodec(flags & 0x0F)
        var track = MediaTrack(number: FLV.videoTrack, kind: .video(width: 0, height: 0), codec: codec)
        if codec == .h264, body.count > 5, body[1] == FLV.sequenceHeader {
            let record = Array(body[5...])
            let size = try FLV.avcDimensions(record)
            track.kind = .video(width: size.width, height: size.height)
            track.codecPrivate = Data(record)
        }
        return track
    }

    private func audioTrack(_ body: [UInt8]) throws -> MediaTrack? {
        guard let flags = body.first else { return nil }
        let codec = FLV.audioCodec(format: flags >> 4, sixteenBit: flags & 2 != 0)
        var track = MediaTrack(
            number: FLV.audioTrack, kind: .audio(sampleRate: FLV.audioRate(flags), channels: flags & 1 == 0 ? 1 : 2),
            codec: codec
        )
        if codec == .aac, body.count > 2, body[1] == FLV.sequenceHeader {
            let config = Array(body[2...])
            let format = try FLV.aacFormat(config)
            track.kind = .audio(sampleRate: format.sampleRate, channels: format.channels)
            track.codecPrivate = Data(config)
        }
        return track
    }

    private mutating func nextTag() throws -> Tag? {
        guard position < file.size else { return nil }
        guard position + Int64(FLV.tagHeaderSize) <= file.size else { throw FormatError.corrupt("truncated FLV tag") }
        let header = try file.bytes(at: position, count: FLV.tagHeaderSize)
        guard header[0] & Self.encryptedBit == 0 else { throw FormatError.unsupported("encrypted FLV") }
        let size = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        let timestamp = Int64(header[7]) << 24 | Int64(header[4]) << 16 | Int64(header[5]) << 8 | Int64(header[6])
        let bodyStart = position + Int64(FLV.tagHeaderSize)
        guard bodyStart + Int64(size) <= file.size else { throw FormatError.corrupt("truncated FLV tag") }
        position = bodyStart + Int64(size) + 4
        return Tag(type: header[0] & 0x1F, timestamp: timestamp, body: try file.bytes(at: bodyStart, count: size))
    }

    public mutating func nextPacket() throws -> MediaPacket? {
        while let tag = try nextTag() {
            let decodeTime = tag.timestamp * Nanoseconds.perMillisecond
            guard tag.type == FLV.videoTag || tag.type == FLV.audioTag, tag.body.count > 1 else { continue }
            let number = tag.type == FLV.videoTag ? FLV.videoTrack : FLV.audioTrack
            guard tracks.contains(where: { $0.number == number }) else {
                throw FormatError.unsupported("FLV stream starting after \(Self.probeTags) tags")
            }
            switch tag.type {
            case FLV.videoTag:
                let keyframe = tag.body[0] >> 4 == FLV.keyFrame
                guard tag.body[0] & 0x0F == FLV.avcCodecID else {
                    return MediaPacket(
                        track: FLV.videoTrack, timestamp: decodeTime, isKeyframe: keyframe,
                        payload: Data(tag.body[1...])
                    )
                }
                guard tag.body.count > 5, tag.body[1] == FLV.codedFrames else { continue }
                let offset =
                    Int32(bitPattern: UInt32(tag.body[2]) << 24 | UInt32(tag.body[3]) << 16 | UInt32(tag.body[4]) << 8)
                    >> 8
                return MediaPacket(
                    track: FLV.videoTrack, timestamp: decodeTime + Int64(offset) * Nanoseconds.perMillisecond,
                    decodeTimestamp: decodeTime, isKeyframe: keyframe, payload: Data(tag.body[5...])
                )
            default:
                let aac = tag.body[0] >> 4 == FLV.aacSoundFormat
                if aac, tag.body[1] != FLV.codedFrames { continue }
                let payload = Data(tag.body[(aac ? 2 : 1)...])
                return MediaPacket(track: FLV.audioTrack, timestamp: decodeTime, isKeyframe: true, payload: payload)
            }
        }
        return nil
    }
}
