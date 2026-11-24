import AVFoundation
import CoreMedia
import CoreVideo
import Formats
import Foundation

public enum VideoSegmentReverser {
    public static let maximumSegmentSeconds = 60.0

    private static let intermediateQuality = 0.95
    private static let intermediateKeyframeInterval = Nanoseconds.perSecond
    private static let gopMemoryBudgetBytes = 256 << 20
    private static let minimumBufferedFrames = 8
    private static let sdrBytesPerPixel = 4
    private static let hdrBytesPerPixel = 8
    private static let audioChunkFrames: AVAudioFrameCount = 4_096
    private static let audioPrepProgressShare = 0.15
    private static let readinessPoll = Duration.milliseconds(2)
    private static let boundaryToleranceSeconds = 1e-6

    public static func reverse(
        segmentID: UUID,
        in edit: VideoEdit,
        primaryURL: URL,
        staging: StagingArea,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoEdit {
        try Task.checkCancellation()
        guard var segments = edit.segments,
            let segmentIndex = segments.firstIndex(where: { $0.id == segmentID })
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        var segment = segments[segmentIndex]
        guard !segment.isFreeze, !segment.isReversed else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let segmentSeconds = segment.end - segment.start
        guard segmentSeconds <= maximumSegmentSeconds else {
            throw EngineError.invalidInput(.tooLong(limitSeconds: maximumSegmentSeconds))
        }

        var sources: [VideoEditSource]
        if let existing = edit.sources, !existing.isEmpty {
            guard existing.indices.contains(segment.sourceIndex) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            for source in existing { try source.stamp.validate(source.url) }
            sources = existing
        } else {
            guard segment.sourceIndex == 0 else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            try edit.sourceStamp?.validate(primaryURL)
            let primaryInput = try await MediaInput.open(primaryURL)
            let primaryDuration = Double(primaryInput.duration) / Double(Nanoseconds.perSecond)
            let primaryStamp = try edit.sourceStamp ?? MediaSourceStamp(url: primaryURL)
            sources = [VideoEditSource(url: primaryURL, duration: primaryDuration, stamp: primaryStamp)]
        }

        let originSource = sources[segment.sourceIndex]
        let input = try await MediaInput.open(originSource.url)
        try input.requireSingleTracksForReplacement()
        guard input.video != nil else { throw EngineError.decodeFailed("no video track") }
        let rangeStart = try Nanoseconds.from(seconds: segment.start)
        let rangeEnd = try Nanoseconds.from(seconds: segment.end)
        guard rangeStart >= 0, rangeStart < rangeEnd, rangeEnd <= input.duration else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }

        let directory = try staging.makeDirectory(for: primaryURL)
        let outputURL = directory.appending(path: "reversed-\(UUID().uuidString).mov")
        do {
            try await renderReversed(
                input: input, range: rangeStart..<rangeEnd, to: outputURL, stagingDirectory: directory,
                progress: progress)
            try Task.checkCancellation()
            try originSource.stamp.validate(originSource.url)
            let rendered = try await MediaInput.open(outputURL)
            guard rendered.video != nil, rendered.duration > 0 else {
                throw EngineError.encodeFailed("reversed clip has no video")
            }
            let renderedDuration = Double(rendered.duration) / Double(Nanoseconds.perSecond)
            let reversedSource = VideoEditSource(
                url: outputURL, duration: renderedDuration, stamp: try MediaSourceStamp(url: outputURL))
            let newSourceIndex = sources.count
            sources.append(reversedSource)
            let origin = ReversedSegmentOrigin(
                sourceIndex: segment.sourceIndex, start: segment.start, end: segment.end)
            segment.sourceIndex = newSourceIndex
            segment.start = 0
            segment.end = renderedDuration
            segment.reversedOrigin = origin
            segments[segmentIndex] = segment
            var updated = edit
            updated.sources = sources
            updated.segments = segments
            return updated
        } catch {
            staging.remove(directory)
            throw error
        }
    }

    public static func unreverse(
        segmentID: UUID,
        in edit: VideoEdit,
        staging: StagingArea? = nil
    ) throws -> VideoEdit {
        guard var segments = edit.segments,
            let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
            let origin = segments[segmentIndex].reversedOrigin
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        var segment = segments[segmentIndex]
        let reversedDuration = edit.sources.flatMap {
            $0.indices.contains(segment.sourceIndex) ? $0[segment.sourceIndex].duration : nil
        }
        let restoredRange = restoredOriginRange(
            segmentStart: segment.start, segmentEnd: segment.end,
            reversedDuration: reversedDuration, origin: origin)
        segment.sourceIndex = origin.sourceIndex
        segment.start = restoredRange.lowerBound
        segment.end = restoredRange.upperBound
        segment.reversedOrigin = nil
        segments[segmentIndex] = segment

        var updated = edit
        updated.segments = segments
        if let staging {
            return removeUnusedStagedSources(in: updated, staging: staging)
        }
        return updated
    }

    public static func removeUnusedStagedSources(in edit: VideoEdit, staging: StagingArea) -> VideoEdit {
        guard var sources = edit.sources, sources.count > 1, var segments = edit.segments else { return edit }
        var overlays = edit.overlays
        var index = sources.count - 1
        while index > 0 {
            let directory = sources[index].url.deletingLastPathComponent()
            let referenced = segments.contains {
                $0.sourceIndex == index || $0.reversedOrigin?.sourceIndex == index
            }
            if !referenced, StagingArea.isItemReplacementDirectory(directory) {
                sources.remove(at: index)
                for segIndex in segments.indices {
                    if segments[segIndex].sourceIndex > index { segments[segIndex].sourceIndex -= 1 }
                    if let originIndex = segments[segIndex].reversedOrigin?.sourceIndex, originIndex > index {
                        segments[segIndex].reversedOrigin?.sourceIndex = originIndex - 1
                    }
                }
                overlays.removeAll { $0.sourceIndex == index }
                for overlayIndex in overlays.indices where overlays[overlayIndex].sourceIndex > index {
                    overlays[overlayIndex].sourceIndex -= 1
                }
                staging.remove(directory)
            }
            index -= 1
        }
        var updated = edit
        updated.sources = sources
        updated.segments = segments
        updated.overlays = overlays
        return updated
    }

    public static func cleanupStagedSource(_ url: URL, in staging: StagingArea) {
        let directory = url.deletingLastPathComponent()
        if StagingArea.isItemReplacementDirectory(directory) {
            staging.remove(directory)
        }
    }

    private static func restoredOriginRange(
        segmentStart: Double, segmentEnd: Double, reversedDuration: Double?, origin: ReversedSegmentOrigin
    ) -> Range<Double> {
        guard let reversedDuration, reversedDuration > 0 else { return origin.start..<origin.end }
        let untrimmed =
            segmentStart <= boundaryToleranceSeconds
            && abs(segmentEnd - reversedDuration) <= boundaryToleranceSeconds
        if untrimmed { return origin.start..<origin.end }
        let scale = (origin.end - origin.start) / reversedDuration
        let lower = max(origin.start, min(origin.end, origin.end - segmentEnd * scale))
        let upper = max(lower, min(origin.end, origin.end - segmentStart * scale))
        return upper > lower ? lower..<upper : origin.start..<origin.end
    }

    private static func renderReversed(
        input: MediaInput, range: Range<Int64>, to outputURL: URL, stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let videoTrack = input.video else { throw EngineError.decodeFailed("no video track") }
        let hdr = try await VideoProperties.hdrConfiguration(input)
        let hasAlpha = videoTrack.hasAlpha
        if hdr != nil, hasAlpha { throw EngineError.hdrConversionUnsupported }
        if hasAlpha, videoTrack.codec != .vp9 {
            guard case .asset = input.backend else { throw EngineError.videoAlphaUnsupported }
        }

        let preservesRawGeometry = input.codedSize == input.codedSize.evened() && videoTrack.displayGeometry == nil
        let outputSize = preservesRawGeometry ? input.codedSize : input.displaySize.evened()
        let outputTransform = preservesRawGeometry ? input.transform : .identity
        let bytesPerPixel = hdr != nil ? hdrBytesPerPixel : sdrBytesPerPixel
        var workingBudget = FrameMemoryBudget()
        try workingBudget.reserve(width: outputSize.width, height: outputSize.height, bytesPerPixel: bytesPerPixel)
        let frameBytes = max(1, outputSize.width * outputSize.height * bytesPerPixel)
        let maxBufferedFrames = max(minimumBufferedFrames, gopMemoryBudgetBytes / frameBytes)

        let processor: FrameProcessor?
        if preservesRawGeometry {
            processor = nil
        } else {
            var frameEdit = FrameEdit(displayOrientation: try input.displayOrientation, size: outputSize)
            frameEdit.preservesAlpha = hasAlpha
            processor = try FrameProcessor(
                source: input.codedSize, edit: frameEdit, hdr: hdr?.configuration, display: videoTrack.displayGeometry)
        }

        let (keyframes, frameTimes) = try await scanVideoIndex(input: input, videoTrack: videoTrack, range: range)
        guard !frameTimes.isEmpty else { throw EngineError.decodeFailed("no frame in selected segment") }
        let chunks = makeDecodeChunks(
            keyframes: keyframes, frameTimes: frameTimes, maxBufferedFrames: maxBufferedFrames)

        var encoding = VideoEncoding(
            codec: .hevc, width: outputSize.width, height: outputSize.height,
            frameDuration: input.frameDuration, bitrate: nil)
        encoding.quality = intermediateQuality
        encoding.keyframeInterval = intermediateKeyframeInterval
        encoding.alpha = hasAlpha
        encoding.hdr = hdr?.configuration
        // Monotonic PTS equals DTS without edit lists.
        encoding.allowsFrameReordering = false

        var audioTempURL: URL?
        defer {
            if let audioTempURL { try? FileManager.default.removeItem(at: audioTempURL) }
        }
        let hasAudio = input.audio != nil
        var stages: [any StreamStage] = []
        let videoStage = try ReversedVideoStage(
            input: input, videoTrack: videoTrack, range: range, frameTimes: frameTimes, chunks: chunks,
            encoding: encoding, hdr: hdr?.configuration, processor: processor)
        stages.append(videoStage)

        if let audioTrack = input.audio {
            let tempCAF = stagingDirectory.appending(path: "reverse-audio-\(UUID().uuidString).caf")
            audioTempURL = tempCAF
            let prepared = try await prepareForwardAudio(
                input: input, track: audioTrack, range: range, to: tempCAF)
            if prepared.totalFrames > 0 {
                let audioStage = try ReversedAudioStage(
                    url: tempCAF, totalFrames: prepared.totalFrames,
                    sampleRate: prepared.sampleRate, channels: prepared.channels, trackNumber: 2)
                stages.append(audioStage)
            }
            progress(audioPrepProgressShare)
        }

        var primed: [[MediaPacket]] = []
        for stage in stages {
            var packets: [MediaPacket] = []
            while packets.isEmpty, stage.nextTime != nil { packets = try await stage.pull() }
            primed.append(packets)
        }
        let tracks = try stages.map { stage in
            guard let output = stage.output else { throw EngineError.encodeFailed("stream produced nothing") }
            return output
        }

        let totalDuration = max(Double(range.upperBound - range.lowerBound), 1)
        let baseProgress = hasAudio ? audioPrepProgressShare : 0
        let streamWeight = 1 - baseProgress

        let sink = try AssetWriterSink(
            url: outputURL, fileType: .mov, tracks: tracks, transform: outputTransform)
        var queues = primed
        do {
            while let index = try await earliestReadyStage(stages, queues, sink: sink) {
                try Task.checkCancellation()
                guard !queues[index].isEmpty else {
                    queues[index] = try await stages[index].pull()
                    continue
                }
                let packet = queues[index].removeFirst()
                try await sink.write(packet)
                let fraction = min(max(Double(packet.timestamp) / totalDuration, 0), 1)
                progress(baseProgress + streamWeight * fraction)
            }
            try await sink.finish()
            progress(1)
        } catch {
            sink.cancel()
            throw error
        }
    }

    private static func earliestReadyStage(
        _ stages: [any StreamStage], _ queues: [[MediaPacket]], sink: AssetWriterSink
    ) async throws -> Int? {
        while true {
            try sink.checkHealth()
            try Task.checkCancellation()
            var candidates: [(index: Int, time: Int64)] = []
            for index in stages.indices {
                guard let time = queues[index].first?.timestamp ?? stages[index].nextTime else {
                    stages[index].output.map { sink.endTrack($0.track.number) }
                    continue
                }
                candidates.append((index, time))
            }
            guard !candidates.isEmpty else { return nil }
            let ordered = candidates.sorted { $0.time < $1.time }
            if let ready = ordered.first(where: { sink.accepts(track: stages[$0.index].output?.track.number ?? 0) }) {
                return ready.index
            }
            try await Task.sleep(for: readinessPoll)
        }
    }

    private static func scanVideoIndex(
        input: MediaInput, videoTrack: MediaTrack, range: Range<Int64>
    ) async throws -> (keyframes: [Int64], frameTimes: [Int64]) {
        switch input.backend {
        case .asset(_, let assetTrack?, _):
            return try scanAssetIndex(track: assetTrack, range: range)
        default:
            return try scanContainerIndex(input: input, track: videoTrack, range: range)
        }
    }

    private static func scanAssetIndex(
        track: AVAssetTrack, range: Range<Int64>
    ) throws -> (keyframes: [Int64], frameTimes: [Int64]) {
        let firstKeyframe = try AssetKeyframes.time(atOrBefore: range.lowerBound, in: track)
        let startCM = CMTime(value: firstKeyframe, timescale: SampleBuffers.nanosecondScale)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: startCM) else {
            throw EngineError.decodeFailed("track has no sample index")
        }
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            guard cursor.stepInDecodeOrder(byCount: -1) == -1 else { break }
        }
        var keyframes: [Int64] = []
        var allCandidates: [Int64] = []
        while true {
            try Task.checkCancellation()
            let pts = SampleBuffers.nanoseconds(cursor.presentationTimeStamp)
            let isSync = cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue
            if isSync, pts >= range.upperBound { break }
            if isSync { keyframes.append(pts) }
            if pts < range.upperBound { allCandidates.append(pts) }
            guard cursor.stepInDecodeOrder(byCount: 1) == 1 else { break }
        }
        return normalizeVideoIndex(keyframes: keyframes, candidates: allCandidates, range: range)
    }

    private static func scanContainerIndex(
        input: MediaInput, track: MediaTrack, range: Range<Int64>
    ) throws -> (keyframes: [Int64], frameTimes: [Int64]) {
        guard var demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
        var allKeyframes: [Int64] = []
        var candidates: [Int64] = []
        while let packet = try demuxer.nextPacket() {
            try Task.checkCancellation()
            guard packet.track == track.number else { continue }
            guard !packet.continuesPrevious, packet.remainingLaceFrames == 0 else {
                throw EngineError.unsupportedCodec(track.codec.displayName)
            }
            if packet.isKeyframe, packet.timestamp < range.upperBound {
                allKeyframes.append(packet.timestamp)
            }
            if packet.timestamp < range.upperBound {
                candidates.append(packet.timestamp)
            }
        }
        let firstKeyframe = allKeyframes.last { $0 <= range.lowerBound } ?? 0
        let keyframes = allKeyframes.filter { $0 >= firstKeyframe }
        return normalizeVideoIndex(keyframes: keyframes, candidates: candidates, range: range)
    }

    private static func normalizeVideoIndex(
        keyframes: [Int64], candidates: [Int64], range: Range<Int64>
    ) -> (keyframes: [Int64], frameTimes: [Int64]) {
        let sortedFrames = Array(Set(candidates)).sorted()
        let leading = sortedFrames.last { $0 <= range.lowerBound }
        var kept: [Int64] = []
        if let leading { kept.append(leading) }
        kept.append(contentsOf: sortedFrames.filter { $0 > range.lowerBound && $0 < range.upperBound })
        let sortedKeyframes = Array(Set(keyframes)).sorted()
        let effectiveKeyframes = sortedKeyframes.isEmpty ? [kept.first ?? 0] : sortedKeyframes
        return (effectiveKeyframes, kept)
    }

    private struct DecodeChunk {
        let decodeFrom: Int64
        let nextKeyframe: Int64?
        let targetIndices: Range<Int>
    }

    private static func makeDecodeChunks(
        keyframes: [Int64], frameTimes: [Int64], maxBufferedFrames: Int
    ) -> [DecodeChunk] {
        var groups: [(decodeFrom: Int64, nextKeyframe: Int64?, indices: [Int])] = []
        var keyframeCursor = 0
        for index in frameTimes.indices {
            let timestamp = frameTimes[index]
            while keyframeCursor + 1 < keyframes.count, keyframes[keyframeCursor + 1] <= timestamp {
                keyframeCursor += 1
            }
            let decodeFrom = keyframes[keyframeCursor]
            let nextKeyframe = keyframeCursor + 1 < keyframes.count ? keyframes[keyframeCursor + 1] : nil
            if let last = groups.last, last.decodeFrom == decodeFrom {
                groups[groups.count - 1].indices.append(index)
            } else {
                groups.append((decodeFrom, nextKeyframe, [index]))
            }
        }
        var chunks: [DecodeChunk] = []
        for group in groups {
            guard let first = group.indices.first, let last = group.indices.last else { continue }
            var cursor = first
            while cursor <= last {
                let end = min(cursor + maxBufferedFrames, last + 1)
                chunks.append(
                    DecodeChunk(
                        decodeFrom: group.decodeFrom, nextKeyframe: group.nextKeyframe,
                        targetIndices: cursor..<end))
                cursor = end
            }
        }
        return chunks
    }

    private struct PreparedAudio {
        let totalFrames: Int64
        let sampleRate: Double
        let channels: Int
    }

    private static func prepareForwardAudio(
        input: MediaInput, track: MediaTrack, range: Range<Int64>, to url: URL
    ) async throws -> PreparedAudio {
        let source = try VideoPCMSource(input: input, track: track, start: range.lowerBound, end: range.upperBound)
        try await TimeStretchedAudio.writeContinuous(
            source, track: track, start: range.lowerBound, end: range.upperBound, to: url)
        let written = try AVAudioFile(forReading: url)
        return PreparedAudio(totalFrames: written.length, sampleRate: source.sampleRate, channels: source.channels)
    }

    private final class ReversedVideoStage: StreamStage {
        private static let timestampMatchTolerance: Int64 = 2

        private let input: MediaInput
        private let videoTrack: MediaTrack
        private let range: Range<Int64>
        private let frameTimes: [Int64]
        private let totalDuration: Int64
        private var remainingChunks: [DecodeChunk]
        private var encoder: any VideoFrameEncoder
        private let hdr: VideoHDRConfiguration?
        private let processor: FrameProcessor?
        private var pendingFrames: [(image: CVPixelBuffer, sourceIndex: Int)] = []
        private var lastOutputTimestamp: Int64?
        private var finished = false

        init(
            input: MediaInput, videoTrack: MediaTrack, range: Range<Int64>, frameTimes: [Int64],
            chunks: [DecodeChunk], encoding: VideoEncoding, hdr: VideoHDRConfiguration?,
            processor: FrameProcessor?
        ) throws {
            self.input = input
            self.videoTrack = videoTrack
            self.range = range
            self.frameTimes = frameTimes
            totalDuration = range.upperBound - range.lowerBound
            remainingChunks = chunks
            encoder = try VideoEncoders.make(encoding, track: 1)
            self.hdr = hdr
            self.processor = processor
        }

        var output: OutputTrack? {
            guard encoder.formatDescription != nil else { return nil }
            return OutputTrack(track: encoder.track, format: encoder.formatDescription)
        }

        var nextTime: Int64? {
            if finished { return nil }
            if let next = pendingFrames.last { return outputTimestamp(for: next.sourceIndex) }
            if let chunk = remainingChunks.last { return outputTimestamp(for: chunk.targetIndices.upperBound - 1) }
            return totalDuration
        }

        func pull() async throws -> [MediaPacket] {
            guard !finished else { return [] }
            while pendingFrames.isEmpty {
                try Task.checkCancellation()
                guard let chunk = remainingChunks.popLast() else {
                    finished = true
                    var packets = try encoder.finish()
                    clampFinalDuration(&packets)
                    return packets
                }
                pendingFrames = try await decodeChunk(chunk)
            }
            let next = pendingFrames.removeLast()
            var timestamp = outputTimestamp(for: next.sourceIndex)
            if let last = lastOutputTimestamp, timestamp <= last { timestamp = last + 1 }
            lastOutputTimestamp = timestamp
            let buffer = try processor?.process(next.image) ?? next.image
            var packets = try encoder.encode(buffer, timestamp: timestamp)
            if pendingFrames.isEmpty && remainingChunks.isEmpty {
                finished = true
                packets += try encoder.finish()
                clampFinalDuration(&packets)
            }
            return packets
        }

        private func outputTimestamp(for sourceIndex: Int) -> Int64 {
            let effectiveEnd = min(
                sourceIndex + 1 < frameTimes.count ? frameTimes[sourceIndex + 1] : range.upperBound,
                range.upperBound)
            return max(0, range.upperBound - effectiveEnd)
        }

        private func clampFinalDuration(_ packets: inout [MediaPacket]) {
            guard !packets.isEmpty else { return }
            let lastIndex = packets.count - 1
            let remaining = totalDuration - packets[lastIndex].timestamp
            if remaining > 0 {
                packets[lastIndex].duration = remaining
            }
        }

        private func decodeChunk(_ chunk: DecodeChunk) async throws -> [(image: CVPixelBuffer, sourceIndex: Int)] {
            let firstTarget = frameTimes[chunk.targetIndices.lowerBound]
            let lastTarget = frameTimes[chunk.targetIndices.upperBound - 1]
            var decoded: [DecodedFrame] = []
            switch input.backend {
            case .asset(let asset, let assetTrack?, _):
                let readerRange = CMTimeRange(
                    start: CMTime(
                        value: max(0, firstTarget - Self.timestampMatchTolerance),
                        timescale: SampleBuffers.nanosecondScale),
                    end: CMTime(
                        value: lastTarget + Self.timestampMatchTolerance + 1,
                        timescale: SampleBuffers.nanosecondScale))
                let mode: AssetTrackReader.Mode = hdr != nil ? .hdrFrames : .frames
                let reader = try AssetTrackReader(
                    asset: asset, track: assetTrack, number: 1, mode: mode, range: readerRange)
                while let frame = try await reader.nextFrame() {
                    try Task.checkCancellation()
                    if frame.timestamp >= firstTarget - Self.timestampMatchTolerance,
                        frame.timestamp <= lastTarget + Self.timestampMatchTolerance
                    {
                        decoded.append(frame)
                    }
                }
            default:
                guard var demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
                var decoder = try VideoDecoders.make(for: videoTrack, hdr: hdr)
                while let packet = try demuxer.nextPacket() {
                    try Task.checkCancellation()
                    guard packet.track == videoTrack.number, packet.timestamp >= chunk.decodeFrom else { continue }
                    if let nextKeyframe = chunk.nextKeyframe, packet.isKeyframe, packet.timestamp >= nextKeyframe {
                        break
                    }
                    for frame in try decoder.decode(packet)
                    where frame.timestamp >= firstTarget - Self.timestampMatchTolerance
                        && frame.timestamp <= lastTarget + Self.timestampMatchTolerance
                    {
                        decoded.append(frame)
                    }
                }
                for frame in try decoder.finish()
                where frame.timestamp >= firstTarget - Self.timestampMatchTolerance
                    && frame.timestamp <= lastTarget + Self.timestampMatchTolerance
                {
                    decoded.append(frame)
                }
            }
            decoded.sort { $0.timestamp < $1.timestamp }
            var matched: [(image: CVPixelBuffer, sourceIndex: Int)] = []
            var decodedCursor = 0
            for sourceIndex in chunk.targetIndices {
                let target = frameTimes[sourceIndex]
                while decodedCursor + 1 < decoded.count,
                    abs(decoded[decodedCursor + 1].timestamp - target)
                        < abs(decoded[decodedCursor].timestamp - target)
                {
                    decodedCursor += 1
                }
                if decodedCursor < decoded.count {
                    matched.append((decoded[decodedCursor].image, sourceIndex))
                    if decodedCursor + 1 < decoded.count { decodedCursor += 1 }
                }
            }
            guard !matched.isEmpty else { throw EngineError.decodeFailed("no frame in reversed segment") }
            return matched
        }
    }

    private final class ReversedAudioStage: StreamStage {
        private let file: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        private let sampleRate: Double
        private let channels: Int
        private let trackNumber: Int
        private var remainingFrames: Int64
        private var writtenFrames: Int64 = 0
        private(set) var output: OutputTrack?

        init(url: URL, totalFrames: Int64, sampleRate: Double, channels: Int, trackNumber: Int) throws {
            file = try AVAudioFile(forReading: url)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: VideoSegmentReverser.audioChunkFrames)
            else { throw EngineError.decodeFailed("audio reverse buffer unavailable") }
            self.buffer = buffer
            self.sampleRate = sampleRate
            self.channels = channels
            self.trackNumber = trackNumber
            remainingFrames = min(totalFrames, file.length)
            let pcmFormat = try PCMFormat.make(sampleRate: sampleRate, channels: channels)
            let track = MediaTrack(
                number: trackNumber, kind: .audio(sampleRate: sampleRate, channels: channels),
                codec: .pcm(bits: 32, float: true, bigEndian: false))
            output = OutputTrack(track: track, format: pcmFormat.formatDescription)
        }

        var nextTime: Int64? {
            guard remainingFrames > 0 else { return nil }
            return try? Nanoseconds.scale(writtenFrames, by: Nanoseconds.perSecond, over: Int64(sampleRate))
        }

        func pull() async throws -> [MediaPacket] {
            guard remainingFrames > 0 else { return [] }
            try Task.checkCancellation()
            let count = Int(min(remainingFrames, Int64(VideoSegmentReverser.audioChunkFrames)))
            file.framePosition = remainingFrames - Int64(count)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let readCount = Int(buffer.frameLength)
            guard readCount > 0, let planes = buffer.floatChannelData else {
                remainingFrames = 0
                return []
            }
            var interleaved = [Float](repeating: 0, count: readCount * channels)
            for frame in 0..<readCount {
                let sourceFrame = readCount - 1 - frame
                for channel in 0..<channels {
                    interleaved[frame * channels + channel] = planes[channel][sourceFrame]
                }
            }
            let timestamp = try Nanoseconds.scale(writtenFrames, by: Nanoseconds.perSecond, over: Int64(sampleRate))
            let duration = try Nanoseconds.scale(Int64(readCount), by: Nanoseconds.perSecond, over: Int64(sampleRate))
            remainingFrames -= Int64(readCount)
            writtenFrames += Int64(readCount)
            let payload = interleaved.withUnsafeBytes { Data($0) }
            return [
                MediaPacket(
                    track: trackNumber, timestamp: timestamp, duration: duration, isKeyframe: true, payload: payload)
            ]
        }
    }
}
