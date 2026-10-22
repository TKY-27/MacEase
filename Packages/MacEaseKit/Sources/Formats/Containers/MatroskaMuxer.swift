import Foundation

/// Matroska or WebM, with Cues and SeekHead.
public struct MatroskaMuxer: MediaMuxer {
    private static let timestampScale: Int64 = 1_000_000
    private static let clusterSpan: Int64 = 5 * Nanoseconds.perSecond
    /// Relative block timestamps are 16-bit milliseconds.
    private static let maximumRelative: Int64 = 32_000 * Nanoseconds.perMillisecond
    private static let clusterBytes = 5 << 20
    private static let maximumLaceFrames = 256
    private static let maximumPendingLaceBytes = 250_000_000
    private static let invalidLaceMessage = String(
        localized: "Matroska lace cannot be represented", comment: "Lace metadata cannot fit one block")
    private static let seekHeadReserve = 96
    private static let sizeWidth = 8

    private let file: PatchableFile
    private let tracks: [MediaTrack]
    private let webm: Bool
    private let videoTrack: Int?
    private var segmentDataStart: Int64 = 0
    private var segmentSizeOffset: Int64 = 0
    private var seekHeadOffset: Int64 = 0
    private var durationOffset: Int64 = 0
    private var infoPosition: Int64 = 0
    private var tracksPosition: Int64 = 0
    private var pending: [[MediaPacket]] = []
    private var lastPendingBlockByTrack: [Int: Int] = [:]
    private var incompleteLaceCount = 0
    private var pendingBytes = 0
    private var cues: [(time: Int64, position: Int64)] = []
    private var lastEnd: Int64 = 0

    public init(url: URL, tracks: [MediaTrack], webm: Bool) throws {
        guard tracks.allSatisfy({ $0.number > 0 }), Set(tracks.map(\.number)).count == tracks.count else {
            throw FormatError.encoderFailure("Matroska track numbers must be unique and positive")
        }
        for track in tracks {
            switch track.kind {
            case .video(let width, let height):
                guard width >= 0, height >= 0 else {
                    throw FormatError.corrupt(
                        String(localized: "Matroska video dimensions out of range", comment: "Invalid track metadata"))
                }
                if let geometry = track.displayGeometry { try geometry.validate(width: width, height: height) }
            case .audio(let sampleRate, let channels):
                let bitDepth: Int?
                if case .pcm(let bits, _, _) = track.codec { bitDepth = bits } else { bitDepth = nil }
                try AudioMetadata.validate(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
            }
            guard track.defaultDuration.map({ $0 >= 0 }) ?? true else {
                throw FormatError.corrupt(
                    String(localized: "Matroska duration out of range", comment: "Invalid track metadata"))
            }
        }
        if webm {
            for track in tracks where !MatroskaCodec.webmCodecs.contains(try MatroskaCodec.id(for: track.codec)) {
                throw FormatError.unsupported("\(track.codec.displayName) in WebM")
            }
        }
        file = try PatchableFile(url: url)
        self.tracks = tracks
        self.webm = webm
        videoTrack = tracks.first(where: \.isVideo)?.number
        try writeHeader()
    }

    private mutating func writeHeader() throws {
        let docType = webm ? "webm" : "matroska"
        try file.append(
            EBML.element(
                MatroskaID.ebml,
                EBML.element(MatroskaID.ebmlVersion, unsigned: 1)
                    + EBML.element(MatroskaID.ebmlReadVersion, unsigned: 1)
                    + EBML.element(MatroskaID.ebmlMaxIDLength, unsigned: 4)
                    + EBML.element(MatroskaID.ebmlMaxSizeLength, unsigned: 8)
                    + EBML.element(MatroskaID.docType, string: docType)
                    + EBML.element(MatroskaID.docTypeVersion, unsigned: 4)
                    + EBML.element(MatroskaID.docTypeReadVersion, unsigned: 2)
            )
        )
        try file.append(EBML.encodeID(MatroskaID.segment))
        segmentSizeOffset = file.position
        try file.append(EBML.encodeSize(0, width: Self.sizeWidth))
        segmentDataStart = file.position
        seekHeadOffset = file.position
        try file.append(voidElement(totalSize: Self.seekHeadReserve))

        infoPosition = file.position - segmentDataStart
        let durationElement = EBML.element(MatroskaID.duration, float: 0)
        let infoBody =
            EBML.element(MatroskaID.timestampScale, unsigned: UInt64(Self.timestampScale))
            + EBML.element(MatroskaID.muxingApp, string: "MacEase")
            + EBML.element(MatroskaID.writingApp, string: "MacEase")
        let info = EBML.element(MatroskaID.info, infoBody + durationElement)
        durationOffset = file.position + Int64(info.count - durationElement.count) + 3
        try file.append(info)

        tracksPosition = file.position - segmentDataStart
        try file.append(EBML.element(MatroskaID.tracks, try tracks.flatMap(trackEntry)))
    }

    private func trackEntry(_ track: MediaTrack) throws -> [UInt8] {
        var body =
            EBML.element(MatroskaID.trackNumber, unsigned: UInt64(track.number))
            + EBML.element(MatroskaID.trackUID, unsigned: UInt64(track.number) &* 0x9E37_79B9 | 1)
            + EBML.element(MatroskaID.flagLacing, unsigned: 1)
            + EBML.element(MatroskaID.codecID, string: try MatroskaCodec.id(for: track.codec))
        switch track.kind {
        case .video(let width, let height):
            body += EBML.element(MatroskaID.trackType, unsigned: UInt64(MatroskaValue.videoTrack))
            var video =
                EBML.element(MatroskaID.pixelWidth, unsigned: UInt64(width))
                + EBML.element(MatroskaID.pixelHeight, unsigned: UInt64(height))
            if let geometry = track.displayGeometry {
                if let displayWidth = geometry.displayWidth {
                    video += EBML.element(MatroskaID.displayWidth, unsigned: UInt64(displayWidth))
                }
                if let displayHeight = geometry.displayHeight {
                    video += EBML.element(MatroskaID.displayHeight, unsigned: UInt64(displayHeight))
                }
                video += EBML.element(MatroskaID.displayUnit, unsigned: UInt64(geometry.displayUnit))
                video += EBML.element(MatroskaID.pixelCropTop, unsigned: UInt64(geometry.cropTop))
                video += EBML.element(MatroskaID.pixelCropBottom, unsigned: UInt64(geometry.cropBottom))
                video += EBML.element(MatroskaID.pixelCropLeft, unsigned: UInt64(geometry.cropLeft))
                video += EBML.element(MatroskaID.pixelCropRight, unsigned: UInt64(geometry.cropRight))
            }
            if track.hasAlpha {
                video += EBML.element(MatroskaID.alphaMode, unsigned: 1)
                body += EBML.element(MatroskaID.maxBlockAdditionID, unsigned: MatroskaValue.alphaAdditionID)
            }
            body += EBML.element(MatroskaID.video, video)
        case .audio(let sampleRate, let channels):
            body += EBML.element(MatroskaID.trackType, unsigned: UInt64(MatroskaValue.audioTrack))
            var audio =
                EBML.element(MatroskaID.samplingFrequency, float: sampleRate)
                + EBML.element(MatroskaID.channels, unsigned: UInt64(channels))
            if case .pcm(let bits, _, _) = track.codec {
                audio += EBML.element(MatroskaID.bitDepth, unsigned: UInt64(bits))
            }
            body += EBML.element(MatroskaID.audio, audio)
        }
        if let codecPrivate = track.codecPrivate {
            body += EBML.element(MatroskaID.codecPrivate, [UInt8](codecPrivate))
        }
        if let defaultDuration = track.defaultDuration {
            body += EBML.element(MatroskaID.defaultDuration, unsigned: UInt64(defaultDuration))
        }
        if track.codecDelay > 0 { body += EBML.element(MatroskaID.codecDelay, unsigned: UInt64(track.codecDelay)) }
        if track.seekPreRoll > 0 { body += EBML.element(MatroskaID.seekPreRoll, unsigned: UInt64(track.seekPreRoll)) }
        if let language = track.language { body += EBML.element(MatroskaID.language, string: language) }
        return EBML.element(MatroskaID.trackEntry, body)
    }

    private func voidElement(totalSize: Int) -> [UInt8] {
        EBML.encodeID(MatroskaID.void) + EBML.encodeSize(Int64(totalSize - 1 - Self.sizeWidth), width: Self.sizeWidth)
            + [UInt8](repeating: 0, count: totalSize - 1 - Self.sizeWidth)
    }

    public mutating func write(_ packet: MediaPacket) throws {
        guard tracks.contains(where: { $0.number == packet.track }) else {
            throw FormatError.encoderFailure("packet for unknown track \(packet.track)")
        }
        guard packet.remainingLaceFrames >= 0, packet.remainingLaceFrames < Self.maximumLaceFrames else {
            throw FormatError.encoderFailure(Self.invalidLaceMessage)
        }
        if packet.continuesPrevious {
            guard let blockIndex = lastPendingBlockByTrack[packet.track] else {
                throw FormatError.encoderFailure(Self.invalidLaceMessage)
            }
            let block = pending[blockIndex]
            guard
                block.count < Self.maximumLaceFrames,
                let previous = block.last, previous.remainingLaceFrames > 0,
                packet.remainingLaceFrames == previous.remainingLaceFrames - 1,
                packet.timestamp == block[0].timestamp, packet.duration == nil, block[0].duration == nil,
                packet.isKeyframe == block[0].isKeyframe, packet.additional == block[0].additional,
                packet.laceDuration == nil, previous.discardPadding == nil
            else {
                throw FormatError.encoderFailure(Self.invalidLaceMessage)
            }
        } else {
            if let blockIndex = lastPendingBlockByTrack[packet.track],
                pending[blockIndex].last?.remainingLaceFrames != 0
            {
                throw FormatError.encoderFailure(Self.invalidLaceMessage)
            }
            guard
                packet.remainingLaceFrames == 0 || packet.duration == nil,
                packet.remainingLaceFrames > 0 || packet.laceDuration == nil
            else {
                throw FormatError.encoderFailure(Self.invalidLaceMessage)
            }
        }
        guard packet.laceDuration.map({ $0 >= 0 }) ?? true else {
            throw FormatError.encoderFailure(Self.invalidLaceMessage)
        }
        let (end, endOverflow) = packet.timestamp.addingReportingOverflow(packet.laceDuration ?? packet.duration ?? 0)
        guard !endOverflow else {
            throw FormatError.encoderFailure(
                String(localized: "Matroska timestamp out of range", comment: "Unrepresentable output timeline"))
        }
        if let first = pending.first?.first {
            let (span, spanOverflow) = packet.timestamp.subtractingReportingOverflow(first.timestamp)
            guard !spanOverflow else {
                throw FormatError.encoderFailure(
                    String(localized: "Matroska timestamp out of range", comment: "Unrepresentable output timeline"))
            }
            let startsGroup = packet.track == videoTrack ? packet.isKeyframe : videoTrack == nil
            let full = span >= Self.maximumRelative || pendingBytes >= Self.clusterBytes
            // A frame group cannot cross cluster boundaries.
            if !packet.continuesPrevious && incompleteLaceCount == 0
                && (full || (startsGroup && span >= Self.clusterSpan))
            {
                try flushCluster()
            }
            if let first = pending.first?.first {
                let base = max(Self.ticks(first.timestamp), 0)
                let (relative, relativeOverflow) = Self.ticks(packet.timestamp).subtractingReportingOverflow(base)
                guard !relativeOverflow, Int16(exactly: relative) != nil else {
                    throw FormatError.encoderFailure(Self.invalidLaceMessage)
                }
            }
        }
        let (newPendingBytes, byteOverflow) = pendingBytes.addingReportingOverflow(packet.payload.count)
        guard !byteOverflow else {
            throw FormatError.corrupt(
                String(localized: "Matroska cluster too large", comment: "Invalid packet payload"))
        }
        if (incompleteLaceCount > 0 || packet.remainingLaceFrames > 0)
            && newPendingBytes > Self.maximumPendingLaceBytes
        {
            throw FormatError.corrupt(
                String(localized: "Matroska cluster too large", comment: "Invalid packet payload"))
        }
        if packet.continuesPrevious, let blockIndex = lastPendingBlockByTrack[packet.track] {
            pending[blockIndex].append(packet)
            if packet.remainingLaceFrames == 0 { incompleteLaceCount -= 1 }
        } else {
            lastPendingBlockByTrack[packet.track] = pending.count
            pending.append([packet])
            if packet.remainingLaceFrames > 0 { incompleteLaceCount += 1 }
        }
        pendingBytes = newPendingBytes
        lastEnd = max(lastEnd, end)
    }

    private static func ticks(_ nanoseconds: Int64) -> Int64 {
        let half = timestampScale / 2
        let (whole, remainder) = nanoseconds.quotientAndRemainder(dividingBy: timestampScale)
        if remainder >= half { return whole + 1 }
        if remainder <= -half { return whole - 1 }
        return whole
    }

    private mutating func flushCluster() throws {
        guard let first = pending.first?.first else { return }
        let base = max(Self.ticks(first.timestamp), 0)
        var body = EBML.element(MatroskaID.clusterTimestamp, unsigned: UInt64(base))
        for frames in pending {
            let packet = frames[0]
            let (relativeTicks, overflow) = Self.ticks(packet.timestamp).subtractingReportingOverflow(base)
            guard !overflow, let relative = Int16(exactly: relativeTicks) else {
                throw FormatError.encoderFailure("packet outside its cluster's time range")
            }
            var block = EBML.encodeSize(Int64(packet.track))
            block += [UInt8(truncatingIfNeeded: relative >> 8), UInt8(truncatingIfNeeded: relative)]
            let lacing = frames.count > 1
            let frameBytes: [UInt8]
            if lacing {
                var bytes: [UInt8] = [UInt8(frames.count - 1)]
                for frame in frames.dropLast() {
                    bytes += [UInt8](repeating: 255, count: frame.payload.count / 255)
                    bytes.append(UInt8(frame.payload.count % 255))
                }
                for frame in frames { bytes += frame.payload }
                frameBytes = bytes
            } else {
                frameBytes = [UInt8](packet.payload)
            }
            if packet.additional != nil || frames.last?.discardPadding != nil || packet.laceDuration != nil {
                block.append(lacing ? 0x02 : 0)
                block += frameBytes
                var group = EBML.element(MatroskaID.block, block)
                if let additional = packet.additional {
                    let more =
                        EBML.element(MatroskaID.blockAddID, unsigned: MatroskaValue.alphaAdditionID)
                        + EBML.element(MatroskaID.blockAdditional, [UInt8](additional))
                    group += EBML.element(MatroskaID.blockAdditions, EBML.element(MatroskaID.blockMore, more))
                }
                if let discardPadding = frames.last?.discardPadding {
                    group += EBML.element(MatroskaID.discardPadding, signed: discardPadding)
                }
                if let laceDuration = packet.laceDuration {
                    group += EBML.element(MatroskaID.blockDuration, unsigned: UInt64(Self.ticks(laceDuration)))
                }
                if !packet.isKeyframe { group += EBML.element(MatroskaID.referenceBlock, unsigned: 0) }
                body += EBML.element(MatroskaID.blockGroup, group)
            } else {
                block.append((packet.isKeyframe ? 0x80 : 0) | (lacing ? 0x02 : 0))
                block += frameBytes
                body += EBML.element(MatroskaID.simpleBlock, block)
            }
        }
        let cueWanted = videoTrack == nil || (first.track == videoTrack && first.isKeyframe)
        if cueWanted { cues.append((base, file.position - segmentDataStart)) }
        try file.append(EBML.element(MatroskaID.cluster, body))
        pending = []
        lastPendingBlockByTrack = [:]
        incompleteLaceCount = 0
        pendingBytes = 0
    }

    public mutating func finish() throws {
        guard incompleteLaceCount == 0 else { throw FormatError.encoderFailure(Self.invalidLaceMessage) }
        try flushCluster()
        let cuesPosition = file.position - segmentDataStart
        let cueTrack = UInt64(videoTrack ?? tracks.first?.number ?? 1)
        let points = cues.flatMap { cue in
            EBML.element(
                MatroskaID.cuePoint,
                EBML.element(MatroskaID.cueTime, unsigned: UInt64(cue.time))
                    + EBML.element(
                        MatroskaID.cueTrackPositions,
                        EBML.element(MatroskaID.cueTrack, unsigned: cueTrack)
                            + EBML.element(MatroskaID.cueClusterPosition, unsigned: UInt64(cue.position))
                    )
            )
        }
        if !points.isEmpty { try file.append(EBML.element(MatroskaID.cues, points)) }
        let segmentSize = file.position - segmentDataStart
        try file.patch(EBML.encodeSize(segmentSize, width: Self.sizeWidth), at: segmentSizeOffset)
        let milliseconds = Double(lastEnd) / Double(Self.timestampScale)
        var duration = Data()
        duration.appendBigEndian(milliseconds.bitPattern)
        try file.patch(duration, at: durationOffset)
        var seeks = [(MatroskaID.info, infoPosition), (MatroskaID.tracks, tracksPosition)]
        if !points.isEmpty { seeks.append((MatroskaID.cues, cuesPosition)) }
        let seekHead = EBML.element(
            MatroskaID.seekHead,
            seeks.flatMap { id, position in
                EBML.element(
                    MatroskaID.seek,
                    EBML.element(MatroskaID.seekID, EBML.encodeID(id))
                        + EBML.element(MatroskaID.seekPosition, unsigned: UInt64(position))
                )
            }
        )
        try file.patch(seekHead + voidElement(totalSize: Self.seekHeadReserve - seekHead.count), at: seekHeadOffset)
        try file.close()
    }
}
