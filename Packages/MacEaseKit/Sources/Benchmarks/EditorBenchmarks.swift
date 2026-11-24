import CoreGraphics
import Engine
import Foundation

func benchmarkReverse(_ source: URL) async throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "ReverseBench-\(UUID())")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let staging = StagingArea(supportDirectory: support)
    let segment = VideoSegment(start: 0, end: VideoSegmentReverser.maximumSegmentSeconds)
    var edit = VideoEdit()
    edit.segments = [segment]
    let editor = try await VideoEditorSource.open(source, staging: staging)
    let start = ContinuousClock.now
    _ = try await editor.reverse(
        segmentID: segment.id, in: edit,
        statistics: { measured in
            print("decoded_frames=\(measured.decodedFrames) peak_buffered_bytes=\(measured.peakBufferedBytes)")
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
