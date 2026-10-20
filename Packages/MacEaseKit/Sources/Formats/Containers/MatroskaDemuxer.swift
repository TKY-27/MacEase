import Foundation

public struct MatroskaDemuxer: MediaDemuxer {
    /// Keeps laced timestamps far from overflow.
    private static let maximumFrameDuration = 10 * 60 * Nanoseconds.perSecond
    private static let maximumClusterTimestamp: Int64 = 1 << 62

    public private(set) var tracks: [MediaTrack] = []
    public private(set) var duration: Int64?
    public private(set) var docType = ""

    private let file: RandomAccessFile
    private var timestampScale: Int64 = 1_000_000
    private var segmentEnd: Int64
    private var position: Int64
    private var clusterEnd: Int64?
    private var clusterTimestamp: Int64 = 0
    private var queued: [MediaPacket] = []
    private var strippedHeaders: [Int: [UInt8]] = [:]

    public init(url: URL) throws {
        file = try RandomAccessFile(url: url)
        let header = try EBML.readHeader(file, at: 0)
        guard header.id == MatroskaID.ebml, let headerSize = header.size else {
            throw FormatError.corrupt("not a Matroska file")
        }
        for child in try Self.children(file, from: header.dataStart, to: header.dataStart + headerSize)
        where child.id == MatroskaID.docType {
            docType = EBML.string(try file.bytes(at: child.dataStart, count: Int(child.size ?? 0)))
        }
        guard docType == "matroska" || docType == "webm" else {
            throw FormatError.unsupported("EBML document \(docType)")
        }
        let segment = try EBML.readHeader(file, at: header.dataStart + headerSize)
        guard segment.id == MatroskaID.segment else { throw FormatError.corrupt("missing Segment") }
        let fileSize = file.size
        segmentEnd = segment.size.map { min(segment.dataStart + $0, fileSize) } ?? fileSize
        position = segment.dataStart
        while position < segmentEnd {
            let element = try EBML.readHeader(file, at: position)
            if element.id == MatroskaID.cluster { break }
            guard let size = element.size else { throw FormatError.corrupt("unknown-size top-level element") }
            switch element.id {
            case MatroskaID.info: try parseInfo(element)
            case MatroskaID.tracks: try parseTracks(element)
            default: break
            }
            position = element.dataStart + size
        }
        guard !tracks.isEmpty else { throw FormatError.corrupt("no tracks before the first cluster") }
    }

    static func children(_ file: RandomAccessFile, from start: Int64, to end: Int64) throws -> [EBML.Header] {
        var result: [EBML.Header] = []
        var offset = start
        while offset < end {
            let header = try EBML.readHeader(file, at: offset)
            guard let size = header.size, header.dataStart + size <= end else {
                throw FormatError.corrupt("child element overruns its parent")
            }
            result.append(header)
            offset = header.dataStart + size
        }
        return result
    }

    private func children(of element: EBML.Header) throws -> [EBML.Header] {
        guard let size = element.size else { throw FormatError.corrupt("unknown-size master element") }
        return try Self.children(file, from: element.dataStart, to: element.dataStart + size)
    }

    private func payload(_ element: EBML.Header) throws -> [UInt8] {
        guard let size = element.size, size <= Int64(Int32.max) else { throw FormatError.corrupt("element too large") }
        return try file.bytes(at: element.dataStart, count: Int(size))
    }

    private func integer(_ element: EBML.Header) throws -> Int {
        try EBML.integer(try payload(element))
    }

    private mutating func parseInfo(_ info: EBML.Header) throws {
        var rawDuration: Double?
        for child in try children(of: info) {
            switch child.id {
            case MatroskaID.timestampScale: timestampScale = Int64(try integer(child))
            case MatroskaID.duration: rawDuration = try EBML.float(try payload(child))
            default: break
            }
        }
        guard timestampScale > 0 else { throw FormatError.corrupt("zero TimestampScale") }
        if let rawDuration {
            duration = try Nanoseconds.from(
                seconds: rawDuration * Double(timestampScale) / Double(Nanoseconds.perSecond))
        }
    }

    private mutating func parseTracks(_ list: EBML.Header) throws {
        for entry in try children(of: list) where entry.id == MatroskaID.trackEntry {
            var number = 0
            var type = 0
            var codecID = ""
            var codecPrivate: Data?
            var defaultDuration: Int64?
            var language: String?
            var width = 0
            var height = 0
            var alpha = false
            var sampleRate = 8_000.0
            var channels = 1
            var bitDepth: Int?
            var delay: Int64 = 0
            var preRoll: Int64 = 0
            var encodings: EBML.Header?
            for field in try children(of: entry) {
                switch field.id {
                case MatroskaID.trackNumber: number = try integer(field)
                case MatroskaID.trackType: type = try integer(field)
                case MatroskaID.codecID: codecID = EBML.string(try payload(field))
                case MatroskaID.codecPrivate: codecPrivate = Data(try payload(field))
                case MatroskaID.defaultDuration: defaultDuration = Int64(try integer(field))
                case MatroskaID.language: language = EBML.string(try payload(field))
                case MatroskaID.codecDelay: delay = Int64(try integer(field))
                case MatroskaID.seekPreRoll: preRoll = Int64(try integer(field))
                case MatroskaID.video:
                    for detail in try children(of: field) {
                        switch detail.id {
                        case MatroskaID.pixelWidth: width = try integer(detail)
                        case MatroskaID.pixelHeight: height = try integer(detail)
                        case MatroskaID.alphaMode: alpha = try integer(detail) == 1
                        default: break
                        }
                    }
                case MatroskaID.audio:
                    for detail in try children(of: field) {
                        switch detail.id {
                        case MatroskaID.samplingFrequency: sampleRate = try EBML.float(try payload(detail))
                        case MatroskaID.channels: channels = try integer(detail)
                        case MatroskaID.bitDepth: bitDepth = try integer(detail)
                        default: break
                        }
                    }
                case MatroskaID.contentEncodings: encodings = field
                default: break
                }
            }
            guard number > 0 else { throw FormatError.corrupt("track number 0") }
            if let encodings { strippedHeaders[number] = try strippedHeader(encodings) }
            guard type == MatroskaValue.videoTrack || type == MatroskaValue.audioTrack else { continue }
            if type == MatroskaValue.videoTrack {
                _ = try VideoDecoders.checkedFrameBytes(width: width, height: height)
            } else {
                try AudioMetadata.validate(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
            }
            if let defaultDuration, defaultDuration > Self.maximumFrameDuration {
                throw FormatError.corrupt("DefaultDuration out of range")
            }
            var track = MediaTrack(
                number: number,
                kind: type == MatroskaValue.videoTrack
                    ? .video(width: width, height: height) : .audio(sampleRate: sampleRate, channels: channels),
                codec: MatroskaCodec.codec(id: codecID, bitDepth: bitDepth),
                codecPrivate: codecPrivate
            )
            track.defaultDuration = defaultDuration
            track.language = language
            track.hasAlpha = alpha
            track.codecDelay = delay
            track.seekPreRoll = preRoll
            tracks.append(track)
        }
    }

    /// Header stripping only; other encodings fail.
    private func strippedHeader(_ encodings: EBML.Header) throws -> [UInt8]? {
        var prefix: [UInt8]?
        for encoding in try children(of: encodings) {
            for setting in try children(of: encoding) {
                guard setting.id != MatroskaID.contentEncryption else {
                    throw FormatError.unsupported("encrypted Matroska tracks")
                }
                guard setting.id == MatroskaID.contentCompression else { continue }
                var algorithm: UInt64 = 0
                var settings: [UInt8] = []
                for field in try children(of: setting) {
                    if field.id == MatroskaID.contentCompAlgo { algorithm = try EBML.unsigned(try payload(field)) }
                    if field.id == MatroskaID.contentCompSettings { settings = try payload(field) }
                }
                guard algorithm == MatroskaValue.headerStripping else {
                    throw FormatError.unsupported("compressed Matroska tracks")
                }
                prefix = settings
            }
        }
        return prefix
    }

    public mutating func nextPacket() throws -> MediaPacket? {
        while queued.isEmpty {
            guard position < segmentEnd else { return nil }
            let element = try EBML.readHeader(file, at: position)
            if let end = clusterEnd, position >= end || MatroskaID.topLevel.contains(element.id) {
                clusterEnd = nil
            }
            switch element.id {
            case MatroskaID.cluster:
                clusterEnd = element.size.map { element.dataStart + $0 } ?? segmentEnd
                position = element.dataStart
                continue
            case MatroskaID.clusterTimestamp where clusterEnd != nil:
                clusterTimestamp = Int64(try integer(element))
                guard clusterTimestamp < Self.maximumClusterTimestamp else {
                    throw FormatError.corrupt("cluster timestamp out of range")
                }
            case MatroskaID.simpleBlock where clusterEnd != nil:
                queued = try packets(from: try payload(element), keyframe: nil)
            case MatroskaID.blockGroup where clusterEnd != nil:
                queued = try blockGroup(element)
            default:
                break
            }
            guard let size = element.size else { throw FormatError.corrupt("unknown-size element inside a cluster") }
            position = element.dataStart + size
        }
        return queued.removeFirst()
    }

    private func blockGroup(_ group: EBML.Header) throws -> [MediaPacket] {
        var block: [UInt8]?
        var hasReference = false
        var duration: Int64?
        var additional: Data?
        var discardPadding: Int64?
        for child in try children(of: group) {
            switch child.id {
            case MatroskaID.block: block = try payload(child)
            case MatroskaID.referenceBlock: hasReference = true
            case MatroskaID.blockDuration:
                duration = try Nanoseconds.scale(Int64(try integer(child)), by: timestampScale, over: 1)
            case MatroskaID.discardPadding: discardPadding = try EBML.signed(try payload(child))
            case MatroskaID.blockAdditions:
                for more in try children(of: child) {
                    for field in try children(of: more) where field.id == MatroskaID.blockAdditional {
                        additional = Data(try payload(field))
                    }
                }
            default: break
            }
        }
        guard let block else { throw FormatError.corrupt("BlockGroup without Block") }
        var packets = try packets(from: block, keyframe: !hasReference, duration: duration, additional: additional)
        if let discardPadding, !packets.isEmpty { packets[packets.count - 1].discardPadding = discardPadding }
        return packets
    }

    /// `nil` defers to the SimpleBlock flag.
    private func packets(
        from block: [UInt8], keyframe: Bool?, duration: Int64? = nil, additional: Data? = nil
    ) throws -> [MediaPacket] {
        let (number, numberLength) = try EBML.readVint(block, at: 0)
        guard block.count >= numberLength + 3 else { throw FormatError.corrupt("short block") }
        guard let track = tracks.first(where: { $0.number == Int(number) }) else { return [] }
        let relative = Int64(Int16(bitPattern: UInt16(block[numberLength]) << 8 | UInt16(block[numberLength + 1])))
        let flags = block[numberLength + 2]
        let isKeyframe = keyframe ?? (flags & 0x80 != 0)
        let frames = try Self.unlace(block, from: numberLength + 3, lacing: flags >> 1 & 0x03)
        let timestamp = try Nanoseconds.scale(clusterTimestamp + relative, by: timestampScale, over: 1)
        let step = track.defaultDuration
        let prefix = strippedHeaders[track.number] ?? []
        return frames.enumerated().map { index, frame in
            MediaPacket(
                track: track.number, timestamp: timestamp + Int64(index) * (step ?? 0), duration: duration ?? step,
                isKeyframe: isKeyframe, payload: Data(prefix + frame), additional: additional
            )
        }
    }

    static func unlace(_ block: [UInt8], from start: Int, lacing: UInt8) throws -> [[UInt8]] {
        guard lacing != 0 else { return [Array(block[start...])] }
        guard start < block.count else { throw FormatError.corrupt("laced block without a count") }
        let count = Int(block[start]) + 1
        var offset = start + 1
        var sizes: [Int] = []
        switch lacing {
        case 1:
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard offset < block.count else { throw FormatError.corrupt("truncated Xiph lacing") }
                    let byte = Int(block[offset])
                    offset += 1
                    size += byte
                    if byte < 255 { break }
                }
                sizes.append(size)
            }
        case 3 where count > 1:
            let (first, firstLength) = try EBML.readVint(block, at: offset)
            offset += firstLength
            var current = Int(first)
            sizes.append(current)
            for _ in 0..<(count - 2) {
                let (raw, length) = try EBML.readVint(block, at: offset)
                offset += length
                let bias = (1 << (7 * length - 1)) - 1
                current += Int(raw) - bias
                guard (0...block.count).contains(current) else { throw FormatError.corrupt("laced size out of range") }
                sizes.append(current)
            }
        case 3:
            break
        default:
            let total = block.count - offset
            guard total % count == 0 else { throw FormatError.corrupt("fixed lacing does not divide evenly") }
            sizes = [Int](repeating: total / count, count: count - 1)
        }
        guard sizes.allSatisfy({ (0...block.count).contains($0) }) else {
            throw FormatError.corrupt("laced size out of range")
        }
        let used = sizes.reduce(0, +)
        guard offset + used <= block.count else { throw FormatError.corrupt("laced sizes exceed the block") }
        sizes.append(block.count - offset - used)
        var frames: [[UInt8]] = []
        for size in sizes {
            frames.append(Array(block[offset..<(offset + size)]))
            offset += size
        }
        return frames
    }
}
