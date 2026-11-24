import AVFoundation
import CoreGraphics
import Formats
import Foundation

public struct VideoEditorDetails: Sendable {
    public let size: CGSize
    public let duration: Double
    public let frameDuration: Double
    public let hasAudio: Bool
    public let containsHDR: Bool
    public let hasAlpha: Bool
    public let stamp: MediaSourceStamp
}

public actor VideoEditorSource {
    public let details: VideoEditorDetails
    private let url: URL
    private let preview: MediaPreview
    private let staging: StagingArea
    private let omittedStreams: Set<UnpreservedStream>
    private var additionalSources: [URL: VideoEditorSource] = [:]
    private var reversedDirectories: Set<URL> = []
    private var reverseTasks: [UUID: Task<VideoEdit, any Error>] = [:]
    private var proxies: [String: URL] = [:]
    private var musicProxy: (edit: VideoEdit, playbackURL: URL, directory: URL)?
    private var musicGeneration = 0
    private static let previewAudioChunkFrames: AVAudioFrameCount = 4_096
    private var directories: [URL] = []
    private var closed = false
    private var frameTimes: [Int64]?

    public static func open(
        _ url: URL, staging: StagingArea, omission: StreamOmission? = nil
    ) async throws -> VideoEditorSource {
        let stamp = try MediaSourceStamp(url: url)
        let input = try await MediaInput.open(url)
        try input.requirePreservableStreams(omitting: omission?.streams(covering: stamp) ?? [])
        guard input.video != nil, input.duration > 0 else { throw EngineError.decodeFailed("no video track") }
        let hdr = try await VideoProperties.hdrConfiguration(input)
        let preview = MediaPreview(input: input, url: url)
        try stamp.validate(url)
        return VideoEditorSource(
            url: url, input: input, preview: preview, staging: staging,
            containsHDR: hdr != nil, stamp: stamp, omittedStreams: omittedStreams)
    }

    private init(
        url: URL, input: MediaInput, preview: MediaPreview, staging: StagingArea,
        containsHDR: Bool, stamp: MediaSourceStamp, omittedStreams: Set<UnpreservedStream>
    ) {
        self.url = url
        self.preview = preview
        self.staging = staging
        self.omittedStreams = omittedStreams
        details = VideoEditorDetails(
            size: CGSize(width: input.displaySize.width, height: input.displaySize.height),
            duration: preview.durationSeconds,
            frameDuration: Double(input.frameDuration) / Double(Nanoseconds.perSecond),
            hasAudio: input.audio != nil, containsHDR: containsHDR, hasAlpha: input.video?.hasAlpha == true,
            stamp: stamp)
    }

    deinit {
        for task in reverseTasks.values { task.cancel() }
        for directory in reversedDirectories { staging.release(directory) }
        for directory in directories { staging.remove(directory) }
    }

    public func frames(
        at seconds: [Double], width: Int, edit: VideoEdit = VideoEdit(), cropPreview: Bool = false,
        exactFrame: Bool = false, segmentID: UUID? = nil
    )
        async throws -> [CGImage]
    {
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        var geometry = edit.geometry
        if cropPreview { geometry.crop = EditCrop() }
        let resolved = try await edit.openedSources(primaryURL: url, omittedStreams: omittedStreams)
        let timeline = try VideoTimeline(edit: resolved.edit, sourceDuration: details.duration)
        var images: [CGImage] = []
        for second in seconds {
            let selected: VideoSegment?
            if let segmentID {
                selected = timeline.segments.first { $0.id == segmentID }
            } else {
                selected =
                    timeline.segments.first { second >= $0.start && second < $0.end }
                    ?? timeline.segments.last { second == $0.end }
            }
            guard let segment = selected else { throw EngineError.invalidInput(.videoSegmentNotFound) }
            guard let outputTime = timeline.outputTime(for: second, segmentID: segment.id) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            let input = resolved.inputs[segment.sourceIndex]
            let frameTime = min(try Nanoseconds.from(seconds: second), try Nanoseconds.from(seconds: segment.end) - 1)
            let selection: (@Sendable (ClosedRange<Double>) -> [EditOverlay])? =
                timeline.overlays.isEmpty
                ? nil
                : { @Sendable range in
                    timeline.overlays(at: outputTime, sourceRange: range, segmentID: segment.id)
                }
            let sourceHDR = try await VideoProperties.hdrConfiguration(input)
            images += try await preview.frames(
                input: input, at: [Double(frameTime) / Double(Nanoseconds.perSecond)], width: width,
                geometry: geometry, adjustments: segment.adjustments,
                toneMapToSDR: edit.changesColor && sourceHDR != nil,
                exactFrame: exactFrame, overlaySelection: selection)
        }
        try details.stamp.validate(url)
        for source in edit.sources ?? [] { try source.stamp.validate(source.url) }
        return images
    }

    public func adjacentFrameTime(to seconds: Double, forward: Bool) async throws -> Double {
        let timestamps = try await indexedFrameTimes()
        let current = try Nanoseconds.from(seconds: seconds)
        guard let first = timestamps.first, let last = timestamps.last else {
            throw EngineError.decodeFailed("no video frames")
        }
        let timestamp =
            forward
            ? timestamps.first { $0 > current + 1 } ?? last
            : timestamps.last { $0 < current - 1 } ?? first
        return Double(timestamp) / Double(Nanoseconds.perSecond)
    }

    public func nearestFrameTime(to seconds: Double, within range: Range<Double>) async throws -> Double? {
        guard seconds.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite,
            range.lowerBound >= 0, range.upperBound <= details.duration
        else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let timestamps = try await indexedFrameTimes()
        let requested = try Nanoseconds.from(seconds: min(max(seconds, range.lowerBound), range.upperBound))
        var lower = 0
        var upper = timestamps.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestamps[middle] < requested { lower = middle + 1 } else { upper = middle }
        }
        let candidates = [lower - 1, lower].filter { timestamps.indices.contains($0) }
            .map { Double(timestamps[$0]) / Double(Nanoseconds.perSecond) }
            .filter { range.contains($0) }
        return candidates.min { abs($0 - seconds) < abs($1 - seconds) }
    }

    private func indexedFrameTimes() async throws -> [Int64] {
        guard !closed else { throw CancellationError() }
        if frameTimes == nil { frameTimes = try await Self.readFrameTimes(url) }
        try Task.checkCancellation()
        guard !closed, let frameTimes else { throw CancellationError() }
        guard !frameTimes.isEmpty else { throw EngineError.decodeFailed("no video frames") }
        return frameTimes
    }

    private nonisolated static func readFrameTimes(_ url: URL) async throws -> [Int64] {
        let input = try await MediaInput.open(url)
        return try await EditorFrameIndex(input: input).timestamps
    }

    public func playbackURL(sdr: Bool, normalized: Bool = false) async throws -> URL {
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        let toneMap = sdr && details.containsHDR
        if !toneMap, !normalized, try await Self.canPlay(url) { return url }
        let key = "\(toneMap)-\(normalized)"
        if let cached = proxies[key] { return cached }
        let directory = try staging.makeDirectory(for: url)
        directories.append(directory)
        let output = directory.appending(path: "preview.mp4")
        do {
            try await Self.makePreview(url: url, output: output, toneMap: toneMap, normalized: normalized)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try details.stamp.validate(url)
            proxies[key] = output
            return output
        } catch {
            staging.remove(directory)
            directories.removeAll { $0 == directory }
            throw error
        }
    }

    public func playback(edit: VideoEdit) async throws -> VideoEditorPlayback {
        guard !closed else { throw CancellationError() }
        try edit.geometry.validate()
        let timeline = try VideoTimeline(edit: edit, sourceDuration: details.duration)
        let playback = try await playbackURL(
            sdr: edit.changesColor || edit.requiresJoinedExport, normalized: edit.requiresJoinedExport)
        let resolvedMusicURL: URL?
        if timeline.music != nil {
            resolvedMusicURL = try await musicPlaybackURL(for: edit)
        } else {
            clearMusicProxy()
            resolvedMusicURL = nil
        }
        var previewEdit = edit
        if previewEdit.sources == nil {
            previewEdit.sources = [VideoEditSource(url: url, duration: details.duration, stamp: details.stamp)]
        }
        let payload: VideoEditorPlayback
        if let sources = edit.sources {
            var urls: [URL] = []
            for source in sources {
                try source.stamp.validate(source.url)
                if source.url == url {
                    urls.append(playback)
                } else {
                    let opened: VideoEditorSource
                    if let cached = additionalSources[source.url] {
                        opened = cached
                    } else {
                        opened = try await VideoEditorSource.open(source.url, staging: staging)
                        guard !closed else {
                            await opened.close()
                            throw CancellationError()
                        }
                        additionalSources[source.url] = opened
                    }
                    urls.append(try await opened.playbackURL(sdr: true, normalized: true))
                }
            }
            payload = try await VideoEditorPlayback.joined(
                urls: urls, edit: previewEdit, sourceSize: details.size, audioPreviewURL: resolvedMusicURL)
            for source in sources { try source.stamp.validate(source.url) }
        } else {
            payload = try await VideoEditorPlayback.make(
                url: playback, timeline: timeline, edit: previewEdit, sourceSize: details.size,
                audioPreviewURL: resolvedMusicURL)
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        try timeline.music?.validateSource()
        return payload
    }

    private func musicPlaybackURL(for edit: VideoEdit) async throws -> URL {
        guard !closed else { throw CancellationError() }
        try edit.music?.validateSource()
        var key = edit
        key.geometry = EditGeometry()
        key.overlays = []
        key.adjustments = MediaAdjustments()
        key.resize = nil
        if var segments = key.segments {
            for index in segments.indices { segments[index].adjustments = MediaAdjustments() }
            key.segments = segments
        }
        if let cached = musicProxy, cached.edit == key { return cached.playbackURL }
        musicGeneration += 1
        let generation = musicGeneration
        let directory = try staging.makeDirectory(for: url)
        directories.append(directory)
        let output = directory.appending(path: "music-preview.caf")
        do {
            try await Self.writeMusicPreview(
                edit: edit, primaryURL: url, omittedStreams: omittedStreams, to: output, directory: directory
            ) { [weak self] in
                guard let self else { return true }
                return await self.closed
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try details.stamp.validate(url)
            for source in edit.sources ?? [] { try source.stamp.validate(source.url) }
            try edit.music?.validateSource()
            if generation == musicGeneration {
                clearMusicProxy()
                musicProxy = (key, output, directory)
            }
            return output
        } catch {
            staging.remove(directory)
            directories.removeAll { $0 == directory }
            throw error
        }
    }

    private nonisolated static func writeMusicPreview(
        edit: VideoEdit, primaryURL: URL, omittedStreams: Set<UnpreservedStream>, to url: URL, directory: URL,
        shouldCancel: @escaping @Sendable () async -> Bool
    ) async throws {
        let resolved = try await edit.openedSources(primaryURL: primaryURL, omittedStreams: omittedStreams)
        let inputs = resolved.inputs
        let timeline = try VideoTimeline(
            edit: resolved.edit, sourceDuration: Double(inputs[0].duration) / Double(Nanoseconds.perSecond))
        let source = try TimelinePCMSource(
            input: inputs[0], track: inputs[0].audio, timeline: timeline,
            inputs: inputs, stagingDirectory: directory)
        guard let channels = AVAudioChannelCount(exactly: source.channels),
            let format = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: channels),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.previewAudioChunkFrames),
            let planes = buffer.floatChannelData
        else { throw EngineError.audioChannelLayoutUnsupported }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while let chunk = try await source.next() {
            try Task.checkCancellation()
            if await shouldCancel() { throw CancellationError() }
            let count = chunk.samples.count / source.channels
            guard count <= Int(Self.previewAudioChunkFrames) else {
                throw EngineError.decodeFailed("preview audio chunk exceeded its buffer")
            }
            for frame in 0..<count {
                for channel in 0..<source.channels {
                    planes[channel][frame] = chunk.samples[frame * source.channels + channel]
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
    }

    private func clearMusicProxy() {
        musicGeneration += 1
        guard let existing = musicProxy else { return }
        staging.remove(existing.directory)
        directories.removeAll { $0 == existing.directory }
        musicProxy = nil
    }

    private nonisolated static func canPlay(_ url: URL) async throws -> Bool {
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else { return false }
        return try await AVURLAsset(url: url).load(.isPlayable)
    }

    private nonisolated static func makePreview(url: URL, output: URL, toneMap: Bool, normalized: Bool) async throws {
        let input = try await MediaInput.open(url)
        guard let source = input.video else { throw EngineError.decodeFailed("no video track") }
        if toneMap, case .asset(_, let track?, _) = input.backend {
            for format in try await track.load(.formatDescriptions) { try VideoSDR.validateSourceFormat(format) }
        }
        let size = try VideoResize.lines(720).outputSize(input.displaySize).evened()
        var encoding = VideoEncoding(
            codec: .h264, width: size.width, height: size.height,
            frameDuration: input.frameDuration, bitrate: nil)
        encoding.quality = 0.85
        var edit = FrameEdit(displayOrientation: try input.displayOrientation, size: size)
        edit.flattensAlpha = normalized
        var plan = TranscodePlan(
            container: .mp4, video: .encode(encoding, edit),
            audio: input.audio.map { _ in .encode(.aac, kilobits: 192) })
        plan.toneMapToSDR = toneMap
        plan.range = 0..<input.duration
        if source.hasAlpha, !normalized { throw EngineError.videoAlphaUnsupported }
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
    }

    public func reverse(
        segmentID: UUID, in edit: VideoEdit,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        statistics: @escaping @Sendable (VideoReverseStatistics) -> Void = { _ in }
    ) async throws -> VideoEdit {
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        let selected = edit.segments?.first { $0.id == segmentID }
        let selectedURL =
            selected.flatMap { segment in
                edit.sources.flatMap { $0.indices.contains(segment.sourceIndex) ? $0[segment.sourceIndex].url : nil }
            } ?? url
        let requestID = UUID()
        let consent = selectedURL == url ? omittedStreams : []
        let task = Task { [url, staging] in
            try await VideoSegmentReverser.reverse(
                segmentID: segmentID, in: edit, primaryURL: url, staging: staging,
                omittedStreams: consent, progress: progress, statistics: statistics)
        }
        reverseTasks[requestID] = task
        defer { reverseTasks.removeValue(forKey: requestID) }
        let updated = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard let source = updated.sources?.last else { throw EngineError.invalidInput(.emptyInput) }
        let directory = source.url.deletingLastPathComponent()
        if closed || Task.isCancelled {
            staging.remove(directory)
            throw CancellationError()
        }
        staging.retain(directory)
        reversedDirectories.insert(directory)
        return updated
    }

    public func close() async {
        closed = true
        let tasks = Array(reverseTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
        for source in additionalSources.values { await source.close() }
        additionalSources.removeAll()
        for directory in reversedDirectories { staging.release(directory) }
        reversedDirectories.removeAll()
        for directory in directories { staging.remove(directory) }
        directories.removeAll()
        proxies.removeAll()
        musicProxy = nil
        frameTimes = nil
    }
}
