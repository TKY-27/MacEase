import Foundation

/// RIFF AVI with OpenDML extensions.
public struct AVIDemuxer: MediaDemuxer {
    private static let maximumHeaderChunk = 1 << 20
    private static let maximumIndexChunk = 1 << 26
    private static let maximumMediaChunk: Int64 = 1 << 28

    public private(set) var tracks: [MediaTrack] = []
    public private(set) var duration: Int64?

    private struct StreamInfo {
        var scale: Int64
        var rate: Int64
        var sampleSize: Int64
        var bytesPerSecond: Int64
        var keyframes: [Bool] = []
        var chunkIndex: Int64 = 0
        var bytesSeen: Int64 = 0
    }

    private let file: RandomAccessFile
    private var streams: [StreamInfo] = []
    private(set) var segments: [Range<Int64>] = []
    private var segmentIndex = 0
    private var position: Int64 = 0
    private var listEnds: [Int64] = []

    public init(url: URL) throws {
        file = try RandomAccessFile(url: url)
        var offset: Int64 = 0
        while offset + 12 <= file.size {
            let id = try fourCC(at: offset)
            let size = Int64(try uint32(at: offset + 4))
            let form = try fourCC(at: offset + 8)
            guard id == "RIFF", form == "AVI " || form == "AVIX" else {
                if offset == 0 { throw FormatError.corrupt("not an AVI file") }
                break
            }
            // Interrupted recordings leave RIFF size zero.
            let end = size == 0 ? file.size : min(offset + 8 + size, file.size)
            var child = offset + 12
            while child + 8 <= end {
                let childID = try fourCC(at: child)
                let childSize = Int64(try uint32(at: child + 4))
                let childEnd = childSize == 0 && childID == "LIST" ? end : min(child + 8 + childSize, end)
                if childID == "LIST" {
                    let listType = try fourCC(at: child + 8)
                    if listType == "hdrl" { try parseHeaderList(child + 12, childEnd) }
                    if listType == "movi" { segments.append((child + 12)..<childEnd) }
                } else if childID == "idx1" {
                    try parseLegacyIndex(child + 8, childEnd - child - 8)
                }
                child = childEnd + (childEnd - child) % 2
            }
            offset = end + (end - offset) % 2
        }
        guard !tracks.isEmpty, !segments.isEmpty else { throw FormatError.corrupt("AVI without streams or movi") }
        position = segments[0].lowerBound
    }

    private func fourCC(at offset: Int64) throws -> String {
        String(decoding: try file.bytes(at: offset, count: 4), as: UTF8.self)
    }

    private func uint32(at offset: Int64) throws -> UInt32 {
        UInt32(littleEndian: try file.bytes(at: offset, count: 4), at: 0)
    }

    private mutating func parseHeaderList(_ start: Int64, _ end: Int64) throws {
        var offset = start
        var microsecondsPerFrame: Int64 = 0
        var totalFrames: Int64 = 0
        while offset + 8 <= end {
            let id = try fourCC(at: offset)
            let size = Int64(try uint32(at: offset + 4))
            if id == "avih", size >= AVI.mainHeaderSize {
                let header = try file.bytes(at: offset + 8, count: AVI.mainHeaderSize)
                microsecondsPerFrame = Int64(UInt32(littleEndian: header, at: 0))
                totalFrames = Int64(UInt32(littleEndian: header, at: 16))
            } else if id == "LIST", try fourCC(at: offset + 8) == "strl" {
                try parseStream(offset + 12, min(offset + 8 + size, end))
            } else if id == "LIST", try fourCC(at: offset + 8) == "odml" {
                let dmlh = offset + 12
                if try fourCC(at: dmlh) == "dmlh" { totalFrames = Int64(try uint32(at: dmlh + 8)) }
            }
            offset += 8 + size + size % 2
        }
        let microsecond = Nanoseconds.perSecond / 1_000_000
        duration =
            microsecondsPerFrame > 0
            ? try Nanoseconds.scale(microsecondsPerFrame, by: totalFrames * microsecond, over: 1) : nil
    }

    private mutating func parseStream(_ start: Int64, _ end: Int64) throws {
        var offset = start
        var header: [UInt8] = []
        var format: [UInt8] = []
        var superIndex: [UInt8] = []
        while offset + 8 <= end {
            let id = try fourCC(at: offset)
            let size = Int(try uint32(at: offset + 4))
            guard size <= Self.maximumHeaderChunk else { throw FormatError.corrupt("oversized stream header") }
            let payload = try file.bytes(at: offset + 8, count: size)
            switch id {
            case "strh": header = payload
            case "strf": format = payload
            case "indx": superIndex = payload
            default: break
            }
            offset += 8 + Int64(size) + Int64(size % 2)
        }
        guard header.count >= AVI.minimumStreamHeaderSize else { throw FormatError.corrupt("short strh") }
        let type = String(decoding: header[0..<4], as: UTF8.self)
        let handler = String(decoding: header[4..<8], as: UTF8.self)
        let scale = Int64(UInt32(littleEndian: header, at: 20))
        let rate = Int64(UInt32(littleEndian: header, at: 24))
        let sampleSize = Int64(UInt32(littleEndian: header, at: 44))
        let index = streams.count
        let number = index + 1
        var info = StreamInfo(scale: max(scale, 1), rate: max(rate, 1), sampleSize: sampleSize, bytesPerSecond: 0)
        if type == "vids", format.count >= AVI.bitmapInfoSize {
            let width = Int(Int32(bitPattern: UInt32(littleEndian: format, at: 4)))
            let height = abs(Int(Int32(bitPattern: UInt32(littleEndian: format, at: 8))))
            let compression = String(decoding: format[16..<20], as: UTF8.self)
            var track = MediaTrack(
                number: number, kind: .video(width: width, height: height), codec: Self.videoCodec(compression, handler)
            )
            track.defaultDuration = try Nanoseconds.scale(info.scale, by: Nanoseconds.perSecond, over: info.rate)
            if format.count > AVI.bitmapInfoSize { track.codecPrivate = Data(format[AVI.bitmapInfoSize...]) }
            tracks.append(track)
        } else if type == "auds", format.count >= AVI.waveFormatSize {
            let tag = UInt16(littleEndian: format, at: 0)
            let channels = Int(UInt16(littleEndian: format, at: 2))
            let sampleRate = Double(UInt32(littleEndian: format, at: 4))
            info.bytesPerSecond = Int64(UInt32(littleEndian: format, at: 8))
            let bits = Int(UInt16(littleEndian: format, at: 14))
            var track = MediaTrack(
                number: number, kind: .audio(sampleRate: sampleRate, channels: channels),
                codec: Self.audioCodec(tag, bits: bits)
            )
            if format.count > AVI.waveFormatExSize { track.codecPrivate = Data(format[AVI.waveFormatExSize...]) }
            tracks.append(track)
        }
        streams.append(info)
        if superIndex.count >= AVI.indexHeaderSize { try parseSuperIndex(superIndex, stream: index) }
    }

    static func videoCodec(_ compression: String, _ handler: String) -> MediaCodec {
        switch compression.uppercased() {
        case "MJPG", "AVRN", "LJPG", "JPGL": .mjpeg
        case "H264", "X264", "AVC1", "DAVC": .h264
        case "HEVC", "H265", "HVC1": .hevc
        case "XVID", "DIVX", "DX50", "FMP4", "MP4V", "M4S2": .mpeg4Part2
        case "VP80": .vp8
        case "VP90": .vp9
        case "AV01": .av1
        case "WMV1", "WMV2", "WMV3", "WVC1": .unsupported("WMV")
        case "DIV3", "MP43", "MP42": .unsupported("MS-MPEG4")
        default: .unsupported(compression.trimmingCharacters(in: .whitespaces).isEmpty ? handler : compression)
        }
    }

    static func audioCodec(_ tag: UInt16, bits: Int) -> MediaCodec {
        switch tag {
        case 0x0001: .pcm(bits: bits, float: false, bigEndian: false)
        case 0x0003: .pcm(bits: bits, float: true, bigEndian: false)
        case 0x0055: .mp3
        case 0x2000: .ac3
        case 0x00FF, 0x1610, 0x706D: .aac
        case 0x2001: .unsupported("DTS")
        case 0x0160, 0x0161, 0x0162, 0x0163: .unsupported("WMA")
        default: .unsupported(String(format: "audio format 0x%04X", tag))
        }
    }

    /// Keyframe flags in each stream's chunk order.
    private mutating func parseLegacyIndex(_ start: Int64, _ size: Int64) throws {
        guard streams.allSatisfy({ $0.keyframes.isEmpty }) else { return }
        let count = Int(size) / AVI.legacyIndexEntrySize
        let entries = try file.bytes(at: start, count: count * AVI.legacyIndexEntrySize)
        for entry in 0..<count {
            let base = entry * AVI.legacyIndexEntrySize
            let id = String(decoding: entries[base..<(base + 4)], as: UTF8.self)
            guard let stream = Self.streamNumber(id) else { continue }
            guard stream < streams.count else { throw FormatError.corrupt("idx1 names a missing stream") }
            let flags = UInt32(littleEndian: entries, at: base + 4)
            streams[stream].keyframes.append(flags & AVI.keyframeFlag != 0)
        }
    }

    private mutating func parseSuperIndex(_ index: [UInt8], stream: Int) throws {
        guard index[3] == AVI.indexOfIndexes else { throw FormatError.corrupt("indx is not an index of indexes") }
        let entries = Int(UInt32(littleEndian: index, at: 4))
        guard entries <= (index.count - AVI.indexHeaderSize) / AVI.superIndexEntrySize else {
            throw FormatError.corrupt("indx entry count exceeds its chunk")
        }
        for entry in 0..<entries {
            let base = AVI.indexHeaderSize + entry * AVI.superIndexEntrySize
            let low = UInt64(UInt32(littleEndian: index, at: base))
            let offset = UInt64(UInt32(littleEndian: index, at: base + 4)) << 32 | low
            let size = Int(UInt32(littleEndian: index, at: base + 8))
            guard offset < UInt64(file.size), size > 8 + AVI.indexHeaderSize, size <= Self.maximumIndexChunk else {
                throw FormatError.corrupt("indx entry out of range")
            }
            let chunk = try file.bytes(at: Int64(offset) + 8, count: size - 8)
            let count = Int(UInt32(littleEndian: chunk, at: 4))
            guard count <= (chunk.count - AVI.indexHeaderSize) / AVI.standardIndexEntrySize else {
                throw FormatError.corrupt("ix entry count exceeds its chunk")
            }
            for item in 0..<count {
                let sizeField = AVI.indexHeaderSize + item * AVI.standardIndexEntrySize + 4
                streams[stream].keyframes.append(UInt32(littleEndian: chunk, at: sizeField) & AVI.deltaFrameBit == 0)
            }
        }
    }

    static func streamNumber(_ id: String) -> Int? {
        let digits = id.prefix(2)
        let kind = id.suffix(2)
        guard ["dc", "db", "wb", "pc"].contains(kind) else { return nil }
        return Int(digits)
    }

    public mutating func nextPacket() throws -> MediaPacket? {
        while segmentIndex < segments.count {
            let end = listEnds.last ?? segments[segmentIndex].upperBound
            guard position + 8 <= end else {
                if listEnds.isEmpty {
                    segmentIndex += 1
                    if segmentIndex < segments.count { position = segments[segmentIndex].lowerBound }
                } else {
                    position = listEnds.removeLast()
                }
                continue
            }
            let id = try fourCC(at: position)
            let size = Int64(try uint32(at: position + 4))
            if id == "LIST" {
                listEnds.append(min(position + 8 + size, end))
                position += 12
                continue
            }
            let dataStart = position + 8
            position = dataStart + size + size % 2
            guard dataStart + size <= file.size else { throw FormatError.corrupt("truncated AVI chunk") }
            guard let stream = Self.streamNumber(id), stream < streams.count else { continue }
            guard size <= Self.maximumMediaChunk else { throw FormatError.corrupt("oversized AVI chunk") }
            guard let track = tracks.first(where: { $0.number == stream + 1 }) else { continue }
            let payload = Data(try file.bytes(at: dataStart, count: Int(size)))
            let packet = try packet(track: track, stream: stream, payload: payload)
            if size > 0 { return packet }
        }
        return nil
    }

    private mutating func packet(track: MediaTrack, stream: Int, payload: Data) throws -> MediaPacket {
        var info = streams[stream]
        let timestamp: Int64
        if case .audio = track.kind, info.sampleSize > 0, info.bytesPerSecond > 0 {
            timestamp = try Nanoseconds.scale(info.bytesSeen, by: Nanoseconds.perSecond, over: info.bytesPerSecond)
        } else {
            let ticks = try Nanoseconds.scale(info.chunkIndex, by: info.scale, over: 1)
            timestamp = try Nanoseconds.scale(ticks, by: Nanoseconds.perSecond, over: info.rate)
        }
        let keyframe =
            info.chunkIndex < info.keyframes.count
            ? info.keyframes[Int(info.chunkIndex)] : !track.isVideo || track.codec == .mjpeg || info.chunkIndex == 0
        info.chunkIndex += 1
        info.bytesSeen += Int64(payload.count)
        streams[stream] = info
        return MediaPacket(track: track.number, timestamp: timestamp, isKeyframe: keyframe, payload: payload)
    }
}
