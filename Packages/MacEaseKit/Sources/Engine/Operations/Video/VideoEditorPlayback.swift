import AVFoundation
import CoreImage
import Formats
import Foundation

// Immutable snapshots cross the actor boundary.
public struct VideoEditorPlayback: @unchecked Sendable {
    public let asset: AVAsset
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix?
    public let timeline: VideoTimeline

    public static func joined(urls: [URL], edit: VideoEdit, sourceSize: CGSize) async throws -> VideoEditorPlayback {
        guard let first = edit.sources?.first, urls.count == edit.sources?.count,
            sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0
        else {
            throw EngineError.invalidInput(.emptyInput)
        }
        let timeline = try VideoTimeline(edit: edit, sourceDuration: first.duration)
        return try await make(urls: urls, timeline: timeline, edit: edit, sourceSize: sourceSize)
    }

    static func make(url: URL, timeline: VideoTimeline, edit: VideoEdit, sourceSize: CGSize) async throws
        -> VideoEditorPlayback
    {
        try await make(urls: [url], timeline: timeline, edit: edit, sourceSize: sourceSize)
    }

    private static func make(urls: [URL], timeline: VideoTimeline, edit: VideoEdit, sourceSize: CGSize) async throws
        -> VideoEditorPlayback
    {
        guard let first = urls.first else { throw EngineError.invalidInput(.emptyInput) }
        let source = AVURLAsset(url: first)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            throw EngineError.decodeFailed("no playback video track")
        }
        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw EngineError.decodeFailed("cannot create playback video track") }
        video.naturalTimeScale = compositionTimescale
        video.preferredTransform = urls.count > 1 ? .identity : try await sourceVideo.load(.preferredTransform)
        var audioTracks: [AVMutableCompositionTrack?] = []
        var audioParameters: [AVMutableAudioMixInputParameters?] = []
        for url in urls {
            if try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty {
                audioTracks.append(nil)
                audioParameters.append(nil)
                continue
            }
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw EngineError.decodeFailed("cannot create playback audio track") }
            track.naturalTimeScale = compositionTimescale
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTimePitchAlgorithm = .timeDomain
            audioTracks.append(track)
            audioParameters.append(parameters)
        }

        for (index, segment) in timeline.segments.enumerated() {
            try Task.checkCancellation()
            let audio = audioTracks[segment.sourceIndex]
            let parameters = audioParameters[segment.sourceIndex]
            let asset = AVURLAsset(url: urls[segment.sourceIndex])
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw EngineError.decodeFailed("no playback video track")
            }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let audioRange: CMTimeRange?
            if let range = try await sourceAudio?.load(.timeRange) {
                audioRange = CMTimeRange(start: time(range.start.seconds), end: time(range.end.seconds))
            } else {
                audioRange = nil
            }
            let sourceRange: CMTimeRange
            if segment.freezeDuration != nil {
                // One tick isolates a single source frame.
                let tick = CMTime(value: 1, timescale: compositionTimescale)
                let sliceDuration = CMTimeMinimum(tick, time(segment.end) - time(segment.start))
                sourceRange = CMTimeRange(start: time(segment.start), duration: sliceDuration)
            } else {
                sourceRange = CMTimeRange(start: time(segment.start), end: time(segment.end))
            }
            let outputStart = time(timeline.outputStart(at: index))
            let outputDuration = time(timeline.outputEnd(at: index)) - outputStart
            let insertedRange = CMTimeRange(start: outputStart, duration: sourceRange.duration)
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: outputStart)
            video.scaleTimeRange(insertedRange, toDuration: outputDuration)
            if let audio {
                if segment.freezeDuration != nil {
                    audio.insertEmptyTimeRange(CMTimeRange(start: outputStart, duration: outputDuration))
                    parameters?.setVolume(0, at: outputStart)
                } else {
                    audio.insertEmptyTimeRange(insertedRange)
                    if let sourceAudio, let audioRange {
                        let intersection = CMTimeRangeGetIntersection(sourceRange, otherRange: audioRange)
                        if intersection.isValid, intersection.duration > .zero {
                            let start = outputStart + intersection.start - sourceRange.start
                            audio.removeTimeRange(CMTimeRange(start: start, duration: intersection.duration))
                            try audio.insertTimeRange(intersection, of: sourceAudio, at: start)
                        }
                    }
                    audio.scaleTimeRange(insertedRange, toDuration: outputDuration)
                    let fade = timeline.fade(at: index)
                    let volume = Float(segment.volume)
                    if fade.fadeIn > 0 {
                        parameters?.setVolumeRamp(
                            fromStartVolume: 0, toEndVolume: volume,
                            timeRange: CMTimeRange(start: outputStart, duration: time(fade.fadeIn)))
                    } else {
                        parameters?.setVolume(volume, at: outputStart)
                    }
                    if fade.fadeOut > 0 {
                        parameters?.setVolumeRamp(
                            fromStartVolume: volume, toEndVolume: 0,
                            timeRange: CMTimeRange(
                                start: outputStart + outputDuration - time(fade.fadeOut), duration: time(fade.fadeOut)))
                    }
                }
            }
        }
        let mix: AVAudioMix?
        let parameters = audioParameters.compactMap { $0 }
        if !parameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = parameters
            guard let snapshot = audioMix.copy() as? AVAudioMix else {
                throw EngineError.decodeFailed("cannot snapshot playback audio mix")
            }
            mix = snapshot
        } else {
            mix = nil
        }
        let videoComposition: AVVideoComposition?
        if edit.changesAppearance || urls.count > 1 || timeline.hasFades {
            videoComposition = try await filtered(
                composition, timeline: timeline, edit: edit, sourceSize: sourceSize, urls: urls)
        } else {
            videoComposition = nil
        }
        guard let snapshot = composition.copy() as? AVComposition else {
            throw EngineError.decodeFailed("cannot snapshot playback composition")
        }
        return VideoEditorPlayback(
            asset: snapshot, videoComposition: videoComposition, audioMix: mix, timeline: timeline)
    }

    private static func filtered(
        _ asset: AVAsset, timeline: VideoTimeline, edit: VideoEdit, sourceSize: CGSize, urls: [URL]
    ) async throws -> AVVideoComposition {
        let geometry = edit.geometry
        let original = geometry.outputSize(sourceSize)
        let dimensions = try edit.resize?.dimensions(width: Int(original.width), height: Int(original.height))
        let selected = PixelSize(
            width: dimensions?.width ?? Int(original.width), height: dimensions?.height ?? Int(original.height))
        let size = try VideoResize.lines(720).outputSize(selected).evened()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) else {
            throw EngineError.encodeFailed("video preview color space unavailable")
        }
        let context = CIContext(options: [.cacheIntermediates: false, .outputColorSpace: colorSpace])
        let presentation = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let hasOverlays = !timeline.overlays.isEmpty
        let annotationCache = EditAnnotationCache()
        let fullOutputSize = CGSize(width: selected.width, height: selected.height)
        let source = try await MediaInput.open(urls[0])
        var sourceOrientations: [VideoDisplayOrientation] = []
        var sourceIndexes: [EditorFrameIndex] = []
        for url in urls {
            let input = try await MediaInput.open(url)
            sourceOrientations.append(try input.displayOrientation)
            guard case .asset(_, let track?, _) = input.backend else {
                throw EngineError.decodeFailed("preview source has no native video track")
            }
            sourceIndexes.append(
                EditorFrameIndex(track: track, end: Double(input.duration) / Double(Nanoseconds.perSecond)))
        }
        let orientations = sourceOrientations
        let frameIndexes = sourceIndexes
        let frameSeconds = Double(source.frameDuration) / Double(Nanoseconds.perSecond)
        let renderBounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let filtered = try await AVVideoComposition(applyingFiltersTo: asset) { request in
            let outputTime = request.compositionTime.seconds
            let segment = timeline.segment(at: outputTime)
            let input = request.sourceImage
            let oriented =
                urls.count > 1 ? input.transformed(by: orientations[segment.sourceIndex].pixelTransform) : input
            let normalized = oriented.transformed(
                by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
            var canvas = normalized
            if (edit.sources?.count ?? 0) > 1 {
                let bounds = CGRect(origin: .zero, size: sourceSize)
                let factor = min(bounds.width / canvas.extent.width, bounds.height / canvas.extent.height)
                canvas = canvas.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                canvas = canvas.transformed(
                    by: CGAffineTransform(
                        translationX: (bounds.width - canvas.extent.width) / 2,
                        y: (bounds.height - canvas.extent.height) / 2))
                canvas = canvas.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
            }
            let activeOverlays: [EditOverlay]
            if hasOverlays {
                let sourceRange = try frameIndexes[segment.sourceIndex].range(
                    at: time(timeline.sourceTime(at: outputTime)))
                activeOverlays = timeline.overlays(at: outputTime, sourceRange: sourceRange)
            } else {
                activeOverlays = []
            }
            let canvasSize = canvas.extent.size
            if !activeOverlays.isEmpty { canvas = activeOverlays.redacting(canvas, fullCanvasSize: sourceSize) }
            var image = geometry.applying(to: canvas)
            let adjustments = segment.adjustments
            image = adjustments.applying(to: image)
            image = image.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(size.width) / image.extent.width,
                    y: CGFloat(size.height) / image.extent.height)
            ).cropped(to: renderBounds)
            if let layer = annotationCache.layer(
                for: activeOverlays, size: renderBounds.size, geometry: geometry, canvas: canvasSize,
                fullOutputSize: fullOutputSize)
            {
                image = layer.composited(over: image).cropped(to: renderBounds)
            }
            let fade = timeline.fadeGain(at: outputTime)
            if fade < 1 { image = image.fadedToBlack(fade) }
            if adjustments.isIdentity && !hasOverlays { return AVCIImageFilteringResult(resultImage: image) }
            // Match export transfer values before compositor presentation.
            guard
                let rendered = context.createCGImage(image, from: renderBounds, format: .RGBA8, colorSpace: colorSpace)
            else {
                throw EngineError.encodeFailed("video preview rendering failed")
            }
            return AVCIImageFilteringResult(
                resultImage: CIImage(cgImage: rendered, options: [.colorSpace: NSNull()]), ciContext: presentation)
        }
        // Scaled freeze samples otherwise pause fades.
        let hasFreeze = timeline.segments.contains(where: \.isFreeze)
        let frameDuration = time(frameSeconds)
        var configuration = AVVideoComposition.Configuration(
            colorPrimaries: filtered.colorPrimaries,
            colorTransferFunction: filtered.colorTransferFunction,
            colorYCbCrMatrix: filtered.colorYCbCrMatrix,
            customVideoCompositorClass: filtered.customVideoCompositorClass,
            frameDuration: frameDuration, instructions: filtered.instructions,
            renderSize: CGSize(width: size.width, height: size.height))
        configuration.sourceTrackIDForFrameTiming =
            hasFreeze ? kCMPersistentTrackID_Invalid : filtered.sourceTrackIDForFrameTiming
        return AVVideoComposition(configuration: configuration)
    }

    // Nanosecond timescales overflow CoreMedia audio alignment.
    private static let compositionTimescale: CMTimeScale = 60_000

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: compositionTimescale)
    }
}
