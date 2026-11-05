import AVFoundation
import CoreImage
import Engine
import Observation
import SwiftUI
import os

enum EditorCategory: String, CaseIterable {
    case video, adjust, styles, crop

    var title: String {
        switch self {
        case .video: String(localized: "Video")
        case .adjust: String(localized: "Adjust")
        case .styles: String(localized: "Styles")
        case .crop: String(localized: "Crop")
        }
    }
}

struct EditorValues: Equatable {
    private var singlePhoto = ImageEdit()
    var photoEdits: [URL: ImageEdit] = [:]
    var selectedPhoto: URL?
    var sources: [VideoEditSource] = []
    var photo: ImageEdit {
        get { selectedPhoto.flatMap { photoEdits[$0] } ?? singlePhoto }
        set {
            if let selectedPhoto { photoEdits[selectedPhoto] = newValue } else { singlePhoto = newValue }
        }
    }
    var resolution = 0
    var segments: [VideoSegment] = []
    var selectedID: UUID?

    var selectedIndex: Int? { segments.firstIndex { $0.id == selectedID } }
    var start: Double {
        get { selectedIndex.map { segments[$0].start } ?? 0 }
        set { if let selectedIndex { segments[selectedIndex].start = newValue } }
    }
    var end: Double {
        get { selectedIndex.map { segments[$0].end } ?? 0 }
        set { if let selectedIndex { segments[selectedIndex].end = newValue } }
    }
    var speed: Double {
        get { selectedIndex.map { segments[$0].speed } ?? 1 }
        set { if let selectedIndex { segments[selectedIndex].speed = newValue } }
    }
    var volume: Double {
        get { selectedIndex.map { segments[$0].volume } ?? 1 }
        set { if let selectedIndex { segments[selectedIndex].volume = newValue } }
    }
    var fadeIn: Double {
        get { selectedIndex.map { segments[$0].fadeIn } ?? 0 }
        set { if let selectedIndex { segments[selectedIndex].fadeIn = newValue } }
    }
    var fadeOut: Double {
        get { selectedIndex.map { segments[$0].fadeOut } ?? 0 }
        set { if let selectedIndex { segments[selectedIndex].fadeOut = newValue } }
    }
    var videoAdjustments: MediaAdjustments {
        get { selectedIndex.map { segments[$0].adjustments } ?? MediaAdjustments() }
        set { if let selectedIndex { segments[selectedIndex].adjustments = newValue } }
    }
    var video: VideoEdit {
        var edit = VideoEdit(start: 0, end: segments.map(\.end).max() ?? 0, trimMode: .exact)
        edit.geometry = photo.geometry
        edit.resize = resolution == 0 ? nil : .lines(resolution)
        edit.segments = segments
        edit.sources = sources.isEmpty ? nil : sources
        edit.sourceStamp = photo.sourceStamp
        return edit
    }
}

@Observable @MainActor
final class MediaEditorModel {
    var url: URL { values.selectedPhoto ?? initialURLs[0] }
    let initialURLs: [URL]
    let isVideo: Bool
    let settings: Engine.Settings
    private let staging: StagingArea
    var values = EditorValues()
    var category: EditorCategory
    var original = false
    var zoom = 1.0
    var timelineZoom = 1.0
    var timelineViewportWidth = 600.0
    var hoverPosition: Double?
    var cropAspect = 0.0
    var cropPortrait = false
    var position = 0.0
    var duration = 0.0
    var frameDuration = 1.0 / 30
    var sourceSize = CGSize.zero
    var containsHDR = false
    var requiresNewFile = false
    var requiresSDRForGeometry = false
    var hasAudio = false
    var ready = false
    var preparingPlayback = false
    var splitting = false
    var failure: String?
    var invalidFields: Set<String> = []
    var image: CGImage?
    var thumbnails: [CGImage] = []
    private var sourceThumbnails: [URL: [CGImage]] = [:]
    private var thumbnailOrder: [URL] = []
    var player: AVPlayer?
    var playing = false
    var loops = false
    private(set) var playbackRate: Float = 1
    private var sourceWaveforms: [URL: AudioWaveformSnapshot] = [:]
    private var waveformsUnavailable: Set<URL> = []
    private var waveformTask: Task<Void, Never>?
    var playerReady = false
    var muted = false
    private var photoSource: PhotoEditorSource?
    private var videoSource: VideoEditorSource?
    private var videoSources: [URL: VideoEditorSource] = [:]
    private var videoDetails: [URL: VideoEditorDetails] = [:]
    var selectedPhotos: Set<URL> = []
    private var photoCache: [URL: CGImage] = [:]
    private var photoCacheOrder: [URL] = []
    private var selectionTask: Task<Void, Never>?
    var importing = false
    var loadingPhoto = false
    private var baseline = EditorValues()
    private var undoValues: [EditorValues] = []
    private var redoValues: [EditorValues] = []
    private var interactionStart: EditorValues?
    private var closed = false
    private var timeObserver: Any?
    private var playbackEndObserver: (any NSObjectProtocol)?
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var splitTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var desiredSeek: Double?
    private var trimBaseline: VideoTimeline?
    private var trimSegment: VideoSegment?
    private var trimStartBoundary = false
    private var requestedTrim: Double?
    private var trimTask: Task<Void, Never>?
    private var trimRevision = 0
    private var boundaryInputTask: Task<Void, Never>?
    private var boundaryInputGeneration = 0
    private var revision = 0
    private var preparedEdit: VideoEdit?
    private var renderedRevision = -1
    private static let previewTimescale: CMTimeScale = 1_000_000_000
    private static let maximumCachedPhotos = 3
    private static let maximumCachedVideoSources = 8
    private static let maximumCachedPhotoDimension = 1600

    init(url: URL, isVideo: Bool, settings: Engine.Settings, staging: StagingArea) {
        self.initialURLs = [url]
        self.isVideo = isVideo
        self.settings = settings
        self.staging = staging
        category = isVideo ? .video : .adjust
    }

    convenience init(urls: [URL], isVideo: Bool, settings: Engine.Settings, staging: StagingArea) {
        self.init(url: urls[0], isVideo: isVideo, settings: settings, staging: staging)
        initialSelection(urls)
    }

    private func initialSelection(_ urls: [URL]) {
        openingURLs = urls
        selectedPhotos = Set(urls.prefix(1))
    }

    private var openingURLs: [URL] = []
    var photoURLs: [URL] { openingURLs.isEmpty ? initialURLs : openingURLs }
    var sourceDuration: Double {
        guard let index = values.selectedIndex else { return duration }
        let sourceIndex = values.segments[index].sourceIndex
        return values.sources.indices.contains(sourceIndex) ? values.sources[sourceIndex].duration : duration
    }
    var selectedHasAudio: Bool {
        guard let index = values.selectedIndex, values.sources.indices.contains(values.segments[index].sourceIndex)
        else { return hasAudio }
        return videoDetails[values.sources[values.segments[index].sourceIndex].url]?.hasAudio == true
    }
    var sourceFrameDuration: Double {
        guard let index = values.selectedIndex, values.sources.indices.contains(values.segments[index].sourceIndex)
        else { return frameDuration }
        return videoDetails[values.sources[values.segments[index].sourceIndex].url]?.frameDuration ?? frameDuration
    }
    private func source(for segment: VideoSegment) -> VideoEditorSource? {
        guard values.sources.indices.contains(segment.sourceIndex) else { return videoSource }
        return videoSources[values.sources[segment.sourceIndex].url]
    }
    var timeline: VideoTimeline? { try? VideoTimeline(edit: values.video, sourceDuration: duration) }
    var outputDuration: Double { timeline?.duration ?? 0 }
    var timelineDuration: Double { trimBaseline?.duration ?? outputDuration }
    var maximumTimelineZoom: Double {
        let speed = values.selectedIndex.map { values.segments[$0].speed } ?? 1
        return max(
            timelineZoom,
            MediaTimeline.maximumZoom(
                duration: timelineDuration, viewport: timelineViewportWidth, interval: sourceFrameDuration / speed))
    }
    var trimming: Bool { trimSegment != nil }

    func timelineRange(for segment: VideoSegment) -> ClosedRange<Double> {
        let reference = trimBaseline ?? timeline
        guard let reference,
            let original = reference.segments.first(where: { $0.id == segment.id }),
            let start = reference.outputTime(for: original.start, segmentID: segment.id)
        else { return 0...0 }
        let left = start + (segment.start - original.start) / segment.speed
        let right = start + (segment.end - original.start) / segment.speed
        return left...max(left, right)
    }

    func zoomTimeline(by factor: Double) {
        timelineZoom = min(maximumTimelineZoom, max(1, timelineZoom * factor))
    }
    private var lastPlayablePosition: Double {
        let end = CMTime(seconds: outputDuration, preferredTimescale: Self.previewTimescale)
        let tick = CMTime(value: 1, timescale: Self.previewTimescale)
        return max(0, (end - tick).seconds)
    }
    var hasSelection: Bool { values.selectedIndex != nil }
    var canUndo: Bool { !undoValues.isEmpty }
    var canRedo: Bool { !redoValues.isEmpty }
    var changesColor: Bool {
        isVideo ? values.segments.contains { !$0.adjustments.isIdentity } : values.photo.changesColor
    }
    var adjustments: MediaAdjustments { isVideo ? values.videoAdjustments : values.photo.adjustments }
    var convertsToSDR: Bool {
        containsHDR
            && (isVideo && values.sources.count > 1 || changesColor
                || !isVideo && (requiresSDRForGeometry || values.photo.geometry.straighten != 0))
    }
    var savesNewFile: Bool {
        values.sources.count > 1 || requiresNewFile || containsHDR && changesColor || settings.outputMode == .newFile
    }
    var outputSize: CGSize {
        guard (try? values.photo.geometry.validate()) != nil else { return .zero }
        let geometry = values.photo.geometry.outputSize(sourceSize)
        guard isVideo else { return geometry }
        let resize = values.resolution == 0 ? VideoResize.percent(100) : .lines(values.resolution)
        guard let size = try? resize.dimensions(width: Int(geometry.width), height: Int(geometry.height)) else {
            return .zero
        }
        return CGSize(width: max(2, size.width / 2 * 2), height: max(2, size.height / 2 * 2))
    }
    var previewSize: CGSize {
        if original { return sourceSize }
        var geometry = values.photo.geometry
        if category == .crop { geometry.crop = EditCrop() }
        return geometry.outputSize(sourceSize)
    }
    var canPlay: Bool { ready && !values.segments.isEmpty && player != nil && !preparingPlayback && failure == nil }
    var canSplit: Bool { values.selectedID.map(canSplitSegment) ?? false }

    func canSplitSegment(_ id: UUID) -> Bool {
        guard !splitting, let timeline, !values.segments.isEmpty else { return false }
        let segment = timeline.segment(at: position)
        guard segment.id == id else { return false }
        let source = timeline.sourceTime(at: position)
        return source > segment.start && source < segment.end
    }

    var canSave: Bool {
        guard ready, !closed, failure == nil, invalidFields.isEmpty, !preparingPlayback, !splitting, !importing,
            !loadingPhoto, boundaryInputTask == nil,
            renderedRevision == revision,
            (try? values.photo.validate()) != nil
        else { return false }
        if !isVideo { return values.photoEdits.values.contains { !$0.isIdentity } }
        guard timeline != nil, !values.segments.isEmpty else { return false }
        return values.sources.count > 1 || values.video != baseline.video
    }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task {
            do {
                if isVideo {
                    let source = try await VideoEditorSource.open(url, staging: staging)
                    videoSource = source
                    videoSources[url] = source
                    let details = await source.details
                    videoDetails[url] = details
                    sourceSize = details.size
                    duration = details.duration
                    frameDuration = details.frameDuration
                    hasAudio = details.hasAudio
                    containsHDR = details.containsHDR
                    let segment = VideoSegment(start: 0, end: duration)
                    values.segments = [segment]
                    values.selectedID = segment.id
                    values.photo.sourceStamp = details.stamp
                    values.sources = [VideoEditSource(url: url, duration: details.duration, stamp: details.stamp)]
                    for additional in photoURLs.dropFirst() { try await appendVideo(additional, recordingUndo: false) }
                } else {
                    for photo in photoURLs {
                        var edit = ImageEdit()
                        edit.sourceStamp = try MediaSourceStamp(url: photo)
                        values.photoEdits[photo] = edit
                    }
                    values.selectedPhoto = photoURLs.first
                    let source = try await PhotoEditorSource.open(url)
                    photoSource = source
                    let details = await source.details
                    sourceSize = details.size
                    containsHDR = details.containsHDR
                    requiresNewFile = details.requiresNewFile
                    requiresSDRForGeometry = details.requiresSDRForGeometry
                    values.photo.sourceStamp = details.stamp
                }
                try Task.checkCancellation()
                baseline = values
                ready = true
                refresh()
            } catch is CancellationError { return } catch { report(error) }
        }
    }

    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<EditorValues, Value>) -> Binding<Value> {
        Binding(get: { self.values[keyPath: keyPath] }, set: { value in self.change { $0[keyPath: keyPath] = value } })
    }

    func adjustmentBinding<Value: Equatable>(_ keyPath: WritableKeyPath<MediaAdjustments, Value>) -> Binding<Value> {
        Binding(
            get: { self.adjustments[keyPath: keyPath] },
            set: { value in
                self.change {
                    if self.isVideo {
                        $0.videoAdjustments[keyPath: keyPath] = value
                    } else {
                        $0.photo.adjustments[keyPath: keyPath] = value
                    }
                }
            })
    }

    func change(_ mutation: (inout EditorValues) -> Void) {
        let previous = values
        var edited = previous
        mutation(&edited)
        guard previous != edited else { return }
        values = edited
        hoverPosition = nil
        if interactionStart == nil { remember(previous) }
        position = min(position, lastPlayablePosition)
        pause()
        failure = nil
        refresh()
    }

    func selectSegment(_ id: UUID) {
        endInteraction()
        values.selectedID = id
        invalidFields.removeAll()
        if let segment = values.segments.first(where: { $0.id == id }), thumbnails(for: segment).isEmpty { refresh() }
    }

    func beginTimelineTrim(_ id: UUID, start: Bool) {
        guard !trimming, let timeline, let segment = values.segments.first(where: { $0.id == id }) else { return }
        selectSegment(id)
        beginInteraction()
        trimBaseline = timeline
        trimSegment = segment
        trimStartBoundary = start
        hoverPosition = nil
    }

    func updateTimelineTrim(to seconds: Double) {
        guard let original = trimSegment, let baseline = trimBaseline,
            let offset = baseline.outputTime(for: original.start, segmentID: original.id)
        else { return }
        requestedTrim = original.start + (seconds - offset) * original.speed
        trimRevision += 1
        guard trimTask == nil else { return }
        trimTask = Task {
            defer { trimTask = nil }
            while let request = requestedTrim, !closed, !Task.isCancelled {
                requestedTrim = nil
                let generation = trimRevision
                do {
                    let boundary = try await snappedVideoBoundary(request, segment: original, start: trimStartBoundary)
                    try Task.checkCancellation()
                    guard !closed, generation == trimRevision, let boundary,
                        let index = values.segments.firstIndex(where: { $0.id == original.id })
                    else { continue }
                    let starts = trimStartBoundary
                    change { values in
                        if starts {
                            values.segments[index].start = boundary
                        } else {
                            values.segments[index].end = boundary
                        }
                    }
                } catch is CancellationError { return } catch { report(error); return }
            }
        }
    }

    private func snappedVideoBoundary(_ requested: Double, segment: VideoSegment, start: Bool) async throws -> Double? {
        guard let actor = source(for: segment) else { return nil }
        let sourceDuration =
            values.sources.indices.contains(segment.sourceIndex)
            ? values.sources[segment.sourceIndex].duration : duration
        let lower = start ? 0 : segment.start.nextUp
        let upper = start ? segment.end : sourceDuration
        let target = min(upper, max(lower, requested))
        if !start, target == sourceDuration { return sourceDuration }
        if !start, target == lower {
            return try await actor.adjacentFrameTime(to: segment.start, forward: true)
        }
        return try await actor.nearestFrameTime(to: target, within: lower..<upper)
    }

    func videoBoundaryBinding(start: Bool) -> Binding<Double> {
        Binding(get: { start ? self.values.start : self.values.end }, set: { self.setVideoBoundary($0, start: start) })
    }

    func setVideoBoundary(_ seconds: Double, start: Bool) {
        guard seconds.isFinite, let index = values.selectedIndex else { return }
        let segment = values.segments[index]
        boundaryInputTask?.cancel()
        boundaryInputGeneration += 1
        let generation = boundaryInputGeneration
        boundaryInputTask = Task {
            defer { if generation == boundaryInputGeneration { boundaryInputTask = nil } }
            do {
                let boundary = try await snappedVideoBoundary(seconds, segment: segment, start: start)
                try Task.checkCancellation()
                guard !closed, generation == boundaryInputGeneration, values.selectedID == segment.id,
                    let boundary, let current = values.segments.firstIndex(where: { $0.id == segment.id })
                else { return }
                change {
                    if start { $0.segments[current].start = boundary } else { $0.segments[current].end = boundary }
                }
            } catch is CancellationError { return } catch { report(error) }
        }
    }

    func finishBoundaryInput() async { await boundaryInputTask?.value }

    func endTimelineTrim() async {
        await trimTask?.value
        trimSegment = nil
        trimBaseline = nil
        requestedTrim = nil
        endInteraction()
        position = min(position, lastPlayablePosition)
        refresh()
    }

    func setTrimBoundaryAtPlayhead(start: Bool) {
        guard !trimming, let id = values.selectedID else { return }
        let boundary = position
        beginTimelineTrim(id, start: start)
        updateTimelineTrim(to: boundary)
        Task { await endTimelineTrim() }
    }

    func split() {
        guard canSplit, let timeline else { return }
        guard let videoSource = source(for: timeline.segment(at: position)) else { return }
        pause()
        let segment = timeline.segment(at: position)
        let requestedPosition = position
        let generation = revision
        let seconds = timeline.sourceTime(at: position)
        splitTask?.cancel()
        splitting = true
        splitTask = Task {
            defer { splitting = false }
            do {
                let boundary = try await videoSource.nearestFrameTime(
                    to: seconds, within: segment.start.nextUp..<segment.end)
                try Task.checkCancellation()
                guard !closed, revision == generation, values.selectedID == segment.id, position == requestedPosition,
                    let boundary, let index = values.segments.firstIndex(where: { $0.id == segment.id }),
                    let snappedPosition = timeline.outputTime(for: boundary, segmentID: segment.id)
                else { return }
                change {
                    var right = segment
                    right.id = UUID()
                    right.start = boundary
                    right.fadeIn = 0
                    $0.segments[index].end = boundary
                    $0.segments[index].fadeOut = 0
                    $0.segments.insert(right, at: index + 1)
                    $0.selectedID = right.id
                }
                position = snappedPosition
                requestSeek()
            } catch is CancellationError { return } catch {
                if !closed, revision == generation, values.selectedID == segment.id, position == requestedPosition {
                    report(error)
                }
            }
        }
    }

    func deleteSelection() {
        guard let index = values.selectedIndex else { return }
        let segment = values.segments[index]
        let start = timeline?.outputTime(for: segment.start, segmentID: segment.id) ?? 0
        let removedDuration = (segment.end - segment.start) / segment.speed
        let nextPosition = position < start ? position : max(start, position - removedDuration)
        change {
            $0.segments.remove(at: index)
            $0.selectedID = $0.segments.isEmpty ? nil : $0.segments[min(index, $0.segments.count - 1)].id
        }
        position = min(nextPosition, lastPlayablePosition)
        requestSeek()
    }

    func duplicateSelection() {
        guard let index = values.selectedIndex else { return }
        change {
            var duplicate = $0.segments[index]
            duplicate.id = UUID()
            $0.segments.insert(duplicate, at: index + 1)
            $0.selectedID = duplicate.id
        }
    }

    func moveSelection(_ offset: Int) {
        guard let index = values.selectedIndex else { return }
        moveSegment(values.segments[index].id, to: index + offset)
    }

    func moveSegment(_ id: UUID, to destination: Int) {
        guard let index = values.segments.firstIndex(where: { $0.id == id }),
            values.segments.indices.contains(destination),
            index != destination
        else { return }
        change {
            let segment = $0.segments.remove(at: index)
            $0.segments.insert(segment, at: destination)
            $0.selectedID = id
        }
    }

    func beginInteraction() {
        if interactionStart == nil { interactionStart = values }
        pause()
    }

    func endInteraction() {
        if boundaryInputTask != nil {
            Task {
                await finishBoundaryInput()
                if !closed { endInteraction() }
            }
            return
        }
        if let previous = interactionStart, previous != values { remember(previous) }
        interactionStart = nil
        if !isVideo { refresh() }
    }

    private func remember(_ previous: EditorValues) {
        undoValues.append(previous)
        if undoValues.count > 100 { undoValues.removeFirst() }
        redoValues.removeAll()
    }

    func undo() {
        endInteraction()
        guard let previous = undoValues.popLast() else { return }
        redoValues.append(values)
        values = previous
        restore()
    }

    func redo() {
        guard let next = redoValues.popLast() else { return }
        undoValues.append(values)
        values = next
        restore()
    }

    private func restore() {
        invalidFields.removeAll()
        if isVideo {
            containsHDR = values.sources.contains { videoDetails[$0.url]?.containsHDR == true }
            hasAudio = values.sources.contains { videoDetails[$0.url]?.hasAudio == true }
        }
        synchronizeCropAspect()
        if !isVideo, let selected = values.selectedPhoto {
            if !selectedPhotos.contains(selected) { selectedPhotos = [selected] }
            selectPhoto(selected, force: true)
        }
        position = min(position, lastPlayablePosition)
        pause()
        failure = nil
        refresh()
    }

    func reset() {
        change { $0 = baseline }
        restore()
        cropAspect = 0
    }

    func seek(_ seconds: Double) {
        pause()
        hoverPosition = nil
        player?.isMuted = muted
        position = min(max(0, seconds), lastPlayablePosition)
        requestSeek()
    }

    func skim(_ seconds: Double?) {
        guard !playing, !trimming else { return }
        hoverPosition = seconds.map { min(max(0, $0), lastPlayablePosition) }
        player?.isMuted = hoverPosition != nil || muted
        requestSeek(to: hoverPosition ?? position)
    }

    private func requestSeek(to seconds: Double? = nil) {
        desiredSeek = seconds ?? position
        guard seekTask == nil, let player, !preparingPlayback else { return }
        seekTask = Task {
            defer { seekTask = nil }
            while let destination = desiredSeek, !closed, !Task.isCancelled {
                desiredSeek = nil
                let target = CMTime(seconds: destination, preferredTimescale: Self.previewTimescale)
                let current = player.currentTime().convertScale(Self.previewTimescale, method: .roundHalfAwayFromZero)
                if current == target { continue }
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func stepFrame(_ count: Int) {
        pause()
        guard let timeline, !values.segments.isEmpty else { return }
        let segment = timeline.segment(at: position)
        guard let videoSource = source(for: segment) else { return }
        let seconds = timeline.sourceTime(at: position)
        let forward = count > 0
        playbackTask = Task {
            do {
                let timestamp = try await videoSource.adjacentFrameTime(to: seconds, forward: forward)
                let timestampTolerance = 1e-9
                let progresses =
                    forward ? timestamp > seconds + timestampTolerance : timestamp < seconds - timestampTolerance
                let output: Double?
                if progresses, timestamp >= segment.start, timestamp < segment.end {
                    output = timeline.outputTime(for: timestamp, segmentID: segment.id)
                } else if let index = timeline.segments.firstIndex(where: { $0.id == segment.id }),
                    timeline.segments.indices.contains(index + (forward ? 1 : -1))
                {
                    let adjacent = timeline.segments[index + (forward ? 1 : -1)]
                    guard let adjacentSource = source(for: adjacent) else { return }
                    var boundary = try await adjacentSource.adjacentFrameTime(
                        to: forward ? adjacent.start : adjacent.end, forward: false)
                    if forward, boundary < adjacent.start {
                        boundary = try await adjacentSource.adjacentFrameTime(to: boundary, forward: true)
                    }
                    output =
                        boundary >= adjacent.start && boundary < adjacent.end
                        ? timeline.outputTime(for: boundary, segmentID: adjacent.id) : nil
                } else {
                    output = nil
                }
                try Task.checkCancellation()
                guard !closed, let output else { return }
                seek(output)
            } catch is CancellationError { return } catch { if !closed { report(error) } }
        }
    }

    func pause() {
        playbackTask?.cancel()
        player?.pause()
        playing = false
        playbackRate = 1
    }

    func toggleMute() {
        muted.toggle()
        player?.isMuted = muted || playing && abs(playbackRate) > Self.audibleShuttleRate
    }

    func play() {
        if playing { pause(); return }
        start(rate: 1)
    }

    /// J/K/L; repeated presses double the rate.
    func shuttle(_ direction: Int) {
        guard direction != 0 else { pause(); return }
        let continuing = playing && (playbackRate > 0) == (direction > 0)
        let magnitude = continuing ? min(Self.maximumShuttleRate, abs(playbackRate) * 2) : 1
        let playerItem = player?.currentItem
        let fastest =
            direction > 0
            ? (playerItem?.canPlayFastForward == true ? Self.maximumShuttleRate : Self.audibleShuttleRate)
            : (playerItem?.canPlayFastReverse == true ? Self.maximumShuttleRate : 1)
        let rate = (direction > 0 ? 1 : -1) * min(magnitude, fastest)
        if rate < 0, playerItem?.canPlayReverse != true {
            stepFrame(-1)
            return
        }
        start(rate: rate)
    }

    private static let maximumShuttleRate: Float = 8
    private static let audibleShuttleRate: Float = 2

    private func start(rate: Float) {
        guard canPlay, let player else { return }
        hoverPosition = nil
        player.isMuted = muted || abs(rate) > Self.audibleShuttleRate
        if !playing { requestSeek() }
        if rate > 0, position >= lastPlayablePosition { position = 0; requestSeek() }
        if rate < 0, position <= 0 { return }
        playing = true
        playbackRate = rate
        playbackTask?.cancel()
        playbackTask = Task {
            await seekTask?.value
            guard !Task.isCancelled, !closed else { return }
            player.playImmediately(atRate: rate)
        }
    }

    private func finishPlayback() {
        let reverse = playbackRate < 0
        pause()
        if loops, !reverse { start(rate: 1) }
    }

    func refresh() {
        guard ready, !closed else { return }
        revision += 1
        if isVideo { preparingPlayback = !values.segments.isEmpty }
        guard previewTask == nil else { return }
        previewTask = Task {
            defer { previewTask = nil }
            while !closed, !Task.isCancelled {
                let generation = revision
                do {
                    try await Task.sleep(for: .milliseconds(25))
                    if generation != revision { continue }
                    if isVideo {
                        try await renderVideo(generation: generation)
                    } else if let photoSource {
                        let edit = original ? ImageEdit() : values.photo
                        let maximum = interactionStart == nil ? Int(min(4096, 1600 * zoom)) : 960
                        let cropPreview = category == .crop
                        let rendered = try await photoSource.render(
                            edit, maximumDimension: maximum, cropPreview: cropPreview, allowsSDR: savesNewFile)
                        if generation == revision, !closed { image = rendered }
                    }
                    guard !closed else { return }
                    if generation == revision { renderedRevision = generation; return }
                } catch is CancellationError { return } catch {
                    if generation == revision, !closed { report(error); return }
                }
            }
        }
    }

    private func renderVideo(generation: Int) async throws {
        guard let videoSource else { return }
        guard !values.segments.isEmpty else {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerReady = false
            preparedEdit = nil
            preparingPlayback = false
            return
        }
        var edit = values.video
        if original {
            edit.geometry = EditGeometry()
            edit.segments = edit.segments?.map { segment in
                var segment = segment
                segment.adjustments = MediaAdjustments()
                segment.fadeIn = 0
                segment.fadeOut = 0
                return segment
            }
        } else if category == .crop {
            edit.geometry.crop = EditCrop()
        }
        if preparedEdit != edit {
            let playback: VideoEditorPlayback
            if values.sources.count > 1 {
                var urls: [URL] = []
                for source in values.sources {
                    guard let actor = videoSources[source.url] else { throw CancellationError() }
                    urls.append(try await actor.playbackURL(sdr: true, normalized: true))
                }
                playback = try await VideoEditorPlayback.joined(urls: urls, edit: edit, sourceSize: sourceSize)
            } else {
                playback = try await videoSource.playback(edit: edit)
            }
            try Task.checkCancellation()
            guard generation == revision, !closed else { return }
            let playerItem = AVPlayerItem(asset: playback.asset)
            playerItem.videoComposition = playback.videoComposition
            playerItem.audioMix = playback.audioMix
            playerItem.audioTimePitchAlgorithm = .timeDomain
            if player == nil {
                let player = AVPlayer()
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
                ) { [weak self] time in
                    MainActor.assumeIsolated { self?.playbackAdvanced(time) }
                }
            }
            playerReady = false
            if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
            let identifier = ObjectIdentifier(playerItem)
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let current = self.player?.currentItem, ObjectIdentifier(current) == identifier
                    else { return }
                    self.position = self.outputDuration
                    self.finishPlayback()
                }
            }
            player?.replaceCurrentItem(with: playerItem)
            player?.isMuted = muted
            preparedEdit = edit
            desiredSeek = position
        }
        guard generation == revision, !closed else { return }
        preparingPlayback = false
        requestSeek()
        loadWaveforms()
        await seekTask?.value
        if thumbnailTask == nil {
            let selectedSource = values.selectedIndex.map { values.segments[$0].sourceIndex } ?? 0
            let indices = [selectedSource] + Array(values.sources.indices)
            var scheduled = Set<URL>()
            let prioritized = indices.compactMap { index -> VideoEditSource? in
                guard values.sources.indices.contains(index) else { return nil }
                let source = values.sources[index]
                return scheduled.insert(source.url).inserted ? source : nil
            }.prefix(Self.maximumCachedVideoSources)
            let missing = prioritized.filter { sourceThumbnails[$0.url] == nil }
            if !missing.isEmpty {
                thumbnailTask = Task {
                    defer { thumbnailTask = nil }
                    do {
                        for source in missing {
                            guard let actor = videoSources[source.url] else { continue }
                            let times = (0..<20).map { source.duration * (Double($0) + 0.5) / 20 }
                            let frames = try await actor.frames(at: times, width: 96)
                            try Task.checkCancellation()
                            guard !closed else { return }
                            sourceThumbnails[source.url] = frames
                            thumbnailOrder.removeAll { $0 == source.url }
                            thumbnailOrder.append(source.url)
                            while thumbnailOrder.count > Self.maximumCachedVideoSources {
                                sourceThumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
                            }
                            if source.url == initialURLs[0] { thumbnails = frames }
                        }
                    } catch is CancellationError { return } catch { if !closed { report(error) } }
                }
            }
        }
    }

    /// Segment peaks in timeline seconds.
    func waveform(for segment: VideoSegment, in range: ClosedRange<Double>) -> AudioWaveformSnapshot? {
        guard values.sources.indices.contains(segment.sourceIndex),
            let source = sourceWaveforms[values.sources[segment.sourceIndex].url], source.duration > 0,
            range.upperBound > range.lowerBound
        else { return nil }
        let count = Double(source.peaks.count)
        let first = max(0, min(source.peaks.count - 1, Int(segment.start / source.duration * count)))
        let last = max(first + 1, min(source.peaks.count, Int((segment.end / source.duration * count).rounded(.up))))
        return AudioWaveformSnapshot(
            peaks: Array(source.peaks[first..<last]), start: range.lowerBound,
            duration: range.upperBound - range.lowerBound, sampleRate: source.sampleRate)
    }

    private func loadWaveforms() {
        guard waveformTask == nil else { return }
        let missing = values.sources.filter {
            sourceWaveforms[$0.url] == nil && !waveformsUnavailable.contains($0.url)
                && videoDetails[$0.url]?.hasAudio != false
        }
        guard !missing.isEmpty else { return }
        waveformTask = Task {
            defer { waveformTask = nil }
            for source in missing {
                do {
                    let waveform = try await AudioWaveform.load(videoURL: source.url)
                    try Task.checkCancellation()
                    guard !closed else { return }
                    if let waveform {
                        sourceWaveforms[source.url] = waveform
                    } else {
                        waveformsUnavailable.insert(source.url)
                    }
                } catch is CancellationError { return } catch {
                    waveformsUnavailable.insert(source.url)
                    Logger(category: "editor").error(
                        "Waveform unavailable: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    func thumbnails(for segment: VideoSegment) -> [CGImage] {
        guard values.sources.indices.contains(segment.sourceIndex) else { return thumbnails }
        return sourceThumbnails[values.sources[segment.sourceIndex].url] ?? []
    }

    private func playbackAdvanced(_ time: CMTime) {
        guard playing, time.seconds.isFinite else { return }
        guard player?.rate != 0 else {
            if playbackRate < 0, time.seconds <= frameDuration { position = 0; pause() }
            return
        }
        position = min(max(0, time.seconds), outputDuration)
        if playbackRate > 0, position >= lastPlayablePosition { finishPlayback() }
        if playbackRate < 0, position <= 0 { pause() }
    }

    func validateForSave() throws {
        if isVideo {
            for source in values.sources { try source.stamp.validate(source.url) }
        } else {
            for (url, edit) in values.photoEdits {
                try edit.sourceStamp?.validate(url)
                try edit.validate()
            }
        }
        try values.photo.sourceStamp?.validate(url)
        try values.photo.validate()
        if isVideo { _ = try VideoTimeline(edit: values.video, sourceDuration: duration) }
    }

    func makeBatch() throws -> Batch {
        try validateForSave()
        if isVideo { return MediaEditing.video(url: initialURLs[0], edit: values.video, settings: settings) }
        return MediaEditing.photos(
            photoURLs.compactMap { url in
                guard let edit = values.photoEdits[url], !edit.isIdentity else { return nil }
                return PhotoEditInput(url: url, edit: edit)
            }, settings: settings)
    }

    func selectPhoto(_ url: URL, force: Bool = false) {
        guard !isVideo, force || values.selectedPhoto != url else { return }
        endInteraction()
        if !force, let image, let previous = values.selectedPhoto {
            if max(image.width, image.height) <= Self.maximumCachedPhotoDimension { photoCache[previous] = image }
            photoCacheOrder.removeAll { $0 == previous }
            photoCacheOrder.append(previous)
            while photoCacheOrder.count > Self.maximumCachedPhotos {
                photoCache.removeValue(forKey: photoCacheOrder.removeFirst())
            }
        }
        revision += 1
        loadingPhoto = true
        values.selectedPhoto = url
        invalidFields.removeAll()
        photoSource = nil
        image = photoCache[url]
        selectionTask?.cancel()
        selectionTask = Task {
            defer { if values.selectedPhoto == url { loadingPhoto = false } }
            do {
                let source = try await PhotoEditorSource.open(url)
                let details = await source.details
                try Task.checkCancellation()
                guard !closed, values.selectedPhoto == url else { return }
                photoSource = source
                sourceSize = details.size
                containsHDR = details.containsHDR
                requiresNewFile = details.requiresNewFile
                requiresSDRForGeometry = details.requiresSDRForGeometry
                synchronizeCropAspect()
                failure = nil
                refresh()
            } catch is CancellationError { return } catch { if values.selectedPhoto == url { report(error) } }
        }
    }

    func applyPhotoEdits(toAll: Bool) {
        let selected = toAll ? Set(photoURLs) : selectedPhotos
        let edit = values.photo
        change { values in
            for url in selected {
                guard let stamp = values.photoEdits[url]?.sourceStamp else { continue }
                var copy = edit
                copy.sourceStamp = stamp
                values.photoEdits[url] = copy
            }
        }
        photoCache.removeAll()
        photoCacheOrder.removeAll()
    }

    private func appendVideo(_ url: URL, recordingUndo: Bool) async throws {
        let source: VideoEditorSource
        if let existing = videoSources[url] {
            source = existing
        } else {
            source = try await VideoEditorSource.open(url, staging: staging)
        }
        let details = await source.details
        try Task.checkCancellation()
        guard !closed else { await source.close(); throw CancellationError() }
        let index = values.sources.count
        videoSources[url] = source
        videoDetails[url] = details
        let mutate: (inout EditorValues) -> Void = { values in
            values.sources.append(VideoEditSource(url: url, duration: details.duration, stamp: details.stamp))
            let segment = VideoSegment(start: 0, end: details.duration, sourceIndex: index)
            values.segments.append(segment)
            values.selectedID = segment.id
        }
        if recordingUndo { change(mutate) } else { mutate(&values) }
        hasAudio = hasAudio || details.hasAudio
        containsHDR = containsHDR || details.containsHDR
    }

    func importVideos(_ urls: [URL]) {
        guard !importing else { return }
        importing = true
        selectionTask = Task {
            defer { importing = false }
            do {
                for url in urls { try await appendVideo(url, recordingUndo: true) }
            } catch is CancellationError { return } catch { report(error) }
        }
    }

    func report(_ error: Error) {
        preparingPlayback = false
        failure = UserMessages.describe(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
    }

    func close() async {
        closed = true
        loadTask?.cancel()
        previewTask?.cancel()
        playbackTask?.cancel()
        splitTask?.cancel()
        thumbnailTask?.cancel()
        waveformTask?.cancel()
        seekTask?.cancel()
        trimTask?.cancel()
        boundaryInputTask?.cancel()
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil
        self.timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        await loadTask?.value
        await previewTask?.value
        await playbackTask?.value
        await splitTask?.value
        await thumbnailTask?.value
        await waveformTask?.value
        await seekTask?.value
        await trimTask?.value
        await boundaryInputTask?.value
        selectionTask?.cancel()
        await selectionTask?.value
        for source in videoSources.values { await source.close() }
        videoSources.removeAll()
        photoCache.removeAll()
        photoSource = nil
        videoSource = nil
        image = nil
        thumbnails.removeAll()
        sourceThumbnails.removeAll()
        thumbnailOrder.removeAll()
        sourceWaveforms.removeAll()
    }
}
