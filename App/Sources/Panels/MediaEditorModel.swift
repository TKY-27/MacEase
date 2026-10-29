import AVFoundation
import CoreImage
import Engine
import Observation
import SwiftUI

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
    var photo = ImageEdit()
    var start = 0.0
    var end = 0.0
    var speed = 1.0
    var resolution = 0
    var volume = 1.0
    var trimMode = TrimMode.exact

    var video: VideoEdit {
        var edit = VideoEdit(
            start: start, end: end, speed: speed,
            resize: resolution == 0 ? nil : .lines(resolution), trimMode: trimMode)
        edit.geometry = photo.geometry
        edit.adjustments = photo.adjustments
        edit.volume = volume
        edit.sourceStamp = photo.sourceStamp
        return edit
    }
}

@Observable @MainActor
final class MediaEditorModel {
    let url: URL
    let isVideo: Bool
    let settings: Engine.Settings
    private let staging: StagingArea
    var values = EditorValues()
    var category: EditorCategory
    var original = false
    var zoom = 1.0
    var timelineZoom = 1.0
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
    var failure: String?
    var invalidFields: Set<String> = []
    var image: CGImage?
    var histogram: EditorHistogram?
    var thumbnails: [CGImage] = []
    var player: AVPlayer?
    var playing = false
    private var photoSource: PhotoEditorSource?
    private var videoSource: VideoEditorSource?
    private var baseline = EditorValues()
    private var undoValues: [EditorValues] = []
    private var redoValues: [EditorValues] = []
    private var interactionStart: EditorValues?
    private var closed = false
    private var playbackURL: URL?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var revision = 0
    private var videoOutput: AVPlayerItemVideoOutput?
    private var lastHistogramTime = -1.0
    private var exactFrame = false
    private var preparedGeometry: EditGeometry?
    private var preparedAdjustments: MediaAdjustments?
    private var renderedRevision = -1

    init(url: URL, isVideo: Bool, settings: Engine.Settings, staging: StagingArea) {
        self.url = url
        self.isVideo = isVideo
        self.settings = settings
        self.staging = staging
        category = isVideo ? .video : .adjust
        values.trimMode = settings.video.trimMode
    }

    var canUndo: Bool { !undoValues.isEmpty }
    var canRedo: Bool { !redoValues.isEmpty }
    var changesColor: Bool { isVideo ? !values.photo.adjustments.isIdentity : values.photo.changesColor }
    var convertsToSDR: Bool {
        containsHDR && (changesColor || !isVideo && (requiresSDRForGeometry || values.photo.geometry.straighten != 0))
    }
    var savesNewFile: Bool { requiresNewFile || containsHDR && changesColor || settings.outputMode == .newFile }
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

    var canSave: Bool {
        guard ready, !closed, failure == nil, invalidFields.isEmpty, !preparingPlayback, renderedRevision == revision,
            (try? values.photo.validate()) != nil
        else { return false }
        if !isVideo { return !values.photo.isIdentity }
        return values.start.isFinite && values.end.isFinite && values.speed.isFinite
            && VideoEdit.speedRange.contains(values.speed) && (0...1).contains(values.volume)
            && values.start >= 0 && values.end <= duration && values.end > values.start
            && (values.start != 0 || values.end != duration || values.speed != 1 || values.video.changesAppearance
                || hasAudio && values.volume != 1 || values.resolution > 0 && outputSize != sourceSize)
    }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task {
            do {
                if isVideo {
                    let source = try await VideoEditorSource.open(url, staging: staging)
                    videoSource = source
                    let details = await source.details
                    sourceSize = details.size
                    duration = details.duration
                    frameDuration = details.frameDuration
                    hasAudio = details.hasAudio
                    containsHDR = details.containsHDR
                    values.end = duration
                    values.photo.sourceStamp = details.stamp
                    let times = (0..<20).map { duration * (Double($0) + 0.5) / 20 }
                    thumbnails = try await source.frames(at: times, width: 96)
                } else {
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
            } catch is CancellationError {
                return
            } catch { report(error) }
        }
    }

    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<EditorValues, Value>) -> Binding<Value> {
        Binding(
            get: { self.values[keyPath: keyPath] },
            set: { value in
                self.change { $0[keyPath: keyPath] = value }
            })
    }

    func change(_ mutation: (inout EditorValues) -> Void) {
        let previous = values
        mutation(&values)
        guard previous != values else { return }
        if interactionStart == nil { remember(previous) }
        pause()
        failure = nil
        refresh()
    }

    func beginInteraction() {
        if interactionStart == nil { interactionStart = values }
        pause()
    }

    func endInteraction() {
        if let previous = interactionStart, previous != values { remember(previous) }
        interactionStart = nil
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
        synchronizeCropAspect()
        pause()
        failure = nil
        refresh()
    }

    func redo() {
        guard let next = redoValues.popLast() else { return }
        undoValues.append(values)
        values = next
        synchronizeCropAspect()
        pause()
        failure = nil
        refresh()
    }

    func reset() {
        change { $0 = baseline }
        cropAspect = 0
    }

    func seek(_ seconds: Double) {
        pause()
        exactFrame = false
        position = min(max(0, seconds), max(0, duration - frameDuration))
        player?.seek(
            to: CMTime(seconds: position, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        refresh()
    }

    func stepFrame(_ count: Int) {
        pause()
        guard let videoSource else { return }
        let seconds = position
        playbackTask = Task {
            do {
                let timestamp = try await videoSource.adjacentFrameTime(to: seconds, forward: count > 0)
                try Task.checkCancellation()
                guard !closed else { return }
                let completed = await player?.seek(
                    to: CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                guard completed == true, !Task.isCancelled, !closed else { return }
                position = timestamp
                exactFrame = true
                refresh()
            } catch is CancellationError { return } catch { if !closed { report(error) } }
        }
    }

    func pause() {
        playbackTask?.cancel()
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        playing = false
    }

    func play() {
        guard let player, !preparingPlayback else { return }
        if playing { pause(); refresh(); return }
        let start = position >= values.start && position < values.end - frameDuration ? position : values.start
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: values.end, preferredTimescale: 60_000)
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        player.volume = Float(values.volume)
        playbackTask?.cancel()
        playbackTask = Task {
            let completed = await player.seek(
                to: CMTime(seconds: start, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard completed, !Task.isCancelled, !closed else { return }
            exactFrame = false
            playing = true
            player.playImmediately(atRate: Float(values.speed))
        }
    }

    func refresh() {
        guard ready, !closed else { return }
        revision += 1
        let generation = revision
        var edit = original ? ImageEdit() : values.photo
        if category == .crop { edit.geometry.crop = EditCrop() }
        var video = values.video
        video.geometry = edit.geometry
        video.adjustments = edit.adjustments
        let position = position
        let exactFrame = exactFrame
        let maximumDimension = Int(min(4096, 1600 * zoom))
        let needsPlayback =
            isVideo && (player == nil || preparedGeometry != video.geometry || preparedAdjustments != video.adjustments)
        preparingPlayback = needsPlayback
        let previous = previewTask
        previous?.cancel()
        previewTask = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(35))
                let rendered: CGImage
                if let photoSource {
                    rendered = try await photoSource.render(
                        edit, maximumDimension: maximumDimension, allowsSDR: savesNewFile)
                } else if let videoSource,
                    let frame = try await videoSource.frames(
                        at: [position], width: 1280, edit: video, exactFrame: exactFrame
                    ).first
                {
                    rendered = frame
                } else {
                    throw EngineError.decodeFailed("editor preview unavailable")
                }
                let histogram = try await Task.detached { try EditorHistogram.read(rendered) }.value
                try Task.checkCancellation()
                guard generation == revision, !closed else { return }
                image = rendered
                self.histogram = histogram
                if needsPlayback { try await preparePlayer(edit: video, generation: generation) }
                if generation == revision { renderedRevision = generation }
            } catch is CancellationError { return } catch { if generation == revision && !closed { report(error) } }
        }
    }

    private func preparePlayer(edit: VideoEdit, generation: Int) async throws {
        guard let videoSource else { return }
        preparingPlayback = true
        defer { if generation == revision { preparingPlayback = false } }
        let playbackURL = try await videoSource.playbackURL(sdr: !edit.adjustments.isIdentity)
        try Task.checkCancellation()
        guard generation == revision, !closed else { return }
        let asset = AVURLAsset(url: playbackURL)
        let filtered = try await AVVideoComposition(applyingFiltersTo: asset) { request in
            let transformed = edit.adjustments.applying(to: edit.geometry.applying(to: request.sourceImage))
            return AVCIImageFilteringResult(resultImage: transformed)
        }
        let configuration = AVVideoComposition.Configuration(
            colorPrimaries: filtered.colorPrimaries, colorTransferFunction: filtered.colorTransferFunction,
            colorYCbCrMatrix: filtered.colorYCbCrMatrix,
            customVideoCompositorClass: filtered.customVideoCompositorClass,
            frameDuration: filtered.frameDuration, instructions: filtered.instructions,
            renderSize: edit.geometry.outputSize(filtered.renderSize),
            sourceSampleDataTrackIDs: filtered.sourceSampleDataTrackIDs,
            sourceTrackIDForFrameTiming: filtered.sourceTrackIDForFrameTiming)
        let composition = AVVideoComposition(configuration: configuration)
        try Task.checkCancellation()
        guard generation == revision, !closed else { return }
        if self.playbackURL != playbackURL || player == nil {
            detachPlayer()
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.videoComposition = composition
            let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            playerItem.add(videoOutput)
            self.videoOutput = videoOutput
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            self.playbackURL = playbackURL
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.playbackAdvanced(time) }
            }
        } else {
            player?.currentItem?.videoComposition = composition
        }
        preparedGeometry = edit.geometry
        preparedAdjustments = edit.adjustments
        player?.volume = Float(values.volume)
        await player?.seek(
            to: CMTime(seconds: position, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func playbackAdvanced(_ time: CMTime) {
        guard playing, time.seconds.isFinite else { return }
        position = min(time.seconds, duration)
        if position >= values.end - frameDuration / 2 || player?.rate == 0 {
            pause()
            refresh()
        }
        guard abs(position - lastHistogramTime) >= 0.5, histogramTask == nil,
            let videoOutput, videoOutput.hasNewPixelBuffer(forItemTime: time),
            let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        lastHistogramTime = position
        let frame = CIImage(cvPixelBuffer: buffer)
        let generation = revision
        histogramTask = Task {
            defer { histogramTask = nil }
            do {
                let result = try await Task.detached {
                    let scale = min(1, 256 / max(frame.extent.width, frame.extent.height))
                    let scaled = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else {
                        throw EngineError.encodeFailed("histogram preview")
                    }
                    return try EditorHistogram.read(image)
                }.value
                if !closed, playing, generation == revision { histogram = result }
            } catch { if !closed { report(error) } }
        }
    }

    func validateForSave() throws {
        try values.photo.sourceStamp?.validate(url)
        try values.photo.validate()
    }

    func report(_ error: Error) {
        preparingPlayback = false
        failure = UserMessages.describe(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
    }

    private func detachPlayer() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        videoOutput = nil
    }

    func close() async {
        closed = true
        loadTask?.cancel()
        previewTask?.cancel()
        playbackTask?.cancel()
        histogramTask?.cancel()
        detachPlayer()
        await loadTask?.value
        await previewTask?.value
        await playbackTask?.value
        await histogramTask?.value
        await videoSource?.close()
        photoSource = nil
        videoSource = nil
        image = nil
        thumbnails.removeAll()
    }
}
