import Foundation

/// Motion JPEG and PCM in OpenDML AVI.
public struct AVIMuxer: MediaMuxer {
    /// Non-OpenDML readers stop after one RIFF.
    private static let riffLimit: Int64 = 1 << 30
    private static let superIndexCapacity = 256
    private static let superIndexHeader = 24
    private static let standardIndexHeader = 24
    private static let suggestedBuffer: UInt32 = 1 << 20
    private static let hasIndexAndInterleaved: UInt32 = 0x110
    /// Sample frames of timestamp rounding to ignore.
    private static let pcmSlack: Int64 = 1

    private struct Stream {
        let track: MediaTrack
        let chunkID: Data
        let frameDuration: Int64
        let blockAlign: Int
        var headerOffset: Int64 = 0
        var superIndexOffset: Int64 = 0
        var segmentEntries: [(offset: UInt32, size: UInt32)] = []
        var segmentUnits: Int64 = 0
        var superEntries: [(offset: Int64, size: UInt32, units: Int64)] = []
        var units: Int64 = 0
        var largestChunk = 0

        /// 8-bit PCM is unsigned around 128.
        var silence: UInt8 {
            if case .pcm(8, false, _) = track.codec { 0x80 } else { 0 }
        }
    }

    private let file: PatchableFile
    private var streams: [Stream]
    private var riffStart: Int64 = 0
    private var moviStart: Int64 = 0
    private var legacyIndex: Data? = Data()
    private var firstRiffFrames: Int64 = 0
    private var avihOffset: Int64 = 0
    private var dmlhOffset: Int64 = 0
    private var finished = false

    public init(url: URL, tracks: [MediaTrack]) throws {
        streams = try tracks.enumerated().map { index, track in try Self.stream(index, track) }
        guard streams.filter({ $0.track.isVideo }).count <= 1 else {
            throw FormatError.unsupported("more than one video stream in AVI")
        }
        file = try PatchableFile(url: url)
        try writeHeader()
    }

    private static func stream(_ index: Int, _ track: MediaTrack) throws -> Stream {
        switch (track.kind, track.codec) {
        case (.video, .mjpeg):
            guard let frameDuration = track.defaultDuration, frameDuration > 0 else {
                throw FormatError.unsupported("AVI video without a frame rate")
            }
            return Stream(
                track: track, chunkID: AVI.chunkID(stream: index, suffix: "dc"), frameDuration: frameDuration,
                blockAlign: 0
            )
        case (.audio(_, let channels), .pcm(let bits, let float, false))
        where channels > 0 && bits > 0 && bits % 8 == 0 && (!float || bits == 32):
            return Stream(
                track: track, chunkID: AVI.chunkID(stream: index, suffix: "wb"), frameDuration: 0,
                blockAlign: channels * bits / 8
            )
        default:
            throw FormatError.unsupported("\(track.codec.displayName) in AVI")
        }
    }

    private var videoStream: Int? {
        streams.firstIndex { $0.track.isVideo }
    }

    private mutating func writeHeader() throws {
        try file.append(AVI.fourCC("RIFF") + Data(count: 4) + AVI.fourCC("AVI "))
        let hdrlStart = file.position
        try file.append(AVI.fourCC("LIST") + Data(count: 4) + AVI.fourCC("hdrl"))
        avihOffset = file.position + 8
        try file.append(chunk("avih", mainHeader()))
        for index in streams.indices {
            let strlStart = file.position
            try file.append(AVI.fourCC("LIST") + Data(count: 4) + AVI.fourCC("strl"))
            streams[index].headerOffset = file.position + 8
            try file.append(chunk("strh", streamHeader(streams[index])))
            try file.append(chunk("strf", streamFormat(streams[index].track)))
            streams[index].superIndexOffset = file.position + 8
            try file.append(chunk("indx", superIndex(streams[index])))
            try patchSize(listAt: strlStart)
        }
        let odmlStart = file.position
        try file.append(AVI.fourCC("LIST") + Data(count: 4) + AVI.fourCC("odml"))
        dmlhOffset = file.position + 8
        try file.append(chunk("dmlh", Data(count: AVI.extendedHeaderSize)))
        try patchSize(listAt: odmlStart)
        try patchSize(listAt: hdrlStart)
        try openMovi()
    }

    private func chunk(_ id: String, _ body: Data) -> Data {
        var bytes = AVI.fourCC(id)
        bytes.appendLittleEndian(UInt32(body.count))
        bytes += body
        if body.count % 2 == 1 { bytes.append(0) }
        return bytes
    }

    private func patchSize(listAt offset: Int64) throws {
        var size = Data()
        size.appendLittleEndian(UInt32(file.position - offset - 8))
        try file.patch(size, at: offset + 4)
    }

    private func dimensions() -> (width: Int, height: Int) {
        guard let videoStream, case .video(let width, let height) = streams[videoStream].track.kind else {
            return (0, 0)
        }
        return (width, height)
    }

    private func mainHeader() -> Data {
        var header = Data()
        let frameDuration = videoStream.map { streams[$0].frameDuration } ?? 0
        header.appendLittleEndian(UInt32(frameDuration / 1_000))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(Self.hasIndexAndInterleaved)
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(streams.count))
        header.appendLittleEndian(Self.suggestedBuffer)
        header.appendLittleEndian(UInt32(dimensions().width))
        header.appendLittleEndian(UInt32(dimensions().height))
        header += Data(count: 16)
        return header
    }

    private func streamHeader(_ stream: Stream) -> Data {
        var header = Data()
        let scale: Int64
        let rate: Int64
        if stream.track.isVideo {
            header += AVI.fourCC("vids") + AVI.fourCC("MJPG")
            let divisor = Self.gcd(stream.frameDuration, Nanoseconds.perSecond)
            scale = stream.frameDuration / divisor
            rate = Nanoseconds.perSecond / divisor
        } else {
            header += AVI.fourCC("auds") + Data(count: 4)
            scale = Int64(stream.blockAlign)
            rate = Int64(sampleRate(stream.track)) * scale
        }
        header += Data(count: 12)
        header.appendLittleEndian(UInt32(scale))
        header.appendLittleEndian(UInt32(rate))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(stream.units))
        header.appendLittleEndian(UInt32(stream.largestChunk))
        header.appendLittleEndian(UInt32.max)
        header.appendLittleEndian(UInt32(stream.blockAlign))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(UInt16(stream.track.isVideo ? dimensions().width : 0))
        header.appendLittleEndian(UInt16(stream.track.isVideo ? dimensions().height : 0))
        return header
    }

    private static func gcd(_ first: Int64, _ second: Int64) -> Int64 {
        second == 0 ? first : gcd(second, first % second)
    }

    private func sampleRate(_ track: MediaTrack) -> Double {
        if case .audio(let sampleRate, _) = track.kind { sampleRate } else { 0 }
    }

    private func streamFormat(_ track: MediaTrack) -> Data {
        var format = Data()
        switch (track.kind, track.codec) {
        case (.video(let width, let height), _):
            format.appendLittleEndian(UInt32(40))
            format.appendLittleEndian(Int32(width))
            format.appendLittleEndian(Int32(height))
            format.appendLittleEndian(UInt16(1))
            format.appendLittleEndian(UInt16(24))
            format += AVI.fourCC("MJPG")
            format.appendLittleEndian(UInt32(width * height * 3))
            format += Data(count: 16)
        case (.audio(let sampleRate, let channels), .pcm(let bits, let float, _)):
            let blockAlign = channels * bits / 8
            format.appendLittleEndian(UInt16(float ? 3 : 1))
            format.appendLittleEndian(UInt16(channels))
            format.appendLittleEndian(UInt32(sampleRate))
            format.appendLittleEndian(UInt32(Int(sampleRate) * blockAlign))
            format.appendLittleEndian(UInt16(blockAlign))
            format.appendLittleEndian(UInt16(bits))
            format.appendLittleEndian(UInt16(0))
        case (.audio, _):
            break
        }
        return format
    }

    private func superIndex(_ stream: Stream) -> Data {
        var index = Data()
        index.appendLittleEndian(UInt16(4))
        index.append(0)
        index.append(AVI.indexOfIndexes)
        index.appendLittleEndian(UInt32(stream.superEntries.count))
        index += stream.chunkID + Data(count: 12)
        for entry in stream.superEntries {
            index.appendLittleEndian(UInt64(entry.offset))
            index.appendLittleEndian(entry.size)
            index.appendLittleEndian(UInt32(entry.units))
        }
        return index + Data(count: (Self.superIndexCapacity - stream.superEntries.count) * 16)
    }

    private mutating func openMovi() throws {
        if file.position > 0, legacyIndex == nil {
            riffStart = file.position
            try file.append(AVI.fourCC("RIFF") + Data(count: 4) + AVI.fourCC("AVIX"))
        }
        try file.append(AVI.fourCC("LIST") + Data(count: 4))
        moviStart = file.position
        try file.append(AVI.fourCC("movi"))
    }

    /// Packets must arrive in timestamp order.
    public mutating func write(_ packet: MediaPacket) throws {
        guard !finished else { throw FormatError.encoderFailure("AVI already finished") }
        guard let index = streams.firstIndex(where: { $0.track.number == packet.track }) else {
            throw FormatError.encoderFailure("packet for unknown track \(packet.track)")
        }
        let start = max(packet.timestamp, 0)
        if streams[index].track.isVideo {
            let frameDuration = streams[index].frameDuration
            let frame = (start + frameDuration / 2) / frameDuration
            guard frame >= streams[index].units else {
                throw FormatError.encoderFailure("video frames closer than the AVI frame rate")
            }
            while streams[index].units < frame { try writeChunk(Data(), stream: index, keyframe: false, units: 1) }
            try writeChunk(packet.payload, stream: index, keyframe: packet.isKeyframe, units: 1)
        } else {
            let blockAlign = streams[index].blockAlign
            guard packet.payload.count % blockAlign == 0 else {
                throw FormatError.encoderFailure("PCM packet is not whole sample frames")
            }
            let rate = Int64(sampleRate(streams[index].track))
            let gap = try Nanoseconds.scale(start, by: rate, over: Nanoseconds.perSecond) - streams[index].units
            guard gap >= -Self.pcmSlack else { throw FormatError.encoderFailure("overlapping PCM packets") }
            if gap > Self.pcmSlack {
                let silence = Data(repeating: streams[index].silence, count: Int(gap) * blockAlign)
                try writeChunk(silence, stream: index, keyframe: true, units: gap)
            }
            try writeChunk(
                packet.payload, stream: index, keyframe: true, units: Int64(packet.payload.count / blockAlign))
        }
    }

    private mutating func writeChunk(_ payload: Data, stream index: Int, keyframe: Bool, units: Int64) throws {
        if file.position + 8 + Int64(payload.count) - riffStart > Self.riffLimit {
            try closeRiff()
            try openMovi()
        }
        let offset = file.position
        let flags = keyframe ? AVI.keyframeFlag : 0
        if legacyIndex != nil {
            legacyIndex? += streams[index].chunkID
            legacyIndex?.appendLittleEndian(flags)
            legacyIndex?.appendLittleEndian(UInt32(offset - moviStart))
            legacyIndex?.appendLittleEndian(UInt32(payload.count))
        }
        var header = streams[index].chunkID
        header.appendLittleEndian(UInt32(payload.count))
        try file.append(header)
        try file.append(payload)
        if payload.count % 2 == 1 { try file.append([UInt8(0)]) }
        let size = UInt32(payload.count) | (keyframe ? 0 : AVI.deltaFrameBit)
        streams[index].segmentEntries.append((UInt32(offset + 8 - riffStart), size))
        streams[index].segmentUnits += units
        streams[index].units += units
        streams[index].largestChunk = max(streams[index].largestChunk, payload.count)
    }

    private mutating func closeRiff() throws {
        for index in streams.indices where !streams[index].segmentEntries.isEmpty {
            guard streams[index].superEntries.count < Self.superIndexCapacity else {
                throw FormatError.unsupported("AVI larger than its index capacity")
            }
            var body = Data()
            body.appendLittleEndian(UInt16(2))
            body.append(0)
            body.append(AVI.indexOfChunks)
            body.appendLittleEndian(UInt32(streams[index].segmentEntries.count))
            body += streams[index].chunkID
            body.appendLittleEndian(UInt64(riffStart))
            body.appendLittleEndian(UInt32(0))
            for entry in streams[index].segmentEntries {
                body.appendLittleEndian(entry.offset)
                body.appendLittleEndian(entry.size)
            }
            let indexChunk = chunk("ix" + String(format: "%02d", index), body)
            streams[index].superEntries.append((file.position, UInt32(indexChunk.count), streams[index].segmentUnits))
            try file.append(indexChunk)
            streams[index].segmentEntries = []
            streams[index].segmentUnits = 0
        }
        try patchSize(listAt: moviStart - 8)
        if let legacyIndex {
            try file.append(chunk("idx1", legacyIndex))
            firstRiffFrames = videoStream.map { streams[$0].units } ?? 0
            self.legacyIndex = nil
        }
        try patchSize(listAt: riffStart)
    }

    public mutating func finish() throws {
        guard !finished else { throw FormatError.encoderFailure("AVI already finished") }
        finished = true
        try closeRiff()
        for stream in streams {
            try file.patch(streamHeader(stream), at: stream.headerOffset)
            try file.patch(superIndex(stream), at: stream.superIndexOffset)
        }
        var frames = Data()
        frames.appendLittleEndian(UInt32(firstRiffFrames))
        try file.patch(frames, at: avihOffset + 16)
        var totalFrames = Data()
        totalFrames.appendLittleEndian(UInt32(videoStream.map { streams[$0].units } ?? 0))
        try file.patch(totalFrames, at: dmlhOffset)
        try file.close()
    }
}
