import AVFoundation
import CoreVideo
import Formats
import Foundation

/// Edited frames at a constant rate.
final class FrameSampler {
    private static let hdrWorkingFrames: Int64 = 4
    private static let timestampTolerance: Int64 = 1
    private static let hdrBytesPerPixel = 8
    private enum Source {
        case asset(AssetTrackReader)
        case container(any MediaDemuxer, any VideoFrameDecoder, sourceTrack: Int, decodeFrom: Int64, started: Bool)
    }

    private var source: Source
    private var processor: FrameProcessor?
    private let edit: FrameEdit
    private let hdr: VideoHDRConfiguration?
    private let display: VideoDisplayGeometry?
    let frameDuration: Int64
    private let sourceFrameDuration: Int64
    private let sourceCodec: MediaCodec
    private let frameIndex: EditorFrameIndex?
    private let end: Int64
    private let holdsLastFrame: Bool
    private let timing: VideoTiming
    private var decoded: [DecodedFrame] = []
    private var sourceQueue: [DecodedFrame] = []
    private var nextOutput: Int64
    private var sourceEnded = false
    /// Source time read so far.
    private(set) var position: Int64

    init(
        input: MediaInput, frameDuration: Int64, edit: FrameEdit, start: Int64, end: Int64,
        hdr: VideoHDRConfiguration? = nil, toneMapToSDR: Bool = false, speed: Double = 1,
        holdsLastFrame: Bool = false, frameIndex: EditorFrameIndex? = nil
    ) async throws {
        guard let track = input.video else { throw EngineError.invalidInput(.malformed("no video track")) }
        if hdr != nil {
            var budget = FrameMemoryBudget()
            try budget.reserve(
                width: input.codedSize.width, height: input.codedSize.height,
                bytesPerPixel: Self.hdrBytesPerPixel, frameCount: Self.hdrWorkingFrames)
        }
        timing = try VideoTiming(start: start, speed: speed)
        self.edit = edit
        self.hdr = hdr
        display = track.displayGeometry
        self.frameDuration = frameDuration
        sourceFrameDuration = input.frameDuration
        sourceCodec = track.codec
        self.end = end
        self.holdsLastFrame = holdsLastFrame
        nextOutput = start
        position = start
        switch input.backend {
        case .asset(let asset, let video?, _):
            if let frameIndex {
                self.frameIndex = frameIndex
            } else if edit.hasOverlays {
                self.frameIndex = try await EditorFrameIndex(asset: asset, track: video, end: input.duration)
            } else {
                self.frameIndex = nil
            }
            let range = CMTimeRange(
                start: CMTime(value: start, timescale: SampleBuffers.nanosecondScale),
                end: Transcoder.readerTime(end))
            let mode: AssetTrackReader.Mode = toneMapToSDR ? .sdrFrames : hdr != nil ? .hdrFrames : .frames
            source = .asset(try AssetTrackReader(asset: asset, track: video, number: 1, mode: mode, range: range))
        default:
            self.frameIndex = frameIndex
            if toneMapToSDR { throw EngineError.hdrConversionUnsupported }
            guard var demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
            let decodeFrom: Int64
            if let frameIndex {
                decodeFrom = frameIndex.keyframes.last { $0 <= start } ?? 0
            } else {
                decodeFrom = start > 0 ? try await Transcoder.keyframe(atOrBefore: start, in: input) : 0
            }
            var started = decodeFrom == 0
            if var matroska = demuxer as? MatroskaDemuxer, let checkpoint = frameIndex?.checkpoints[decodeFrom] {
                matroska.seek(to: checkpoint)
                demuxer = matroska
                started = true
            }
            source = .container(
                demuxer, try VideoDecoders.make(for: track, hdr: hdr), sourceTrack: track.number,
                decodeFrom: decodeFrom, started: started)

        }
    }

    /// `nil` once the range is exhausted.
    func next() async throws -> DecodedFrame? {
        try Task.checkCancellation()
        let (outputCenter, centerOverflow) = nextOutput.addingReportingOverflow(frameDuration / 2)
        guard !centerOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        let sourceStart = try timing.sourceTime(nextOutput)
        let center = try timing.sourceTime(outputCenter)
        let firstShortFrame = timing.speed != 1 && nextOutput == timing.start && sourceStart < end
        guard center < end || firstShortFrame else {
            decoded.removeAll()
            sourceQueue.removeAll()
            return nil
        }
        guard let frame = try await next(sourceTime: min(center, end - 1), timestamp: nextOutput) else {
            return nil
        }
        let (following, followingOverflow) = nextOutput.addingReportingOverflow(frameDuration)
        guard !followingOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        nextOutput = following
        return frame
    }

    func next(
        sourceTime: Int64, timestamp: Int64, fade: Double = 1, overlays: [EditOverlay] = [],
        overlaySelection: (@Sendable (ClosedRange<Double>) -> [EditOverlay])? = nil
    ) async throws
        -> DecodedFrame?
    {
        while true {
            try Task.checkCancellation()
            if let chosen = try ready(center: sourceTime) {
                let active: [EditOverlay]
                if let overlaySelection {
                    let range: ClosedRange<Double>
                    if let frameIndex {
                        range = try frameIndex.range(
                            at: CMTime(value: chosen.timestamp, timescale: SampleBuffers.nanosecondScale))
                    } else {
                        let upper = decoded.count > 1 ? decoded[1].timestamp : end
                        range =
                            Double(chosen.timestamp) / Double(Nanoseconds.perSecond)...Double(upper)
                            / Double(Nanoseconds.perSecond)
                    }
                    active = overlaySelection(range)

                } else {
                    active = overlays
                }
                let image = try processor(for: chosen.image).process(chosen.image, fade: fade, overlays: active)
                return DecodedFrame(image: image, timestamp: timestamp)
            }
            if sourceEnded { return nil }
            if let frame = try await nextSourceFrame() {
                decoded.append(frame)
                position = frame.timestamp
            } else {
                sourceEnded = true
            }
        }
    }

    private func processor(for image: CVPixelBuffer) throws -> FrameProcessor {
        if let processor { return processor }
        let size = PixelSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        let created = try FrameProcessor(source: size, edit: edit, hdr: hdr, display: display)
        processor = created
        return created
    }

    private func ready(center: Int64) throws -> DecodedFrame? {
        guard center < end else { return nil }
        while decoded.count >= 2, decoded[1].timestamp <= center + Self.timestampTolerance { decoded.removeFirst() }
        guard let first = decoded.first else { return nil }
        if decoded.count >= 2 { return first }
        guard sourceEnded else { return nil }
        // Editor segments may outlast the video track.
        if holdsLastFrame { return first }
        let (sourceEnd, overflow) = first.timestamp.addingReportingOverflow(max(frameDuration, sourceFrameDuration))
        guard !overflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        guard center < sourceEnd else { return nil }
        return first
    }

    private func nextSourceFrame() async throws -> DecodedFrame? {
        switch source {
        case .asset(let reader):
            return try await reader.nextFrame()
        case .container(var demuxer, var decoder, let sourceTrack, let decodeFrom, var started):
            defer {
                source = .container(
                    demuxer, decoder, sourceTrack: sourceTrack, decodeFrom: decodeFrom, started: started)
            }
            while sourceQueue.isEmpty, let packet = try demuxer.nextPacket() {
                try Task.checkCancellation()
                guard packet.track == sourceTrack else { continue }
                if !started {
                    guard packet.isKeyframe, packet.timestamp == decodeFrom else { continue }
                    started = true
                }
                guard !packet.continuesPrevious, packet.remainingLaceFrames == 0 else {
                    throw EngineError.unsupportedCodec(sourceCodec.displayName)
                }
                sourceQueue = try decoder.decode(packet)
            }
            if sourceQueue.isEmpty { sourceQueue = try decoder.finish() }
            return sourceQueue.isEmpty ? nil : sourceQueue.removeFirst()
        }
    }
}

final class EditorFrameIndex: Sendable {
    private static let timestampTolerance: Int64 = 1
    private static let maximumIndexedFrames = 4_000_000
    let timestamps: [Int64]
    let keyframes: [Int64]
    let checkpoints: [Int64: MatroskaDemuxer.Checkpoint]
    let packetBytesRead: Int64
    let end: Int64

    init(asset: AVAsset, track: AVAssetTrack, end: Int64) async throws {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
            throw EngineError.decodeFailed("source has no frame index")
        }
        let mappings = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping)
        var timestamps: [Int64] = []
        var keyframes: [Int64] = []
        repeat {
            try Task.checkCancellation()
            let timestamp = cursor.presentationTimeStamp
            let duration = cursor.currentSampleDuration
            guard timestamp.isNumeric, duration.isNumeric else {
                throw EngineError.decodeFailed("invalid video frame index sample")
            }
            if duration > .zero {
                let sampleRange = CMTimeRange(start: timestamp, duration: duration)
                for mapping in mappings {
                    let overlap = CMTimeRangeGetIntersection(sampleRange, otherRange: mapping.source)
                    guard overlap.isValid, overlap.duration > .zero else { continue }
                    let output = CMTimeMapTimeFromRangeToRange(
                        overlap.start, fromRange: mapping.source, toRange: mapping.target)
                    let time = SampleBuffers.nanoseconds(output)
                    timestamps.append(time)
                    if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { keyframes.append(time) }
                }
            }
            guard timestamps.count <= Self.maximumIndexedFrames else {
                throw EngineError.decodeFailed("video frame index limit exceeded")
            }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        self.timestamps = Array(Set(timestamps.filter { $0 >= 0 && $0 < end })).sorted()
        self.keyframes = Array(Set(keyframes)).sorted()
        checkpoints = [:]
        packetBytesRead = 0
        self.end = end
        guard !self.timestamps.isEmpty else { throw EngineError.decodeFailed("source has no frame index") }
    }

    convenience init(input: MediaInput) async throws {
        if case .asset(let asset, let track?, _) = input.backend {
            try await self.init(asset: asset, track: track, end: input.duration)
            return
        }
        guard let video = input.video, var demuxer = try input.demuxer else {
            throw EngineError.decodeFailed("source has no frame index")
        }
        var timestamps: [Int64] = []
        var keyframes: [Int64] = []
        var checkpoints: [Int64: MatroskaDemuxer.Checkpoint] = [:]
        var packetBytesRead: Int64 = 0
        while true {
            let checkpoint = (demuxer as? MatroskaDemuxer)?.checkpoint()
            guard let packet = try demuxer.nextPacket() else { break }
            try Task.checkCancellation()
            guard packet.track == video.number else { continue }
            guard !packet.continuesPrevious, packet.remainingLaceFrames == 0 else {
                throw EngineError.unsupportedCodec(video.codec.displayName)
            }
            packetBytesRead += Int64(packet.payload.count)
            timestamps.append(packet.timestamp)
            if packet.isKeyframe {
                keyframes.append(packet.timestamp)
                if let checkpoint { checkpoints[packet.timestamp] = checkpoint }
            }
            guard timestamps.count <= Self.maximumIndexedFrames else {
                throw EngineError.decodeFailed("video frame index limit exceeded")
            }
        }
        try self.init(
            timestamps: timestamps, keyframes: keyframes, checkpoints: checkpoints,
            packetBytesRead: packetBytesRead, end: input.duration)
    }

    private init(
        timestamps: [Int64], keyframes: [Int64], checkpoints: [Int64: MatroskaDemuxer.Checkpoint],
        packetBytesRead: Int64, end: Int64
    ) throws {
        self.timestamps = Array(Set(timestamps.filter { $0 >= 0 && $0 < end })).sorted()
        self.keyframes = Array(Set(keyframes)).sorted()
        self.checkpoints = checkpoints
        self.packetBytesRead = packetBytesRead
        self.end = end
        guard !self.timestamps.isEmpty else { throw EngineError.decodeFailed("source has no frame index") }
    }

    func range(at requested: CMTime, coversBoundary: Bool = false) throws -> ClosedRange<Double> {
        guard requested.isNumeric else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let time = SampleBuffers.nanoseconds(requested)
        let insertion = upperBound(time, inclusive: true)
        let exact = insertion > 0 && timestamps[insertion - 1] == time
        let uncertain = coversBoundary && !exact
        let lowerTime = uncertain ? time - Self.timestampTolerance : time + Self.timestampTolerance
        let lower = max(0, upperBound(lowerTime, inclusive: !uncertain) - 1)
        let upper = upperBound(time + Self.timestampTolerance, inclusive: true)
        let upperTime = upper < timestamps.count ? timestamps[upper] : end
        return Double(timestamps[lower]) / Double(Nanoseconds.perSecond)...Double(upperTime)
            / Double(Nanoseconds.perSecond)
    }

    private func upperBound(_ time: Int64, inclusive: Bool) -> Int {
        var lower = 0
        var upper = timestamps.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestamps[middle] < time || (inclusive && timestamps[middle] == time) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

actor EditorFrameIndexes {
    private var closed = false
    private(set) var buildCount = 0
    private var indexes: [URL: Task<EditorFrameIndex, any Error>] = [:]

    func index(for url: URL) async throws -> EditorFrameIndex {
        guard !closed else { throw CancellationError() }
        if let existing = indexes[url] { return try await existing.value }
        let task = Task { try await EditorFrameIndex(input: MediaInput.open(url)) }
        buildCount += 1
        indexes[url] = task
        do {
            return try await task.value
        } catch {
            indexes.removeValue(forKey: url)
            throw error
        }
    }

    func close() {
        closed = true
        for task in indexes.values { task.cancel() }
        indexes.removeAll()
    }
}
