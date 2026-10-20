import CoreGraphics
import CoreVideo
import Formats
import Foundation
import Testing

@testable import Engine

private let canAllocateVideoFrames: Bool = {
    var image: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary
    let status = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, attributes, &image)
    return status == kCVReturnSuccess && image != nil
}()

@Suite struct FrameBufferReviewTests {
    @Test func rejectsLargeFrameSetsAndOverflowBeforeAllocation() throws {
        var budget = FrameMemoryBudget()
        #expect(throws: EngineError.self) {
            try budget.reserve(width: 480, height: 270, frameCount: 9_000)
        }
        #expect(throws: EngineError.self) {
            try budget.reserve(width: 2_048, height: 2_048, frameCount: 100)
        }
        #expect(throws: EngineError.self) {
            try budget.reserve(width: Int.max, height: Int.max, frameCount: Int64.max)
        }
        try budget.reserve(width: 480, height: 270, frameCount: 150)
    }

    @Test func oversizedResizeFailsBeforeRendering() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "source.png")
        try ImageFixtures.write([ImageFixtures.disc(size: 16)], as: .png, to: source)
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        do {
            _ = try await ImageEdits.resize(
                source, ImageResize(size: .exact(width: 50_000, height: 50_000), allowsUpscale: true), context: context)
            Issue.record("oversized resize must report its memory limit")
        } catch EngineError.invalidInput(.malformed(let reason)) {
            #expect(reason.contains("memory budget"))
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func oversizedPageSetFailsBeforeDecoding() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "pages.tiff")
        let image = try ImageFixtures.disc(size: 2_048)
        try ImageFixtures.write(Array(repeating: image, count: 7), as: .tiff, to: source)
        do {
            _ = try await ImageDocument.load(source)
            Issue.record("oversized page set must fail")
        } catch EngineError.invalidInput(.malformed(let reason)) {
            #expect(reason.contains("memory budget"))
        }
    }

    @Test func longAnimationFailsBeforeSampling() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let remuxed = folder.appending(path: "original.mkv")
        try await Transcoder.run(
            MediaInput.open(source), plan: TranscodePlan(container: .mkv, video: .copy, audio: nil), to: remuxed
        ) { _ in }
        var demuxer = try MatroskaDemuxer(url: remuxed)
        let firstPacket = try demuxer.nextPacket()
        var packet = try #require(firstPacket)
        let tenMinutes = 600 * Nanoseconds.perSecond
        packet.duration = tenMinutes
        let extended = folder.appending(path: "long.mkv")
        var muxer = try MatroskaMuxer(url: extended, tracks: demuxer.tracks, webm: false)
        try muxer.write(packet)
        try muxer.finish()
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        do {
            _ = try await VideoAnimations.apng(
                AnimationRendering(width: 480, framesPerSecond: 15), url: extended, context: context)
            Issue.record("long animation must fail its memory budget")
        } catch EngineError.invalidInput(.malformed(let reason)) {
            #expect(reason.contains("memory budget"))
        }
    }

    @Test(.enabled(if: canAllocateVideoFrames)) func samplerStopsReadingWhenTrimRangeEnds() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let container = folder.appending(path: "clip.mkv")
        let interval = Nanoseconds.perSecond / 24
        var track = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        track.defaultDuration = interval
        let image = try ImageFixtures.disc(size: 16)
        let jpeg = try ImageEncoder.encode(
            [ImageFrame(image: image, duration: 0)], as: .jpeg,
            options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        var muxer = try MatroskaMuxer(url: container, tracks: [track], webm: false)
        for index in 0..<48 {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(index) * interval, duration: interval, isKeyframe: true, payload: jpeg))
        }
        try muxer.finish()
        let input = try await MediaInput.open(container)
        let end = 4 * interval
        let sampler = try await FrameSampler(
            input: input, frameDuration: interval, edit: FrameEdit(), start: 0, end: end)
        var timestamps: [Int64] = []
        while let frame = try await sampler.next() { timestamps.append(frame.timestamp) }
        #expect(timestamps == [0, interval, 2 * interval, 3 * interval])
        #expect(sampler.position <= end + interval)
        let stoppedAt = sampler.position
        #expect(try await sampler.next() == nil)
        #expect(sampler.position == stoppedAt)
    }
}
