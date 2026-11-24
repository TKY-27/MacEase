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
    private let input: MediaInput
    private let preview: MediaPreview
    private let staging: StagingArea
    private let omittedStreams: Set<UnpreservedStream>
    private var additionalSources: [URL: VideoEditorSource] = [:]
    private var reversedDirectories: Set<URL> = []
    private var reverseTasks: [UUID: Task<VideoEdit, any Error>] = [:]
    private var proxies: [String: URL] = [:]
    private var musicProxies: [MediaSourceStamp: URL] = [:]
    private var musicTasks: [MediaSourceStamp: Task<URL, any Error>] = [:]
    private static let previewAudioChunkFrames: AVAudioFrameCount = 4_096
    private var directories: [URL] = []
    private var closed = false
    private var frameTimes: [Int64]?
    private let frameIndexes = EditorFrameIndexes()

    public static func open(
        _ url: URL, staging: StagingArea, omission: StreamOmission? = nil
    ) async throws -> VideoEditorSource {
        try await open(url, staging: staging) { input, stamp in
            let omitted = omission?.streams(covering: stamp) ?? []
            try input.requirePreservableStreams(omitting: omitted)
            return omitted
        }
    }

    /// Throwaway playback copies only; edits use `open`.
    public static func openForPreviewPlayback(_ url: URL, staging: StagingArea) async throws -> VideoEditorSource {
        try await open(url, staging: staging) { input, _ in
            _ = try input.displayOrientation
            return []
        }
    }

    private static func open(
        _ url: URL, staging: StagingArea, validate: (MediaInput, MediaSourceStamp) throws -> Set<UnpreservedStream>
    ) async throws -> VideoEditorSource {
        let stamp = try MediaSourceStamp(url: url)
        let input = try await MediaInput.open(url)
        let omittedStreams = try validate(input, stamp)
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
        self.input = input
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
        for task in musicTasks.values { task.cancel() }
        for directory in reversedDirectories { staging.release(directory) }
        for directory in directories { staging.remove(directory) }
    }

    public func frames(
        at seconds: [Double], width: Int, exactFrame: Bool = false
    ) async throws -> [CGImage] {
        try await renderedFrames(
            at: seconds, width: width, edit: VideoEdit(), cropPreview: false,
            exactFrame: exactFrame, segmentID: nil, omissions: [:])
    }

    public func frames(
        at seconds: [Double], width: Int, edit: VideoEdit, cropPreview: Bool = false,
        exactFrame: Bool = false, segmentID: UUID, omissions: [URL: StreamOmission] = [:]
    ) async throws -> [CGImage] {
        try await renderedFrames(
            at: seconds, width: width, edit: edit, cropPreview: cropPreview,
            exactFrame: exactFrame, segmentID: segmentID, omissions: omissions)
    }

    public func frames(
        atOutput seconds: [Double], width: Int, edit: VideoEdit, cropPreview: Bool = false,
        exactFrame: Bool = false, omissions: [URL: StreamOmission] = [:]
    ) async throws -> [CGImage] {
        try await renderedFrames(
            at: seconds, width: width, edit: edit, cropPreview: cropPreview,
            exactFrame: exactFrame, segmentID: nil, omissions: omissions)
    }

    private func renderedFrames(
        at seconds: [Double], width: Int, edit: VideoEdit, cropPreview: Bool,
        exactFrame: Bool, segmentID: UUID?, omissions: [URL: StreamOmission]
    ) async throws -> [CGImage] {
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        var geometry = edit.geometry
        if cropPreview { geometry.crop = EditCrop() }
        let resolved = try await edit.openedSources(
            primaryURL: url, omittedStreams: omittedStreams, omissions: omissions)
        let timeline = try VideoTimeline(edit: resolved.edit, sourceDuration: details.duration)
        var images: [CGImage] = []
        for requested in seconds {
            guard requested.isFinite, requested >= 0 else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            let segment: VideoSegment
            let second: Double
            let outputTime: Double
            if let segmentID {
                guard let selected = timeline.segments.first(where: { $0.id == segmentID }) else {
                    throw EngineError.invalidInput(.videoSegmentNotFound)
                }
                guard let output = timeline.outputTime(for: requested, segmentID: segmentID) else {
                    throw EngineError.invalidInput(.invalidNumericParameter)
                }
                segment = selected
                second = requested
                outputTime = output
            } else {
                guard requested <= timeline.duration else {
                    throw EngineError.invalidInput(.invalidNumericParameter)
                }
                outputTime = min(requested, timeline.duration.nextDown)
                segment = timeline.segment(at: outputTime)
                second = timeline.sourceTime(at: outputTime)
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
            let needsIndex = selection != nil || input.container.fileType == nil
            let frameIndex = needsIndex ? try await frameIndexes.index(for: input.url) : nil
            images += try await preview.frames(
                input: input, at: [Double(frameTime) / Double(Nanoseconds.perSecond)], width: width,
                geometry: geometry, adjustments: segment.adjustments,
                toneMapToSDR: edit.changesColor && sourceHDR != nil,
                exactFrame: exactFrame, overlaySelection: selection, frameIndex: frameIndex)
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
        if frameTimes == nil {
            let input = try await MediaInput.open(url)
            frameTimes = try await frameIndexes.index(for: input.url).timestamps
        }
        try Task.checkCancellation()
        guard !closed, let frameTimes else { throw CancellationError() }
        guard !frameTimes.isEmpty else { throw EngineError.decodeFailed("no video frames") }
        return frameTimes
    }

    public func playbackURL(
        sdr: Bool, normalized: Bool = false, progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
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
            try await Self.makePreview(
                url: url, output: output, toneMap: toneMap, normalized: normalized, progress: progress)
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

    /// Joined sources open with the caller's consent.
    public func playback(
        edit: VideoEdit, omissions: [URL: StreamOmission] = [:]
    ) async throws -> VideoEditorPlayback {
        guard !closed else { throw CancellationError() }
        try edit.geometry.validate()
        try input.requirePreservableStreams(omitting: omittedStreams)
        let timeline = try VideoTimeline(edit: edit, sourceDuration: details.duration)
        let playback = try await playbackURL(
            sdr: edit.changesColor || edit.requiresJoinedExport, normalized: edit.requiresJoinedExport)
        let resolvedMusicURL: URL?
        if timeline.music != nil {
            resolvedMusicURL = try await musicPlaybackURL(for: timeline.music)
        } else {
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
                        opened = try await VideoEditorSource.open(
                            source.url, staging: staging, omission: omissions[source.url])
                        guard !closed else {
                            await opened.close()
                            throw CancellationError()
                        }
                        additionalSources[source.url] = opened
                    }
                    try await opened.validate(omission: omissions[source.url])
                    urls.append(try await opened.playbackURL(sdr: true, normalized: true))
                }
            }
            payload = try await VideoEditorPlayback.joined(
                urls: urls, edit: previewEdit, sourceSize: details.size, audioPreviewURL: resolvedMusicURL,
                frameIndexes: frameIndexes)
            for source in sources { try source.stamp.validate(source.url) }
        } else {
            payload = try await VideoEditorPlayback.make(
                url: playback, timeline: timeline, edit: previewEdit, sourceSize: details.size,
                audioPreviewURL: resolvedMusicURL, frameIndexes: frameIndexes)
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        try timeline.music?.validateSource()
        return payload
    }

    private func validate(omission: StreamOmission?) throws {
        try details.stamp.validate(url)
        try input.requirePreservableStreams(omitting: omission?.streams(covering: details.stamp) ?? [])
    }

    private func musicPlaybackURL(for music: BackgroundMusic?) async throws -> URL? {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let music else { return nil }
        try music.validateSource()
        try await UntrustedMediaAsset.rejectExternalReferences(in: music.url)
        let input = try AudioInput(url: music.url)
        if try await AudioPreviewSource.canPlayDirectly(input) {
            return music.url
        }
        if let cached = musicProxies[music.stamp] { return cached }
        if let task = musicTasks[music.stamp] { return try await task.value }
        let directory = try staging.makeDirectory(for: music.url)
        directories.append(directory)
        let output = directory.appending(path: "music-preview.caf")
        let task = Task {
            try await Self.writeMusicPreview(music: music, to: output)
            return output
        }
        musicTasks[music.stamp] = task
        do {
            let result = try await task.value
            try music.validateSource()
            guard !closed else { throw CancellationError() }
            musicTasks.removeValue(forKey: music.stamp)
            musicProxies[music.stamp] = result
            try Task.checkCancellation()
            return result
        } catch {
            musicTasks.removeValue(forKey: music.stamp)
            if musicProxies[music.stamp] == nil {
                staging.remove(directory)
                directories.removeAll { $0 == directory }
            }
            throw error
        }
    }

    private nonisolated static func writeMusicPreview(music: BackgroundMusic, to url: URL) async throws {
        let source = try AudioInput(url: music.url).open()
        guard let channels = AVAudioChannelCount(exactly: source.channels),
            let format = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: channels),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.previewAudioChunkFrames),
            let planes = buffer.floatChannelData
        else { throw EngineError.audioChannelLayoutUnsupported }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while let samples = try source.read() {
            try Task.checkCancellation()
            let count = samples.count / source.channels
            for offset in stride(from: 0, to: count, by: Int(Self.previewAudioChunkFrames)) {
                let frames = min(count - offset, Int(Self.previewAudioChunkFrames))
                for frame in 0..<frames {
                    for channel in 0..<source.channels {
                        planes[channel][frame] = samples[(offset + frame) * source.channels + channel]
                    }
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                try file.write(from: buffer)
            }
        }
    }

    private nonisolated static func canPlay(_ url: URL) async throws -> Bool {
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else { return false }
        return try await UntrustedMediaAsset.make(url).load(.isPlayable)
    }

    private nonisolated static func makePreview(
        url: URL, output: URL, toneMap: Bool, normalized: Bool, progress: (Double) -> Void
    ) async throws {
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
        // Priming packets can fall outside the range.
        try await Transcoder.run(input, plan: plan, to: output) { progress(min(max($0, 0), 1)) }
    }

    public func reverse(
        segmentID: UUID, in edit: VideoEdit, omissions: [URL: StreamOmission] = [:],
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
        let selectedStamp = try MediaSourceStamp(url: selectedURL)
        let consent =
            selectedURL == url
            ? omittedStreams : omissions[selectedURL]?.streams(covering: selectedStamp) ?? []
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

    /// Cancelled adoption cannot enter Undo history.
    public func discardReversedSource(at url: URL) {
        let directory = url.deletingLastPathComponent()
        guard reversedDirectories.remove(directory) != nil else { return }
        staging.release(directory)
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
        let musicTasksToClose = Array(musicTasks.values)
        for task in musicTasksToClose { task.cancel() }
        for task in musicTasksToClose { _ = await task.result }
        musicTasks.removeAll()
        musicProxies.removeAll()
        for directory in directories { staging.remove(directory) }
        directories.removeAll()
        proxies.removeAll()
        await frameIndexes.close()
        frameTimes = nil
    }
}
