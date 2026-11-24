import AVFoundation
import CoreGraphics
import Engine
import Foundation

func benchmarkReverse(_ source: URL, start: Double = 0, seconds: Double = VideoSegmentReverser.maximumSegmentSeconds)
    async throws
{
    let support = FileManager.default.temporaryDirectory.appending(path: "ReverseBench-\(UUID())")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let staging = StagingArea(supportDirectory: support)
    let segment = VideoSegment(start: start, end: start + seconds)
    var edit = VideoEdit()
    edit.segments = [segment]
    let editor = try await VideoEditorSource.open(source, staging: staging)
    let start = ContinuousClock.now
    _ = try await editor.reverse(
        segmentID: segment.id, in: edit,
        statistics: { measured in
            print(String(reflecting: measured))
        })
    print("reverse_seconds=\((ContinuousClock.now - start) / .seconds(1))")
    await editor.close()
    try FileManager.default.removeItem(at: support)
}

func benchmarkEditorPhoto() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "PhotoPreviewBench-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let photo = folder.appending(path: "photo.heic")
    try writePhoto(to: photo)
    let source = try await PhotoEditorSource.open(photo)
    let previewDimension = 960
    let warmupIterations = 5
    let iterations = 20
    let percentile = 0.95
    for count in [1, EditOverlay.maximumCount] {
        var edit = ImageEdit()
        edit.overlays = (0..<count).map { index in
            index == 0
                ? EditOverlay(mark: .redaction(rect: EditCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4), style: .blur))
                : EditOverlay(
                    mark: .text(
                        "Annotation \(index)", at: EditPoint(x: 0.5, y: Double(index + 1) / Double(count + 1)),
                        color: .white, size: .small))
        }
        var measured: [Double] = []
        for iteration in 0..<(warmupIterations + iterations) {
            edit.adjustments[.exposure] = Double(iteration) / 100
            let start = ContinuousClock.now
            let image = try await source.render(edit, maximumDimension: previewDimension)
            guard max(image.width, image.height) <= previewDimension else {
                throw BenchError(description: "photo preview exceeded its dimensions")
            }
            if iteration >= warmupIterations { measured.append((ContinuousClock.now - start) / .seconds(1) * 1_000) }
        }
        measured.sort()
        let median = measured[iterations / 2]
        let percentile95 = measured[Int(Double(iterations - 1) * percentile)]
        print("photo_overlays=\(count) median_ms=\(median) p95_ms=\(percentile95)")
    }
    try FileManager.default.removeItem(at: folder)
}

@MainActor
func benchmarkEditorTimeline(_ source: URL, mode: String) async throws {
    guard ["music", "export"].contains(mode) else { throw BenchError(description: "Unknown editor timeline benchmark") }
    let folder = FileManager.default.temporaryDirectory.appending(path: "EditorTimelineBench-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let staging = StagingArea(supportDirectory: folder)
    let editor = try await VideoEditorSource.open(source, staging: staging)
    let details = await editor.details
    var edit = VideoEdit()
    if mode == "music" {
        let song = folder.appending(path: "song.caf")
        try writeBenchmarkTone(to: song)
        edit.segments = [VideoSegment(start: 0, end: details.duration)]
        edit.music = try BackgroundMusic.load(from: song)
        let volumes = [0.25, 0.5, 0.75]
        for (iteration, volume) in volumes.enumerated() {
            edit.music?.volume = volume
            let start = ContinuousClock.now
            let playback = try await editor.playback(edit: edit)
            let playerItem = AVPlayerItem(asset: playback.asset)
            playerItem.audioMix = playback.audioMix
            let player = AVPlayer(playerItem: playerItem)
            while playerItem.status == .unknown { try await Task.sleep(for: .milliseconds(1)) }
            guard playerItem.status == .readyToPlay else { throw BenchError(description: "preview unavailable") }
            print("music_edit=\(iteration) playable_seconds=\((ContinuousClock.now - start) / .seconds(1))")
            withExtendedLifetime(player) {}
        }
    } else {
        let segmentCount = 300
        let keptSeconds = 0.1
        edit.segments = (0..<segmentCount).map { index in
            let start = Double(index) * (details.duration - keptSeconds) / Double(segmentCount)
            return VideoSegment(start: start, end: start + keptSeconds)
        }
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid)), start: 0, end: details.duration
            )
        ]
        let engine = try JobEngine(supportDirectory: folder, concurrency: 1)
        let start = ContinuousClock.now
        let result = await engine.run(
            MediaEditing.video(url: source, edit: edit, settings: Settings()), settings: Settings()
        ) { _ in }
        guard case .succeeded(let outputs, _) = result.outcomes.first else {
            throw BenchError(description: "timeline export failed: \(result.outcomes)")
        }
        print("segments=\(segmentCount) export_seconds=\((ContinuousClock.now - start) / .seconds(1))")
        for output in outputs { try FileManager.default.removeItem(at: output) }
    }
    await editor.close()
    try FileManager.default.removeItem(at: folder)
}

private func writeBenchmarkTone(to url: URL) throws {
    let sampleRate = Double(Targets.audioSampleRate)
    let channels = AVAudioChannelCount(Targets.audioChannels)
    let frameCount = AVAudioFrameCount(Targets.audioSampleRate)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
        let planes = buffer.floatChannelData
    else { throw BenchError(description: "benchmark audio unavailable") }
    for frame in 0..<Int(frameCount) {
        let sample = Float(
            sin(2 * .pi * Targets.audioToneHertz * Double(frame) / sampleRate) * Targets.audioToneAmplitude)
        for channel in 0..<Int(channels) { planes[channel][frame] = sample }
    }
    buffer.frameLength = frameCount
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
}
