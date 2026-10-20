import Foundation

/// H.264 and AAC in FLV, with onMetaData.
public struct FLVMuxer: MediaMuxer {
    private static let aacFlags: UInt8 = 0xAF
    private static let maximumTimestamp = Int64(UInt32.max)

    private let file: PatchableFile
    private let video: MediaTrack?
    private let audio: MediaTrack?
    private var durationOffset: Int64 = 0
    private var end: Int64 = 0
    private var lastVideoTime: Int64 = 0
    private var finished = false

    public init(url: URL, tracks: [MediaTrack]) throws {
        for track in tracks where !(track.codec == .h264 && track.isVideo || track.codec == .aac && !track.isVideo) {
            throw FormatError.unsupported("\(track.codec.displayName) in FLV")
        }
        guard tracks.filter(\.isVideo).count <= 1, tracks.filter({ !$0.isVideo }).count <= 1 else {
            throw FormatError.unsupported("more than one stream of a kind in FLV")
        }
        for track in tracks where track.codecPrivate == nil {
            throw FormatError.encoderFailure("\(track.codec.displayName) without its decoder configuration")
        }
        video = tracks.first(where: \.isVideo)
        audio = tracks.first { !$0.isVideo }
        file = try PatchableFile(url: url)
        try writeHeader()
    }

    private mutating func writeHeader() throws {
        var header = Data("FLV".utf8)
        header.append(1)
        header.append((audio == nil ? 0 : 4) | (video == nil ? 0 : 1))
        header.appendBigEndian(UInt32(FLV.fileHeaderSize))
        header.appendBigEndian(UInt32(0))
        try file.append(header)

        var properties: [Data] = [FLV.amfNumber("duration", 0)]
        if let video, case .video(let width, let height) = video.kind {
            properties += [
                FLV.amfNumber("width", Double(width)), FLV.amfNumber("height", Double(height)),
                FLV.amfNumber("videocodecid", Double(FLV.avcCodecID)),
            ]
        }
        if let audio, case .audio(let sampleRate, let channels) = audio.kind {
            properties += [
                FLV.amfNumber("audiocodecid", Double(FLV.aacSoundFormat)),
                FLV.amfNumber("audiosamplerate", sampleRate), FLV.amfKey("stereo") + [1, channels > 1 ? 1 : 0],
            ]
        }
        var script = Data([2]) + FLV.amfKey("onMetaData") + [8]
        script.appendBigEndian(UInt32(properties.count))
        let durationPosition = script.count + FLV.amfKey("duration").count + 1
        script += properties.reduce(Data(), +) + [0, 0, 9]
        durationOffset = file.position + Int64(FLV.tagHeaderSize + durationPosition)
        try writeTag(FLV.scriptTag, time: 0, script)

        if let codecPrivate = video?.codecPrivate {
            try writeTag(
                FLV.videoTag, time: 0,
                Data([FLV.keyFrame << 4 | FLV.avcCodecID, FLV.sequenceHeader, 0, 0, 0]) + codecPrivate)
        }
        if let codecPrivate = audio?.codecPrivate {
            try writeTag(FLV.audioTag, time: 0, Data([Self.aacFlags, FLV.sequenceHeader]) + codecPrivate)
        }
    }

    private func writeTag(_ type: UInt8, time: Int64, _ body: Data) throws {
        guard body.count < 1 << 24 else { throw FormatError.encoderFailure("FLV tag over 16 MB") }
        var header = Data([type])
        header += [UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)]
        header += [UInt8(time >> 16 & 0xFF), UInt8(time >> 8 & 0xFF), UInt8(time & 0xFF), UInt8(time >> 24 & 0xFF)]
        header += [0, 0, 0]
        try file.append(header)
        try file.append(body)
        var trailer = Data()
        trailer.appendBigEndian(UInt32(FLV.tagHeaderSize + body.count))
        try file.append(trailer)
    }

    private static func milliseconds(_ nanoseconds: Int64) -> Int64 {
        (nanoseconds + Nanoseconds.perMillisecond / 2) / Nanoseconds.perMillisecond
    }

    /// Packets must arrive in decode order.
    public mutating func write(_ packet: MediaPacket) throws {
        guard !finished else { throw FormatError.encoderFailure("FLV already finished") }
        let decodeTime = packet.decodeTimestamp ?? packet.timestamp
        guard decodeTime >= 0, Self.milliseconds(packet.timestamp) <= Self.maximumTimestamp else {
            throw FormatError.encoderFailure("FLV timestamps must be between 0 and 49 days")
        }
        let time = Self.milliseconds(decodeTime)
        switch packet.track {
        case video?.number:
            let offset = Self.milliseconds(packet.timestamp) - time
            let frameType = packet.isKeyframe ? FLV.keyFrame : FLV.interFrame
            var body = Data([frameType << 4 | FLV.avcCodecID, FLV.codedFrames])
            body += [
                UInt8(truncatingIfNeeded: offset >> 16), UInt8(truncatingIfNeeded: offset >> 8),
                UInt8(truncatingIfNeeded: offset),
            ]
            try writeTag(FLV.videoTag, time: time, body + packet.payload)
            lastVideoTime = time
        case audio?.number:
            try writeTag(FLV.audioTag, time: time, Data([Self.aacFlags, FLV.codedFrames]) + packet.payload)
        default:
            throw FormatError.encoderFailure("packet for unknown track \(packet.track)")
        }
        end = max(end, packet.timestamp + (packet.duration ?? 0))
    }

    public mutating func finish() throws {
        guard !finished else { throw FormatError.encoderFailure("FLV already finished") }
        finished = true
        if video != nil {
            try writeTag(
                FLV.videoTag, time: lastVideoTime,
                Data([FLV.keyFrame << 4 | FLV.avcCodecID, FLV.endOfSequence, 0, 0, 0]))
        }
        var seconds = Data()
        seconds.appendBigEndian((Double(end) / Double(Nanoseconds.perSecond)).bitPattern)
        try file.patch(seconds, at: durationOffset)
        try file.close()
    }
}
