import AVFoundation
import CoreVideo
import Formats
import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct VideoEditorEfficiencyTests {
    @Test(arguments: ["preview-23976.mp4", "reverse-late-gop.mkv"])
    func manySegmentsWithRedactionShareOneTimingIndex(_ name: String) async throws {
        let source = try fixture(name)
        let input = try await MediaInput.open(source)
        var edit = VideoEdit()
        edit.segments = (0..<300).map { _ in VideoSegment(start: 0, end: 0.1) }
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid)), start: 0, end: 0.1)
        ]
        let timeline = try VideoTimeline(edit: edit, sourceDuration: 1)
        let frames = try TimelineFrameSource(
            inputs: [input], frameDuration: input.frameDuration, edit: FrameEdit(), timeline: timeline,
            toneMapToSDR: false)
        for position in 0..<300 {
            let buffer = try await frames.frame(at: Nanoseconds.from(seconds: Double(position) * 0.1 + 0.01))
            let image = try CGImage.make(from: buffer)
            #expect(try ImageFixtures.pixel(image, x: 80, y: 60).prefix(3).allSatisfy { $0 < 16 })
        }
        #expect(await frames.frameIndexes.buildCount == 1)
        let index = try await frames.frameIndexes.index(for: source)
        if name.hasSuffix(".mp4") {
            #expect(index.packetBytesRead == 0)
        } else {
            #expect(index.packetBytesRead > 0)
        }
        #expect(await frames.frameIndexes.buildCount == 1)
    }

    @Test func metadataOnlyIndexMatchesReaderOutputIncludingEditLists() async throws {
        for name in ["reverse-open-gop-vfr.mp4", "preview-23976.mp4"] {
            let input = try await MediaInput.open(fixture(name))
            guard case .asset(let asset, let track?, _) = input.backend else {
                Issue.record("expected native fixture")
                return
            }
            let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .packets)
            var expected: [Int64] = []
            while let sample = try await reader.nextSample() {
                if sample.outputDuration > .zero {
                    expected.append(SampleBuffers.nanoseconds(sample.outputPresentationTimeStamp))
                }
            }
            let index = try await EditorFrameIndex(input: input)
            #expect(index.timestamps == Array(Set(expected.filter { $0 >= 0 && $0 < input.duration })).sorted())
            #expect(index.packetBytesRead == 0)
        }
    }

    @Test func lateContainerReverseDecodesOnlyItsGOPAndKeepsFrames() async throws {
        let source = try fixture("reverse-late-gop.mkv")
        let segment = VideoSegment(start: 58.2, end: 58.8)
        var edit = VideoEdit()
        edit.segments = [segment]
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let measured = Mutex<VideoReverseStatistics?>(nil)
        let reversed = try await VideoSegmentReverser.reverse(
            segmentID: segment.id, in: edit, primaryURL: source, staging: staging,
            statistics: { result in measured.withLock { $0 = result } })
        let staged = try #require(reversed.sources?.last?.url)
        defer { VideoSegmentReverser.cleanupStagedSource(staged, in: staging) }
        let statistics = try #require(measured.withLock { $0 })
        #expect(statistics.decodedFrames <= 15)
        #expect(statistics.peakSpillBytes == 0)
        #expect(statistics.peakBufferedBytes <= ReversedFrameSpill.maximumBufferedBytes)
        let original = try await allFrames(source).filter {
            $0.timestamp >= 58_200_000_000 && $0.timestamp < 58_800_000_000
        }
        let backwards = try await allFrames(staged)
        #expect(original.count == 6 && backwards.count == 6)
        try compare(backwards, with: Array(original.reversed()))
    }

    @Test func containerOpenGOPPreservesLeadingFramesAndVariableTiming() async throws {
        let source = try fixture("reverse-open-gop-vfr.mkv")
        let original = try await allFrames(source).sorted { $0.timestamp < $1.timestamp }
        let input = try await MediaInput.open(source)
        let index = try await EditorFrameIndex(input: input)
        let segment = VideoSegment(start: 0.26, end: 0.7)
        var edit = VideoEdit()
        edit.segments = [segment]
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let reversed = try await VideoSegmentReverser.reverse(
            segmentID: segment.id, in: edit, primaryURL: source, staging: staging)
        let staged = try #require(reversed.sources?.last)
        defer { VideoSegmentReverser.cleanupStagedSource(staged.url, in: staging) }
        let backwards = try await allFrames(staged.url)
        let expected = original.filter { frame in
            guard let position = index.timestamps.firstIndex(of: frame.timestamp) else { return false }
            let end = position + 1 < index.timestamps.count ? index.timestamps[position + 1] : input.duration
            return frame.timestamp < 700_000_000 && end > 260_000_000
        }
        #expect(backwards.count == expected.count)
        #expect(expected.count == 6)
        try compare(backwards, with: Array(expected.reversed()))
        let intervals = try #require(staged.reversedFrames)
        #expect(Set(intervals.map { Int((($0.stagedEnd - $0.stagedStart) * 1_000).rounded()) }).count > 1)
    }

    @Test func insufficientCapacityRefusesBeforeSpill() throws {
        #expect(throws: EngineError.invalidInput(.insufficientReverseSpace(requiredBytes: 1_000, availableBytes: 999)))
        {
            try VideoSegmentReverser.requireCapacity(required: 1_000, available: 999)
        }
        try VideoSegmentReverser.requireCapacity(required: 1_000, available: 1_000)
    }

    @Test func reverseRefusesSmallVolumeWithoutLeavingStaging() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "large-frames.mp4")
        try FileManager.default.copyItem(at: fixture("reverse-8k-pq.mp4"), to: source)
        let stamp = try MediaSourceStamp(url: source)
        let input = try await MediaInput.open(source)
        let segment = VideoSegment(start: 0, end: Double(input.duration) / Double(Nanoseconds.perSecond))
        var edit = VideoEdit()
        edit.segments = [segment]
        let support = try AudioSignals.temporaryFolder()
        let staging = StagingArea(supportDirectory: support)
        do {
            _ = try await VideoSegmentReverser.reverse(
                segmentID: segment.id, in: edit, primaryURL: source, staging: staging)
            Issue.record("reverse exceeded available capacity")
        } catch EngineError.invalidInput(.insufficientReverseSpace(let required, let available)) {
            #expect(required > available)
            #expect(required > 200_000_000)
        }
        try stamp.validate(source)
        let registry = support.appending(path: "staging.json")
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)).isEmpty)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    private func allFrames(_ url: URL) async throws -> [DecodedFrame] {
        let input = try await MediaInput.open(url)
        if case .asset(let asset, let track?, _) = input.backend {
            let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .frames)
            var frames: [DecodedFrame] = []
            while let frame = try await reader.nextFrame() { frames.append(frame) }
            return frames
        }
        let track = try #require(input.video)
        var demuxer = try #require(try input.demuxer)
        var decoder = try VideoDecoders.make(for: track)
        var frames: [DecodedFrame] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == track.number { frames += try decoder.decode(packet) }
        }
        frames += try decoder.finish()
        return frames.sorted { $0.timestamp < $1.timestamp }
    }

    private func compare(_ actual: [DecodedFrame], with expected: [DecodedFrame]) throws {
        for (position, frame) in actual.enumerated() {
            let image = try CGImage.make(from: frame.image)
            let scores = try expected.map { referenceFrame in
                let reference = try CGImage.make(from: referenceFrame.image)
                var difference = 0.0
                var count = 0
                for y in stride(from: 4, to: image.height, by: 8) {
                    for x in stride(from: 4, to: image.width, by: 8) {
                        let left = try ImageFixtures.pixel(image, x: x, y: y)
                        let right = try ImageFixtures.pixel(reference, x: x, y: y)
                        difference += zip(left.prefix(3), right.prefix(3)).reduce(0.0) {
                            $0 + abs(Double($1.0) - Double($1.1))
                        }
                        count += 3
                    }
                }
                return difference / Double(count)
            }
            guard scores.indices.contains(position) else {
                Issue.record("unexpected reversed frame")
                continue
            }
            #expect(scores[position] < 10)
            #expect(scores.indices.min { scores[$0] < scores[$1] } == position)
        }
    }
}
