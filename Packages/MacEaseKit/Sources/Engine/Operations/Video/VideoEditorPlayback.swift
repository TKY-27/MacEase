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

    static func make(url: URL, timeline: VideoTimeline, edit: VideoEdit, sourceSize: CGSize) async throws
        -> VideoEditorPlayback
    {
        let source = AVURLAsset(url: url)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            throw EngineError.decodeFailed("no playback video track")
        }
        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw EngineError.decodeFailed("cannot create playback video track") }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let sourceAudio = try await source.loadTracks(withMediaType: .audio).first
        let audio: AVMutableCompositionTrack?
        if sourceAudio != nil {
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw EngineError.decodeFailed("cannot create playback audio track") }
            audio = track
        } else {
            audio = nil
        }
        let audioRange = try await sourceAudio?.load(.timeRange)
        let parameters = audio.map { AVMutableAudioMixInputParameters(track: $0) }
        parameters?.audioTimePitchAlgorithm = .timeDomain
        for (index, segment) in timeline.segments.enumerated() {
            try Task.checkCancellation()
            let sourceRange = CMTimeRange(start: time(segment.start), end: time(segment.end))
            let outputStart = time(timeline.outputStart(at: index))
            let outputDuration = time(timeline.outputEnd(at: index)) - outputStart
            let insertedRange = CMTimeRange(start: outputStart, duration: sourceRange.duration)
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: outputStart)
            video.scaleTimeRange(insertedRange, toDuration: outputDuration)
            if let sourceAudio, let audio, let audioRange {
                audio.insertEmptyTimeRange(insertedRange)
                let intersection = CMTimeRangeGetIntersection(sourceRange, otherRange: audioRange)
                if intersection.isValid, intersection.duration > .zero {
                    let start = outputStart + intersection.start - sourceRange.start
                    audio.removeTimeRange(CMTimeRange(start: start, duration: intersection.duration))
                    try audio.insertTimeRange(intersection, of: sourceAudio, at: start)
                }
                audio.scaleTimeRange(insertedRange, toDuration: outputDuration)
                parameters?.setVolume(Float(segment.volume), at: outputStart)
            }
        }
        let mix: AVAudioMix?
        if let parameters {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [parameters]
            guard let snapshot = audioMix.copy() as? AVAudioMix else {
                throw EngineError.decodeFailed("cannot snapshot playback audio mix")
            }
            mix = snapshot
        } else {
            mix = nil
        }
        let videoComposition: AVVideoComposition?
        if edit.changesAppearance {
            videoComposition = try await filtered(composition, timeline: timeline, edit: edit, sourceSize: sourceSize)
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
        _ asset: AVAsset, timeline: VideoTimeline, edit: VideoEdit, sourceSize: CGSize
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
        let filtered = try await AVVideoComposition(applyingFiltersTo: asset) { request in
            let input = request.sourceImage
            let normalized = input.transformed(
                by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
            var image = geometry.applying(to: normalized)
            let adjustments = timeline.segment(at: request.compositionTime.seconds).adjustments
            image = adjustments.applying(to: image)
            image = image.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(size.width) / image.extent.width,
                    y: CGFloat(size.height) / image.extent.height))
            if adjustments.isIdentity { return AVCIImageFilteringResult(resultImage: image) }
            // Match export transfer values before compositor presentation.
            guard
                let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
            else {
                throw EngineError.encodeFailed("video preview rendering failed")
            }
            return AVCIImageFilteringResult(
                resultImage: CIImage(cgImage: rendered, options: [.colorSpace: NSNull()]), ciContext: presentation)
        }
        var configuration = AVVideoComposition.Configuration(
            colorPrimaries: filtered.colorPrimaries,
            colorTransferFunction: filtered.colorTransferFunction,
            colorYCbCrMatrix: filtered.colorYCbCrMatrix,
            customVideoCompositorClass: filtered.customVideoCompositorClass,
            frameDuration: filtered.frameDuration, instructions: filtered.instructions,
            renderSize: CGSize(width: size.width, height: size.height))
        configuration.sourceTrackIDForFrameTiming = filtered.sourceTrackIDForFrameTiming
        return AVVideoComposition(configuration: configuration)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: SampleBuffers.nanosecondScale)
    }
}
