import COpus
import Foundation

public struct MatroskaDemuxer: MediaDemuxer {
    /// Keeps laced timestamps far from overflow.
    private static let maximumFrameDuration = 10 * 60 * Nanoseconds.perSecond
    private static let maximumClusterTimestamp: Int64 = 1 << 62
    private static let hdrTransferCharacteristics: Set<Int> = [16, 18]
    private static let aacLongFrameSamples: Int64 = 1_024
    private static let aacShortFrameSamples: Int64 = 960
    private static let ac3FrameSamples: Int64 = 1_536
    private static let mpeg1Layer3Samples: Int64 = 1_152
    private static let mpeg2Layer3Samples: Int64 = 576
    private static let mpeg1SampleRates = [44_100, 48_000, 32_000]

    public private(set) var tracks: [MediaTrack] = []
    public private(set) var skippedStreams: Set<SkippedMediaStream> = []
    public private(set) var duration: Int64?
    public private(set) var docType = ""
    public private(set) var hasDescriptiveMetadata = false
    public private(set) var hasTrackMetadata = false
    public private(set) var disabledTrackNumbers: Set<Int> = []

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
        var firstCluster: Int64?
        while position < segmentEnd {
            try Task.checkCancellation()
            let element = try EBML.readHeader(file, at: position)
            if element.id == MatroskaID.cluster, firstCluster == nil { firstCluster = position }
            guard let size = element.size else {
                if element.id == MatroskaID.cluster {
                    skippedStreams.insert(.unknown)
                    position = try endOfUnknownCluster(startingAt: element.dataStart)
                    continue
                }
                throw FormatError.corrupt("unknown-size top-level element")
            }
            switch element.id {
            case MatroskaID.info where firstCluster == nil: try parseInfo(element)
            case MatroskaID.info:
                if try children(of: element).contains(where: { $0.id == MatroskaID.title }) {
                    hasDescriptiveMetadata = true
                }
            case MatroskaID.tracks where firstCluster == nil: try parseTracks(element)
            case MatroskaID.tracks: skippedStreams.insert(.unknown)
            case MatroskaID.tags: try parseTags(element)
            case MatroskaID.attachments: skippedStreams.insert(.attachment)
            case MatroskaID.chapters: skippedStreams.insert(.chapter)
            case MatroskaID.seekHead, MatroskaID.cues, MatroskaID.void, MatroskaID.crc32, MatroskaID.cluster:
                break
            default: skippedStreams.insert(.unknown)
            }
            position = element.dataStart + size
        }
        position = firstCluster ?? position
        guard !tracks.isEmpty else { throw FormatError.corrupt("no tracks before the first cluster") }
        for index in tracks.indices { tracks[index].timestampQuantum = timestampScale }
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

    private func endOfUnknownCluster(startingAt start: Int64) throws -> Int64 {
        var offset = start
        while offset < segmentEnd {
            try Task.checkCancellation()
            let element = try EBML.readHeader(file, at: offset)
            if MatroskaID.topLevel.contains(element.id) { return offset }
            guard let size = element.size, element.dataStart + size <= segmentEnd else {
                throw FormatError.corrupt("unknown-size cluster child")
            }
            offset = element.dataStart + size
        }
        return offset
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
            case MatroskaID.title: hasDescriptiveMetadata = true
            default: break
            }
        }
        guard timestampScale > 0 else { throw FormatError.corrupt("zero TimestampScale") }
        if let rawDuration {
            duration = try Nanoseconds.from(
                seconds: rawDuration * Double(timestampScale) / Double(Nanoseconds.perSecond))
        }
    }

    private mutating func parseTags(_ tags: EBML.Header) throws {
        for tag in try children(of: tags) where tag.id == MatroskaID.tag {
            let fields = try children(of: tag)
            guard fields.contains(where: { $0.id == MatroskaID.simpleTag }) else { continue }
            var targetsTrack = false
            for targets in fields where targets.id == MatroskaID.targets {
                if try children(of: targets).contains(where: { $0.id == MatroskaID.tagTrackUID }) {
                    targetsTrack = true
                }
            }
            if targetsTrack { hasTrackMetadata = true } else { hasDescriptiveMetadata = true }
        }
    }

    private mutating func parseTracks(_ list: EBML.Header) throws {
        for entry in try children(of: list) where entry.id == MatroskaID.trackEntry {
            var number = 0
            var type = 0
            var isEnabled = true
            var codecID = ""
            var codecPrivate: Data?
            var defaultDuration: Int64?
            var language: String?
            var languageBCP47: String?
            var width = 0
            var height = 0
            var displayGeometry = VideoDisplayGeometry()
            var hasDisplayGeometry = false
            var alpha = false
            var hasContainerHDR = false
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
                case MatroskaID.flagEnabled:
                    let flag = try integer(field)
                    guard flag == 0 || flag == 1 else {
                        throw FormatError.corrupt(
                            String(localized: "Matroska enabled flag out of range", comment: "Invalid track metadata"))
                    }
                    isEnabled = flag == 1
                case MatroskaID.codecID: codecID = EBML.string(try payload(field))
                case MatroskaID.codecPrivate: codecPrivate = Data(try payload(field))
                case MatroskaID.defaultDuration: defaultDuration = Int64(try integer(field))
                case MatroskaID.name: hasTrackMetadata = true
                case MatroskaID.language: language = EBML.string(try payload(field))
                case MatroskaID.languageBCP47: languageBCP47 = EBML.string(try payload(field))
                case MatroskaID.codecDelay: delay = Int64(try integer(field))
                case MatroskaID.seekPreRoll: preRoll = Int64(try integer(field))
                case MatroskaID.video:
                    for detail in try children(of: field) {
                        switch detail.id {
                        case MatroskaID.pixelWidth: width = try integer(detail)
                        case MatroskaID.pixelHeight: height = try integer(detail)
                        case MatroskaID.displayWidth:
                            displayGeometry.displayWidth = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.displayHeight:
                            displayGeometry.displayHeight = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.displayUnit:
                            displayGeometry.displayUnit = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.pixelCropTop:
                            displayGeometry.cropTop = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.pixelCropBottom:
                            displayGeometry.cropBottom = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.pixelCropLeft:
                            displayGeometry.cropLeft = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.pixelCropRight:
                            displayGeometry.cropRight = try integer(detail)
                            hasDisplayGeometry = true
                        case MatroskaID.alphaMode: alpha = try integer(detail) == 1
                        case MatroskaID.colour:
                            for property in try children(of: detail) {
                                switch property.id {
                                case MatroskaID.transferCharacteristics:
                                    if Self.hdrTransferCharacteristics.contains(try integer(property)) {
                                        hasContainerHDR = true
                                    }
                                case MatroskaID.masteringMetadata, MatroskaID.maxCLL, MatroskaID.maxFALL:
                                    hasContainerHDR = true
                                default: break
                                }
                            }
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
            if !isEnabled { disabledTrackNumbers.insert(number) }
            if let encodings { strippedHeaders[number] = try strippedHeader(encodings) }
            guard type == MatroskaValue.videoTrack || type == MatroskaValue.audioTrack else {
                skippedStreams.insert(.track(number))
                continue
            }
            if type == MatroskaValue.videoTrack {
                _ = try VideoDecoders.checkedFrameBytes(width: width, height: height)
                if hasDisplayGeometry { try displayGeometry.validate(width: width, height: height) }
            } else {
                try AudioMetadata.validate(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
            }
            if let defaultDuration, defaultDuration <= 0 || defaultDuration > Self.maximumFrameDuration {
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
            track.language = languageBCP47 ?? language
            track.hasAlpha = alpha
            track.hasContainerHDR = hasContainerHDR
            track.displayGeometry = hasDisplayGeometry ? displayGeometry : nil
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
        if let discardPadding, discardPadding != 0, !packets.isEmpty {
            if packets.count == 1 || packets[0].remainingLaceFrames > 0 {
                packets[0].discardPadding = discardPadding
            } else {
                var remaining = discardPadding.magnitude
                let indices = discardPadding < 0 ? Array(packets.indices) : Array(packets.indices.reversed())
                for index in indices where remaining > 0 {
                    guard let duration = packets[index].duration, duration > 0 else {
                        throw FormatError.corrupt("laced frame duration out of range")
                    }
                    let trimmed = min(remaining, UInt64(duration))
                    packets[index].discardPadding = discardPadding < 0 ? -Int64(trimmed) : Int64(trimmed)
                    remaining -= trimmed
                }
            }
        }
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
        let prefix = strippedHeaders[track.number] ?? []
        let payloads = frames.map { Data(prefix + $0) }
        if payloads.count == 1 {
            return [
                MediaPacket(
                    track: track.number, timestamp: timestamp, duration: duration ?? track.defaultDuration,
                    isKeyframe: isKeyframe, payload: payloads[0], additional: additional)
            ]
        }
        guard let frameDurations = try lacedDurations(payloads, track: track, blockDuration: duration) else {
            return payloads.enumerated().map { index, payload in
                MediaPacket(
                    track: track.number, timestamp: timestamp, isKeyframe: isKeyframe, payload: payload,
                    additional: additional, continuesPrevious: index > 0,
                    remainingLaceFrames: payloads.count - index - 1, laceDuration: index == 0 ? duration : nil)
            }
        }
        var offset: Int64 = 0
        return try zip(payloads, frameDurations).map { payload, frameDuration in
            let (presentation, timestampOverflow) = timestamp.addingReportingOverflow(offset)
            let (following, durationOverflow) = offset.addingReportingOverflow(frameDuration)
            let (_, endOverflow) = presentation.addingReportingOverflow(frameDuration)
            guard !timestampOverflow, !durationOverflow, !endOverflow else {
                throw FormatError.corrupt("laced timestamp out of range")
            }
            offset = following
            return MediaPacket(
                track: track.number, timestamp: presentation, duration: frameDuration,
                isKeyframe: isKeyframe, payload: payload, additional: additional)
        }
    }

    private func lacedDurations(_ payloads: [Data], track: MediaTrack, blockDuration: Int64?) throws -> [Int64]? {
        if let defaultDuration = track.defaultDuration {
            return [Int64](repeating: defaultDuration, count: payloads.count)
        }
        if case .audio(let sampleRate, let channels) = track.kind {
            var sampleCounts: [Int64] = []
            var timingRate = sampleRate
            switch track.codec {
            case .pcm(let bits, _, _):
                guard bits.isMultiple(of: 8) else { throw FormatError.corrupt("unaligned PCM sample depth") }
                let bytesPerFrame = channels * (bits / 8)
                for payload in payloads {
                    guard payload.count.isMultiple(of: bytesPerFrame) else {
                        throw FormatError.corrupt("unaligned PCM packet")
                    }
                    sampleCounts.append(Int64(payload.count / bytesPerFrame))
                }
            case .opus:
                timingRate = Double(OpusAudioEncoder.sampleRate)
                sampleCounts = payloads.compactMap { payload in
                    guard !payload.isEmpty, let length = Int32(exactly: payload.count) else {
                        return nil
                    }
                    let samples = payload.withUnsafeBytes { bytes in
                        bytes.bindMemory(to: UInt8.self).baseAddress.map {
                            opus_packet_get_nb_samples($0, length, Int32(OpusAudioEncoder.sampleRate))
                        }
                    }
                    guard let samples, samples > 0 else { return nil }
                    return Int64(samples)
                }
            case .aac:
                if let codecPrivate = track.codecPrivate, codecPrivate.count == 2 {
                    let config = [UInt8](codecPrivate)
                    let frequencyIndex = Int(config[0] & 7) << 1 | Int(config[1] >> 7)
                    let channelConfiguration = Int(config[1] >> 3 & 15)
                    if config[0] >> 3 == 2, config[1] & 0x03 == 0,
                        frequencyIndex < FLV.aacSampleRates.count, (1...7).contains(channelConfiguration)
                    {
                        let configured = try FLV.aacFormat(config)
                        if configured.sampleRate == sampleRate, configured.channels == channels {
                            let samples =
                                config[1] & 0x04 == 0 ? Self.aacLongFrameSamples : Self.aacShortFrameSamples
                            sampleCounts = [Int64](repeating: samples, count: payloads.count)
                        }
                    }
                }
            case .ac3:
                sampleCounts = [Int64](repeating: Self.ac3FrameSamples, count: payloads.count)
            case .mp3:
                sampleCounts = payloads.compactMap { Self.mp3FrameSamples($0, sampleRate: sampleRate) }
            default:
                break
            }
            if sampleCounts.count == payloads.count {
                var elapsedSamples: Int64 = 0
                var previousOffset: Int64 = 0
                return try sampleCounts.map { samples in
                    let (following, overflow) = elapsedSamples.addingReportingOverflow(samples)
                    guard !overflow else { throw FormatError.corrupt("laced sample count out of range") }
                    elapsedSamples = following
                    let offset = try Nanoseconds.from(seconds: Double(elapsedSamples) / timingRate)
                    let frameDuration = offset - previousOffset
                    guard frameDuration > 0 else { throw FormatError.corrupt("laced frame duration out of range") }
                    previousOffset = offset
                    return frameDuration
                }
            }
        }
        if let blockDuration, payloads.allSatisfy({ $0.count == payloads[0].count }) {
            var previousOffset: Int64 = 0
            return try payloads.indices.map { index in
                let offset = try Nanoseconds.scale(Int64(index + 1), by: blockDuration, over: Int64(payloads.count))
                let frameDuration = offset - previousOffset
                guard frameDuration > 0 else { throw FormatError.corrupt("laced frame duration out of range") }
                previousOffset = offset
                return frameDuration
            }
        }
        return nil
    }

    private static func mp3FrameSamples(_ payload: Data, sampleRate: Double) -> Int64? {
        guard payload.count >= 4, payload[0] == 0xFF, payload[1] & 0xE0 == 0xE0,
            payload[1] & 0x06 == 0x02,
            ![0, 15].contains(Int(payload[2] >> 4)), payload[2] & 0x0C != 0x0C
        else { return nil }
        let version = payload[1] & 0x18
        let divisor: Int
        switch version {
        case 0x18: divisor = 1
        case 0x10: divisor = 2
        case 0x00: divisor = 4
        default: return nil
        }
        let rate = Self.mpeg1SampleRates[Int(payload[2] >> 2 & 0x03)] / divisor
        guard sampleRate == Double(rate) else { return nil }
        return version == 0x18 ? Self.mpeg1Layer3Samples : Self.mpeg2Layer3Samples
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
