import AVFoundation
import CoreMedia
import CoreVideo
import Formats
import Foundation

public struct VideoReverseStatistics: Sendable {
    public let decodedFrames: Int
    public let peakBufferedBytes: Int
}

public enum VideoSegmentReverser {
    public static let maximumSegmentSeconds = 60.0

    private static let intermediateQuality = 0.95
    private static let intermediateKeyframeInterval = Nanoseconds.perSecond
    private static let sdrBytesPerPixel = 4
    private static let hdrBytesPerPixel = 8
    private static let audioChunkFrames: AVAudioFrameCount = 4_096
    private static let audioPrepProgressShare = 0.15
    private static let readinessPoll = Duration.milliseconds(2)
    private static let videoPreparationProgressShare = 0.4

    static func reverse(
        segmentID: UUID,
        in edit: VideoEdit,
        primaryURL: URL,
        staging: StagingArea,
        omittedStreams: Set<UnpreservedStream> = [],
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        statistics: @escaping @Sendable (VideoReverseStatistics) -> Void = { _ in }
    ) async throws -> VideoEdit {
        try Task.checkCancellation()
        guard var segments = edit.segments,
            let segmentIndex = segments.firstIndex(where: { $0.id == segmentID })
        else { throw EngineError.invalidInput(.videoSegmentNotFound) }
        var segment = segments[segmentIndex]
        guard !segment.isFreeze else { throw EngineError.invalidInput(.cannotReverseFreeze) }
        guard !segment.isReversed else { throw EngineError.invalidInput(.segmentAlreadyReversed) }
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let segmentSeconds = segment.end - segment.start
        guard segmentSeconds <= maximumSegmentSeconds else {
            throw EngineError.invalidInput(.tooLong(limitSeconds: maximumSegmentSeconds))
        }

        var sources: [VideoEditSource]
        let input: MediaInput
        if let existing = edit.sources, !existing.isEmpty {
            guard existing.indices.contains(segment.sourceIndex) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            for source in existing { try source.stamp.validate(source.url) }
            sources = existing
            input = try await MediaInput.open(existing[segment.sourceIndex].url)
        } else {
            guard segment.sourceIndex == 0 else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            try edit.sourceStamp?.validate(primaryURL)
            let primaryInput = try await MediaInput.open(primaryURL)
            input = primaryInput
            let primaryDuration = Double(primaryInput.duration) / Double(Nanoseconds.perSecond)
            let primaryStamp = try edit.sourceStamp ?? MediaSourceStamp(url: primaryURL)
            sources = [VideoEditSource(url: primaryURL, duration: primaryDuration, stamp: primaryStamp)]
        }

        let originSource = sources[segment.sourceIndex]
        guard originSource.reversedOrigin == nil else { throw EngineError.invalidInput(.segmentAlreadyReversed) }
        _ = try VideoTimeline(edit: edit, sourceDuration: sources[0].duration)
        try input.requirePreservableStreams(omitting: omittedStreams)
        guard input.video != nil else { throw EngineError.decodeFailed("no video track") }
        let rangeStart = try Nanoseconds.from(seconds: segment.start)
        let rangeEnd = try Nanoseconds.from(seconds: segment.end)
        guard rangeStart >= 0, rangeStart < rangeEnd, rangeEnd <= input.duration else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }

        let directory = try staging.makeDirectory(for: primaryURL)
        let outputURL = directory.appending(path: "reversed-\(UUID().uuidString).mov")
        do {
            let reversedFrames = try await renderReversed(
                input: input, range: rangeStart..<rangeEnd, to: outputURL, stagingDirectory: directory,
                statistics: statistics, progress: progress)
            try Task.checkCancellation()
            try originSource.stamp.validate(originSource.url)
            let rendered = try await MediaInput.open(outputURL)
            guard rendered.video != nil, rendered.duration > 0 else {
                throw EngineError.encodeFailed("reversed clip has no video")
            }
            let renderedDuration = Double(rendered.duration) / Double(Nanoseconds.perSecond)
            let origin = ReversedSegmentOrigin(
                sourceIndex: segment.sourceIndex, start: segment.start, end: segment.end)
            let reversedSource = VideoEditSource(
                url: outputURL, duration: renderedDuration, stamp: try MediaSourceStamp(url: outputURL),
                reversedOrigin: origin, reversedFrames: reversedFrames)
            let newSourceIndex = sources.count
            sources.append(reversedSource)
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
        guard let sources = edit.sources, let first = sources.first else {
            throw EngineError.invalidInput(.videoSegmentNotFound)
        }
        var segments = try VideoTimeline(edit: edit, sourceDuration: first.duration).segments
        guard let segmentIndex = segments.firstIndex(where: { $0.id == segmentID }),
            let origin = segments[segmentIndex].reversedOrigin
        else { throw EngineError.invalidInput(.videoSegmentNotFound) }
        var segment = segments[segmentIndex]
        guard !segment.isFreeze else { throw EngineError.invalidInput(.cannotReverseFreeze) }
        let stagedSourceIndex = segment.sourceIndex
        let reversedDuration = sources[segment.sourceIndex].duration
        let lower = origin.mappedTime(segment.end, stagedDuration: reversedDuration, toOriginal: true)
        let upper = origin.mappedTime(segment.start, stagedDuration: reversedDuration, toOriginal: true)
        guard lower < upper else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let restoredRange = lower..<upper
        segment.sourceIndex = origin.sourceIndex
        segment.start = restoredRange.lowerBound
        segment.end = restoredRange.upperBound
        segment.reversedOrigin = nil
        segments[segmentIndex] = segment

        var updated = edit
        updated.segments = segments
        if edit.overlays.contains(where: { $0.sourceIndex == stagedSourceIndex }) {
            updated.overlays = edit.overlays.map { timed in
                guard timed.sourceIndex == stagedSourceIndex else { return timed }
                var mapped = timed
                mapped.sourceIndex = origin.sourceIndex
                mapped.start = origin.mappedTime(timed.end, stagedDuration: reversedDuration, toOriginal: true)
                mapped.end = origin.mappedTime(timed.start, stagedDuration: reversedDuration, toOriginal: true)
                let frames =
                    sources[stagedSourceIndex].reversedFrames?.filter { frame in
                        timed.overlay.isAnnotation && frame.stagedStart >= timed.start && frame.stagedStart < timed.end
                    } ?? []
                if let start = frames.map(\.sourceStart).min(), let end = frames.map(\.sourceEnd).max() {
                    mapped.start = start
                    mapped.end = end
                }
                return mapped
            }
        }
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
            let referenced = segments.contains { segment in
                if segment.sourceIndex == index || segment.reversedOrigin?.sourceIndex == index { return true }
                guard sources.indices.contains(segment.sourceIndex) else { return false }
                return sources[segment.sourceIndex].reversedOrigin?.sourceIndex == index
            }
            if !referenced, StagingArea.isItemReplacementDirectory(directory) {
                sources.remove(at: index)
                for sourceIndex in sources.indices {
                    let source = sources[sourceIndex]
                    guard var origin = source.reversedOrigin, origin.sourceIndex > index else { continue }
                    origin.sourceIndex -= 1
                    sources[sourceIndex] = VideoEditSource(
                        url: source.url, duration: source.duration, stamp: source.stamp,
                        reversedOrigin: origin, reversedFrames: source.reversedFrames)
                }
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

    private static func renderReversed(
        input: MediaInput, range: Range<Int64>, to outputURL: URL, stagingDirectory: URL,
        statistics: @escaping @Sendable (VideoReverseStatistics) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [ReversedSourceFrame] {
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

        let processor: FrameProcessor?
        if preservesRawGeometry {
            processor = nil
        } else {
            var frameEdit = FrameEdit(displayOrientation: try input.displayOrientation, size: outputSize)
            frameEdit.preservesAlpha = hasAlpha
            processor = try FrameProcessor(
                source: input.codedSize, edit: frameEdit, hdr: hdr?.configuration, display: videoTrack.displayGeometry)
        }

        let frameRanges = try await scanVideoIndex(input: input, range: range)
        guard !frameRanges.isEmpty else { throw EngineError.decodeFailed("no frame in selected segment") }
        let spillURL = stagingDirectory.appending(path: "reverse-frames.lz4")
        let spill = try ReversedFrameSpill(url: spillURL)
        let decodedFrames = try await spillForwardFrames(
            input: input, videoTrack: videoTrack, frameRanges: frameRanges, hdr: hdr?.configuration,
            spill: spill, progress: progress)

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
        let hasAudio = input.audio != nil
        var stages: [any StreamStage] = []
        let videoStage = try ReversedVideoStage(
            spill: spill, range: range, frameRanges: frameRanges, encoding: encoding, processor: processor)
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
            progress(videoPreparationProgressShare + audioPrepProgressShare)
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
        let baseProgress = videoPreparationProgressShare + (hasAudio ? audioPrepProgressShare : 0)
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
            try spill.close()
            try FileManager.default.removeItem(at: spillURL)
            if let audioTempURL { try FileManager.default.removeItem(at: audioTempURL) }
            statistics(VideoReverseStatistics(decodedFrames: decodedFrames, peakBufferedBytes: spill.peakBufferedBytes))
            progress(1)
            return frameRanges.reversed().map { frame in
                ReversedSourceFrame(
                    stagedStart: Double(max(0, range.upperBound - min(frame.upperBound, range.upperBound)))
                        / Double(Nanoseconds.perSecond),
                    stagedEnd: Double(range.upperBound - max(frame.lowerBound, range.lowerBound))
                        / Double(Nanoseconds.perSecond),
                    sourceStart: Double(frame.lowerBound) / Double(Nanoseconds.perSecond),
                    sourceEnd: Double(frame.upperBound) / Double(Nanoseconds.perSecond))
            }
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
            for candidate in ordered {
                guard let output = stages[candidate.index].output else {
                    throw EngineError.encodeFailed("reverse stream has no output track")
                }
                if sink.accepts(track: output.track.number) { return candidate.index }
            }
            try await Task.sleep(for: readinessPoll)
        }
    }

    private static func scanVideoIndex(
        input: MediaInput, range: Range<Int64>
    ) async throws -> [Range<Int64>] {
        let sorted = try await EditorFrameIndex(input: input).timestamps
        return sorted.enumerated().compactMap { index, start in
            let end = index + 1 < sorted.count ? sorted[index + 1] : input.duration
            guard start < range.upperBound, end > range.lowerBound, start < end else { return nil }
            return max(0, start)..<end
        }
    }

    private static func spillForwardFrames(
        input: MediaInput, videoTrack: MediaTrack, frameRanges: [Range<Int64>], hdr: VideoHDRConfiguration?,
        spill: ReversedFrameSpill, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let targets = Set(frameRanges.map(\.lowerBound))
        var seen = Set<Int64>()
        var decodedCount = 0
        func store(_ frame: DecodedFrame) throws {
            decodedCount += 1
            guard targets.contains(frame.timestamp) else { return }
            guard seen.insert(frame.timestamp).inserted else {
                throw EngineError.decodeFailed("duplicate decoded reverse frame")
            }
            try spill.append(frame)
            progress(videoPreparationProgressShare * Double(seen.count) / Double(targets.count))
        }
        switch input.backend {
        case .asset(let asset, let track?, _):
            let range = CMTimeRange(
                start: CMTime(value: frameRanges[0].lowerBound, timescale: SampleBuffers.nanosecondScale),
                end: CMTime(value: input.duration, timescale: SampleBuffers.nanosecondScale))
            let reader = try AssetTrackReader(
                asset: asset, track: track, number: videoTrack.number, mode: hdr == nil ? .frames : .hdrFrames,
                range: range)
            while let frame = try await reader.nextFrame() {
                try autoreleasepool { try store(frame) }
                if seen.count == targets.count { break }
            }
        default:
            guard var demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
            var decoder = try VideoDecoders.make(for: videoTrack, hdr: hdr, presentationOrder: false)
            while let packet = try demuxer.nextPacket() {
                try Task.checkCancellation()
                guard packet.track == videoTrack.number else { continue }
                try autoreleasepool {
                    for frame in try decoder.decode(packet) { try store(frame) }
                }
                if seen.count == targets.count { break }
            }
            for frame in try decoder.finish() { try autoreleasepool { try store(frame) } }
        }
        guard seen == targets else {
            throw EngineError.decodeFailed("missing decoded reverse frame: \(targets.subtracting(seen).sorted())")
        }
        try spill.sortFrames()
        return decodedCount
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
        private let spill: ReversedFrameSpill
        private let range: Range<Int64>
        private let frameRanges: [Range<Int64>]
        private let durations: [Int64: Int64]
        private var remaining: Int
        private var encoder: any VideoFrameEncoder
        private let processor: FrameProcessor?
        private var finished = false

        init(
            spill: ReversedFrameSpill, range: Range<Int64>, frameRanges: [Range<Int64>],
            encoding: VideoEncoding, processor: FrameProcessor?
        ) throws {
            self.spill = spill
            self.range = range
            self.frameRanges = frameRanges
            durations = Dictionary(
                uniqueKeysWithValues: frameRanges.map { frame in
                    let start = max(0, range.upperBound - min(frame.upperBound, range.upperBound))
                    let end = range.upperBound - max(frame.lowerBound, range.lowerBound)
                    return (start, end - start)
                })
            remaining = frameRanges.count
            encoder = try VideoEncoders.make(encoding, track: 1)
            self.processor = processor
        }

        var output: OutputTrack? {
            guard encoder.formatDescription != nil else { return nil }
            return OutputTrack(track: encoder.track, format: encoder.formatDescription)
        }

        var nextTime: Int64? {
            guard !finished else { return nil }
            return remaining > 0 ? outputTimestamp(at: remaining - 1) : range.upperBound - range.lowerBound
        }

        func pull() async throws -> [MediaPacket] {
            try Task.checkCancellation()
            guard !finished else { return [] }
            guard remaining > 0 else {
                finished = true
                return try timed(encoder.finish())
            }
            remaining -= 1
            return try autoreleasepool {
                let image = try spill.image(at: remaining)
                let buffer = try processor?.process(image) ?? image
                let timestamp = outputTimestamp(at: remaining)
                var packets = try encoder.encode(buffer, timestamp: timestamp)
                if remaining == 0 {
                    finished = true
                    packets += try encoder.finish()
                }
                return try timed(packets)
            }
        }

        private func timed(_ packets: [MediaPacket]) throws -> [MediaPacket] {
            try packets.map { packet in
                guard let duration = durations[packet.timestamp] else {
                    throw EngineError.encodeFailed("reverse encoder changed frame time")
                }
                var timed = packet
                timed.duration = duration
                return timed
            }
        }

        private func outputTimestamp(at index: Int) -> Int64 {
            max(0, range.upperBound - min(frameRanges[index].upperBound, range.upperBound))
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
        private var nextTimestamp: Int64 = 0
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
            return nextTimestamp
        }

        func pull() async throws -> [MediaPacket] {
            guard remainingFrames > 0 else { return [] }
            try Task.checkCancellation()
            let count = Int(min(remainingFrames, Int64(VideoSegmentReverser.audioChunkFrames)))
            file.framePosition = remainingFrames - Int64(count)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let readCount = Int(buffer.frameLength)
            guard readCount > 0, let planes = buffer.floatChannelData else {
                throw EngineError.decodeFailed("reversed audio ended early")
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
            nextTimestamp = try Nanoseconds.scale(writtenFrames, by: Nanoseconds.perSecond, over: Int64(sampleRate))
            let payload = interleaved.withUnsafeBytes { Data($0) }
            return [
                MediaPacket(
                    track: trackNumber, timestamp: timestamp, duration: duration, isKeyframe: true, payload: payload)
            ]
        }
    }
}
