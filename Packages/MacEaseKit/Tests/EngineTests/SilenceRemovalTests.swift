import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Engine

@Suite struct SilenceRemovalTests {
    private static let sampleRate = 48_000.0
    private static let fps: Int32 = 30
    private static let frameDuration = 1.0 / 30.0
    private static let window = AudioLevels.defaultWindow
    private static let loudDecibels = -10.0
    private static let quietDecibels = -60.0

    @Test func silenceRuleDefaultsAndValidation() throws {
        let defaults = SilenceRule()
        #expect(defaults.threshold == -40)
        #expect(defaults.minimumDuration == 0.75)
        try defaults.validate()

        let minimum = SilenceRule(threshold: -60, minimumDuration: 0.3)
        let maximum = SilenceRule(threshold: -20, minimumDuration: 5.0)
        try minimum.validate()
        try maximum.validate()
        #expect(try JSONDecoder().decode(SilenceRule.self, from: JSONEncoder().encode(minimum)) == minimum)

        let invalidRules = [
            SilenceRule(threshold: -60.1),
            SilenceRule(threshold: -19.9),
            SilenceRule(threshold: .nan),
            SilenceRule(threshold: -.infinity),
            SilenceRule(threshold: .infinity),
            SilenceRule(minimumDuration: 0.29),
            SilenceRule(minimumDuration: 5.01),
            SilenceRule(minimumDuration: 0),
            SilenceRule(minimumDuration: -1),
            SilenceRule(minimumDuration: .nan),
            SilenceRule(minimumDuration: .infinity),
        ]
        for rule in invalidRules {
            #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) { try rule.validate() }
        }
    }

    @Test func syntheticVideoLevelsDetectToneGapToneAndRejectSilentVideo() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let videoURL = folder.appending(path: "tone-gap-tone.mov")
        let totalSeconds = 3.0
        let amplitude = 0.5
        let samples = Self.toneGapToneSamples(
            duration: totalSeconds, sampleRate: Self.sampleRate,
            toneRanges: [0.0..<1.0, 2.0..<3.0], amplitude: Float(amplitude))
        try await Self.writePCMVideo(
            samples: samples, sampleRate: Self.sampleRate, duration: totalSeconds, to: videoURL)

        let levels = try await AudioWaveform.levels(videoAt: videoURL)
        #expect(levels.window == AudioLevels.defaultWindow)
        #expect(abs(levels.duration - totalSeconds) < 0.01)
        #expect(levels.decibels.count == 150)

        let expectedToneDecibels = 20 * log10(amplitude / sqrt(2))
        for index in 5..<45 {
            #expect(abs(levels.decibels[index] - expectedToneDecibels) < 0.2)
        }
        for index in 55..<95 {
            #expect(levels.decibels[index] == -.infinity)
        }
        for index in 105..<145 {
            #expect(abs(levels.decibels[index] - expectedToneDecibels) < 0.2)
        }

        let ranges = try levels.silentRanges(SilenceRule())
        try #require(ranges.count == 1)
        #expect(abs(ranges[0].lowerBound - 1.12) < 1e-6)
        #expect(abs(ranges[0].upperBound - 1.88) < 1e-6)

        let bundledAAC = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let aacLevels = try await AudioWaveform.levels(videoAt: bundledAAC)
        #expect(!aacLevels.decibels.isEmpty)
        #expect(abs(aacLevels.duration - 2) < 0.1)
        #expect(try aacLevels.silentRanges(SilenceRule()).isEmpty)

        let silentVideo = try #require(
            Bundle.module.url(forResource: "x265-hlg.mov", withExtension: nil, subdirectory: "Resources"))
        await #expect(throws: EngineError.invalidInput(.malformed("no audio track"))) {
            try await AudioWaveform.levels(videoAt: silentVideo)
        }
        for badWindow in [0.0, -0.02, .nan, .infinity, 0.0001] {
            await #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) {
                try await AudioWaveform.levels(videoAt: videoURL, window: badWindow)
            }
        }
    }

    @Test func silentRangesHandleStartAndEndBoundaries() throws {
        let rule = SilenceRule()

        let leading = Self.makeLevels(duration: 2.0, silent: [0.0..<1.0])
        let leadingRanges = try leading.silentRanges(rule)
        try #require(leadingRanges.count == 1)
        #expect(leadingRanges[0].lowerBound == 0)
        #expect(abs(leadingRanges[0].upperBound - 0.88) < 1e-9)

        let trailing = Self.makeLevels(duration: 2.0, silent: [1.0..<2.0])
        let trailingRanges = try trailing.silentRanges(rule)
        try #require(trailingRanges.count == 1)
        #expect(abs(trailingRanges[0].lowerBound - 1.12) < 1e-9)
        #expect(trailingRanges[0].upperBound == 2.0)

        let bothEnds = Self.makeLevels(duration: 3.0, silent: [0.0..<1.0, 2.0..<3.0])
        let bothRanges = try bothEnds.silentRanges(rule)
        try #require(bothRanges.count == 2)
        #expect(bothRanges[0].lowerBound == 0)
        #expect(abs(bothRanges[0].upperBound - 0.88) < 1e-9)
        #expect(abs(bothRanges[1].lowerBound - 2.12) < 1e-9)
        #expect(bothRanges[1].upperBound == 3.0)

        let roundedTail = AudioLevels(decibels: [Double](repeating: -.infinity, count: 30), window: 0.03, duration: 0.9)
        #expect(try roundedTail.silentRanges(rule) == [0.0..<0.9])
    }

    @Test func silentRangesRespectMinimumDurationBoundaries() throws {
        let defaultRule = SilenceRule()
        let underDefault = Self.makeLevels(duration: 3.0, silent: [1.0..<1.74])
        #expect(try underDefault.silentRanges(defaultRule).isEmpty)

        let overDefault = Self.makeLevels(duration: 3.0, silent: [1.0..<1.76])
        let overRanges = try overDefault.silentRanges(defaultRule)
        try #require(overRanges.count == 1)
        #expect(abs(overRanges[0].lowerBound - 1.12) < 1e-9)
        #expect(abs(overRanges[0].upperBound - 1.64) < 1e-9)

        let shortRule = SilenceRule(threshold: -40, minimumDuration: 0.3)
        let underShort = Self.makeLevels(duration: 2.0, silent: [1.1..<1.38])
        #expect(try underShort.silentRanges(shortRule).isEmpty)

        let exactShort = Self.makeLevels(duration: 2.0, silent: [1.1..<1.4])
        let exactRanges = try exactShort.silentRanges(shortRule)
        try #require(exactRanges.count == 1)
        #expect(abs(exactRanges[0].lowerBound - 1.22) < 1e-9)
        #expect(abs(exactRanges[0].upperBound - 1.28) < 1e-9)
    }

    @Test func silentRangesHandleOverlappingPaddingAndShortBursts() throws {
        let shortRule = SilenceRule(threshold: -40, minimumDuration: 0.3)

        let narrowGap = Self.makeLevels(duration: 2.0, silent: [1.0..<1.16])
        #expect(try narrowGap.silentRanges(shortRule).isEmpty)

        let shortBurst = Self.makeLevels(duration: 4.1, silent: [1.0..<2.0, 2.06..<3.06])
        let burstRanges = try shortBurst.silentRanges(SilenceRule())
        try #require(burstRanges.count == 2)
        #expect(abs(burstRanges[0].lowerBound - 1.12) < 1e-9)
        #expect(abs(burstRanges[0].upperBound - 1.88) < 1e-9)
        #expect(abs(burstRanges[1].lowerBound - 2.18) < 1e-9)
        #expect(abs(burstRanges[1].upperBound - 2.94) < 1e-9)
        #expect(burstRanges[0].upperBound < burstRanges[1].lowerBound)

        let segment = VideoSegment(start: 0, end: 10)
        let merged = try SilenceRemoval.segments(
            [segment], silences: [0: [5.0..<7.0, 2.0..<4.0, 3.0..<5.5]], minimumKept: 2 * Self.frameDuration)
        try #require(merged.count == 2)
        #expect(merged[0].start == 0 && merged[0].end == 2.0)
        #expect(merged[1].start == 7.0 && merged[1].end == 10.0)
    }

    @Test func segmentSurgeryPreservesSettingsFadesAndSkipsMuted() throws {
        var adjustments = MediaAdjustments()
        adjustments.style = .monochrome
        adjustments[.exposure] = 0.5

        var styled = VideoSegment(
            start: 0, end: 10, speed: 1.5, volume: 0.7, adjustments: adjustments, sourceIndex: 0)
        styled.fadeIn = 0.4
        styled.fadeOut = 0.6

        var muted = VideoSegment(start: 0, end: 4, speed: 1, volume: 0, sourceIndex: 0)
        muted.fadeIn = 0.2
        muted.fadeOut = 0.3

        var secondSource = VideoSegment(start: 0, end: 6, speed: 2, volume: 0.9, sourceIndex: 1)
        secondSource.fadeIn = 0.25
        secondSource.fadeOut = 0.35

        let silences: [Int: [Range<Double>]] = [
            0: [2.0..<4.0, 4.04..<6.0, 8.0..<8.5],
            1: [0.0..<1.5],
        ]
        let result = try SilenceRemoval.segments(
            [styled, muted, secondSource], silences: silences, minimumKept: 2 * Self.frameDuration)

        try #require(result.count == 5)
        let cutStyled = Array(result[0..<3])
        #expect(Set(cutStyled.map(\.id)).count == 3)
        #expect(!cutStyled.contains { $0.id == styled.id })
        #expect(cutStyled[0].start == 0 && cutStyled[0].end == 2.0)
        #expect(cutStyled[1].start == 6.0 && cutStyled[1].end == 8.0)
        #expect(cutStyled[2].start == 8.5 && cutStyled[2].end == 10.0)
        for piece in cutStyled {
            #expect(piece.speed == styled.speed)
            #expect(piece.volume == styled.volume)
            #expect(piece.adjustments == styled.adjustments)
            #expect(piece.sourceIndex == 0)
        }
        #expect(cutStyled[0].fadeIn == 0.4 && cutStyled[0].fadeOut == 0)
        #expect(cutStyled[1].fadeIn == 0 && cutStyled[1].fadeOut == 0)
        #expect(cutStyled[2].fadeIn == 0 && cutStyled[2].fadeOut == 0.6)

        #expect(result[3] == muted)

        let trimmed = result[4]
        #expect(trimmed.id != secondSource.id)
        #expect(trimmed.sourceIndex == 1)
        #expect(trimmed.start == 1.5 && trimmed.end == 6.0)
        #expect(trimmed.fadeIn == 0.25 && trimmed.fadeOut == 0.35)

        var edit = VideoEdit()
        edit.segments = Array(result[0..<4])
        let timeline = try VideoTimeline(edit: edit, sourceDuration: 10)
        #expect(timeline.segments.count == 4)
    }

    @Test func fullySilentInputThrowsInsteadOfReturningEmptyTimeline() throws {
        let silentLevels = Self.makeLevels(duration: 3.0, silent: [0.0..<3.0])
        let silences = try silentLevels.silentRanges(SilenceRule())
        #expect(silences == [0.0..<3.0])

        let segment = VideoSegment(start: 0, end: 3.0)
        #expect(throws: EngineError.invalidInput(.emptyInput)) {
            try SilenceRemoval.segments([segment], silences: [0: silences], minimumKept: 2 * Self.frameDuration)
        }
        #expect(throws: EngineError.invalidInput(.emptyInput)) {
            try SilenceRemoval.segments([segment], silences: [0: [0.0..<2.96]], minimumKept: 2 * Self.frameDuration)
        }
        #expect(throws: EngineError.invalidInput(.emptyInput)) {
            try SilenceRemoval.segments([], silences: [:], minimumKept: 2 * Self.frameDuration)
        }
        for badMinimum in [-0.1, .nan, .infinity] {
            #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) {
                try SilenceRemoval.segments([segment], silences: [:], minimumKept: badMinimum)
            }
        }
    }

    @Test func invalidAnalysisInputsThrowInsteadOfReportingNoSilence() throws {
        let valid = AudioLevels(decibels: [-80, -80], window: 0.5, duration: 1)
        #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) {
            try valid.silentRanges(SilenceRule(threshold: .nan))
        }
        for levels in [
            AudioLevels(decibels: [], window: 0.02, duration: 1),
            AudioLevels(decibels: [-80], window: 0, duration: 1),
            AudioLevels(decibels: [-80], window: .nan, duration: 1),
            AudioLevels(decibels: [-80], window: 1, duration: .infinity),
            AudioLevels(decibels: [.nan], window: 1, duration: 1),
            AudioLevels(decibels: [.infinity], window: 1, duration: 1),
            AudioLevels(decibels: [-80], window: 0.5, duration: 1),
            AudioLevels(decibels: [-80, -80, -80], window: 0.5, duration: 1),
        ] {
            #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) {
                try levels.silentRanges(SilenceRule())
            }
        }
    }

    @Test func freezeStaysIntactAndReversedCutsUseStagedSourceTime() throws {
        let freeze = VideoSegment(start: 0.5, end: 0.54, volume: 0, freezeDuration: 30)
        var reversed = VideoSegment(
            start: 0.2, end: 1.8, sourceIndex: 1,
            reversedOrigin: ReversedSegmentOrigin(sourceIndex: 0, start: 10, end: 12))
        reversed.fadeIn = 0.1
        reversed.fadeOut = 0.2
        let kept = try SilenceRemoval.segments(
            [freeze, reversed], silences: [0: [0..<20], 1: [0.6..<1.2]], minimumKept: 2 * Self.frameDuration)
        try #require(kept.count == 3)
        #expect(kept[0] == freeze)
        #expect(kept[1].start == 0.2 && kept[1].end == 0.6)
        #expect(kept[2].start == 1.2 && kept[2].end == 1.8)
        #expect(kept[1].fadeIn == 0.1 && kept[1].fadeOut == 0)
        #expect(kept[2].fadeIn == 0 && kept[2].fadeOut == 0.2)
        for piece in kept.dropFirst() {
            #expect(piece.sourceIndex == 1 && piece.reversedOrigin == reversed.reversedOrigin)
            #expect(piece.id != reversed.id)
        }
    }

    @Test func rawSegmentBoundaryRejectsInvalidNumbers() {
        let invalid = VideoSegment(start: .nan, end: 2)
        #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) {
            try SilenceRemoval.segments([invalid], silences: [:], minimumKept: 0)
        }
    }

    private static func makeLevels(duration: Double, silent: [Range<Double>]) -> AudioLevels {
        let count = Int((duration / window).rounded())
        let decibels = (0..<count).map { index -> Double in
            let midpoint = (Double(index) + 0.5) * window
            let isSilent = silent.contains { midpoint >= $0.lowerBound && midpoint < $0.upperBound }
            return isSilent ? quietDecibels : loudDecibels
        }
        return AudioLevels(decibels: decibels, window: window, duration: duration)
    }

    private static func toneGapToneSamples(
        duration: Double, sampleRate: Double, toneRanges: [Range<Double>], amplitude: Float
    ) -> [Float] {
        let frames = Int((duration * sampleRate).rounded())
        var samples = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            if toneRanges.contains(where: { time >= $0.lowerBound && time < $0.upperBound }) {
                samples[frame] = amplitude * Float(sin(2 * .pi * 440 * time))
            }
        }
        return samples
    }

    private static func writePCMVideo(
        samples: [Float], sampleRate: Double, duration: Double, to url: URL
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ])
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        guard status == noErr, let audioFormat = formatDescription else {
            throw EngineError.encodeFailed("audio format description \(status)")
        }
        let audioInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error ?? EngineError.encodeFailed("writer start") }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int((duration * Double(fps)).rounded())
        let chunkFrames = 4_800
        let totalChunks = (samples.count + chunkFrames - 1) / chunkFrames
        var frameIndex = 0
        var chunkIndex = 0
        while frameIndex < totalFrames || chunkIndex < totalChunks {
            let videoPending = frameIndex < totalFrames
            let audioPending = chunkIndex < totalChunks
            try await awaitReady(
                [videoPending ? videoInput : nil, audioPending ? audioInput : nil].compactMap { $0 },
                writer: writer)
            let frameTime =
                videoPending ? CMTime(value: CMTimeValue(frameIndex), timescale: fps) : .positiveInfinity
            let audioTime =
                audioPending
                ? CMTime(value: CMTimeValue(chunkIndex * chunkFrames), timescale: CMTimeScale(sampleRate))
                : .positiveInfinity
            if audioPending, audioInput.isReadyForMoreMediaData,
                !videoInput.isReadyForMoreMediaData || CMTimeCompare(audioTime, frameTime) <= 0
            {
                let offset = chunkIndex * chunkFrames
                let count = min(chunkFrames, samples.count - offset)
                let sampleBuffer = try makePCMSampleBuffer(
                    samples: samples[offset..<(offset + count)], offset: offset, sampleRate: sampleRate,
                    format: audioFormat)
                guard audioInput.append(sampleBuffer) else {
                    throw writer.error ?? EngineError.encodeFailed("audio append")
                }
                chunkIndex += 1
                if chunkIndex == totalChunks { audioInput.markAsFinished() }
                continue
            }
            guard videoPending, videoInput.isReadyForMoreMediaData else { continue }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard poolStatus == kCVReturnSuccess, let pixelBuffer = buffer else {
                throw EngineError.encodeFailed("pixel buffer \(poolStatus)")
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: frameTime) else {
                throw writer.error ?? EngineError.encodeFailed("video append")
            }
            frameIndex += 1
            if frameIndex == totalFrames { videoInput.markAsFinished() }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: CMTimeScale(sampleRate)))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func awaitReady(_ inputs: [AVAssetWriterInput], writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !inputs.contains(where: \.isReadyForMoreMediaData) {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? EngineError.encodeFailed("fixture writer stopped")
            }
            guard ContinuousClock.now < deadline else {
                throw EngineError.encodeFailed("fixture writer stalled")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func makePCMSampleBuffer(
        samples: ArraySlice<Float>, offset: Int, sampleRate: Double, format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard allocStatus == kCMBlockBufferNoErr, let block else {
            throw EngineError.encodeFailed("block alloc \(allocStatus)")
        }
        let copyStatus = samples.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadLengthParameterErr) }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw EngineError.encodeFailed("block copy \(copyStatus)")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw EngineError.encodeFailed("sample create \(sampleStatus)")
        }
        return sampleBuffer
    }
}
