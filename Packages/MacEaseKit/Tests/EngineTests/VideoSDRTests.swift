import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MenuCatalog
import Testing
import VideoToolbox

@testable import Engine

@Suite(.serialized) struct VideoSDRTests {
    private static let width = 64
    private static let height = 48
    private static let barWidth = 8
    private static let frameDurations: [Int64] = Array(
        repeating: [100, 120, 170, 220, 140], count: 3
    ).flatMap { $0 }
    private static let frameTimes: [Int64] = {
        var times: [Int64] = []
        var elapsed: Int64 = 0
        for duration in frameDurations {
            times.append(elapsed)
            elapsed += duration
        }
        return times
    }()
    private static let timescale: CMTimeScale = 1_000
    private static let lumaCodes: [UInt16] = [96, 176, 256, 336, 416, 496, 576, 656]
    private static let title = "HDR calibration clip"
    private static let audioTitle = "Calibration audio"
    private static let audioPreferredVolume: Float = 0.5
    private static let mirroredQuarterTurn = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    private static let referenceMaximumError = 12.0
    private static let referenceMeanError = 4.0
    private static let neutralDeltaELimit = 2.0
    private static let monotonicRoundingAllowance = 1.0
    private static let temporalVariationLimit = 4.0
    private static let repeatedPatternSeparation = 10
    private static let fixtureReadinessTimeout = Duration.seconds(30)

    enum Transfer: String, CaseIterable {
        case pq
        case hlg

        var writerValue: String {
            switch self {
            case .pq: AVVideoTransferFunction_SMPTE_ST_2084_PQ
            case .hlg: AVVideoTransferFunction_ITU_R_2100_HLG
            }
        }

        var coreVideoValue: CFString {
            switch self {
            case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
            }
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "VideoSDR-\(UUID().uuidString)")
        TestTemporaryFolders.register(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func describedHDR(extra: [CFString: Any] = [:]) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        extensions.merge(extra) { _, replacement in replacement }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC,
            width: Int32(Self.width), height: Int32(Self.height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw EngineError.decodeFailed("HDR source format fixture \(status)")
        }
        return description
    }

    private func fixture(in folder: URL, transfer: Transfer, withAudio: Bool = false) async throws -> URL {
        let url = folder.appending(path: "\(transfer.rawValue).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = Self.title as NSString
        writer.metadata = [title]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Self.width,
                AVVideoHeightKey: Self.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: transfer.writerValue,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        input.transform = Self.mirroredQuarterTurn
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard writer.canAdd(input) else { throw EngineError.encodeFailed("HDR fixture track unsupported") }
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        var audioSamples: [CMSampleBuffer] = []
        if withAudio {
            let audioURL = try #require(
                Bundle.module.url(
                    forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
            let asset = AVURLAsset(url: audioURL)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { throw EngineError.decodeFailed("fixture audio read") }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? EngineError.decodeFailed("fixture audio start")
            }
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 { audioSamples.append(sample) }
            }
            if reader.status == .failed { throw reader.error ?? EngineError.decodeFailed("fixture audio read") }
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            audio.languageCode = "jpn"
            audio.extendedLanguageTag = "ja"
            audio.preferredVolume = Self.audioPreferredVolume
            let audioMetadata = AVMutableMetadataItem()
            audioMetadata.identifier = .commonIdentifierTitle
            audioMetadata.value = Self.audioTitle as NSString
            audio.metadata = [audioMetadata]
            guard writer.canAdd(audio) else { throw EngineError.encodeFailed("fixture audio track") }
            writer.add(audio)
            audioInput = audio
        }
        guard writer.startWriting() else { throw writer.error ?? EngineError.encodeFailed("HDR fixture start") }
        writer.startSession(atSourceTime: .zero)
        let last = try #require(Self.frameTimes.last)
        let duration = try #require(Self.frameDurations.last)
        var sessionEnd = CMTime(value: last + duration, timescale: Self.timescale)
        var frameIndex = 0
        var audioIndex = 0
        while frameIndex < Self.frameTimes.count || audioIndex < audioSamples.count {
            let videoPending = frameIndex < Self.frameTimes.count
            let pendingAudio = audioIndex < audioSamples.count ? audioInput : nil
            try await awaitReady([videoPending ? input : nil, pendingAudio].compactMap { $0 }, writer: writer)
            let frameTime =
                videoPending
                ? CMTime(value: Self.frameTimes[frameIndex], timescale: Self.timescale) : .positiveInfinity
            // Encoder lookahead stalls video without later audio.
            if let pendingAudio, pendingAudio.isReadyForMoreMediaData,
                !input.isReadyForMoreMediaData
                    || CMTimeCompare(audioSamples[audioIndex].presentationTimeStamp, frameTime) < 0
            {
                let sample = audioSamples[audioIndex]
                guard pendingAudio.append(sample) else {
                    throw writer.error ?? EngineError.encodeFailed("fixture audio append")
                }
                let end = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
                if CMTimeCompare(end, sessionEnd) > 0 { sessionEnd = end }
                audioIndex += 1
                if audioIndex == audioSamples.count { pendingAudio.markAsFinished() }
                continue
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard status == kCVReturnSuccess, let frame = created else {
                throw EngineError.encodeFailed("HDR fixture pixel buffer \(status)")
            }
            try fill(frame, transfer: transfer, frameIndex: frameIndex)
            let timing = CMSampleTimingInfo(
                duration: CMTime(value: Self.frameDurations[frameIndex], timescale: Self.timescale),
                presentationTimeStamp: frameTime, decodeTimeStamp: .invalid)
            let format = try CMVideoFormatDescription(imageBuffer: frame)
            let sample = try CMSampleBuffer(imageBuffer: frame, formatDescription: format, sampleTiming: timing)
            guard input.append(sample) else {
                throw writer.error ?? EngineError.encodeFailed("HDR fixture append")
            }
            frameIndex += 1
            if frameIndex == Self.frameTimes.count { input.markAsFinished() }
        }
        writer.endSession(atSourceTime: sessionEnd)
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    private func awaitReady(_ inputs: [AVAssetWriterInput], writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now + Self.fixtureReadinessTimeout
        while !inputs.contains(where: \.isReadyForMoreMediaData) {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? EngineError.encodeFailed("HDR fixture writer stopped")
            }
            guard ContinuousClock.now < deadline else {
                throw EngineError.encodeFailed("HDR fixture writer stalled")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func fill(_ frame: CVPixelBuffer, transfer: Transfer, frameIndex: Int) throws {
        CVBufferSetAttachment(
            frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, transfer.coreVideoValue, .shouldPropagate)
        CVBufferSetAttachment(
            frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        guard CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess else {
            throw EngineError.encodeFailed("HDR fixture pixel lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(frame, 0)).assumingMemoryBound(to: UInt16.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(frame, 1)).assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0) / MemoryLayout<UInt16>.size
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1) / MemoryLayout<UInt16>.size
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let bar = column / Self.barWidth
                let motion = frameIndex.isMultiple(of: 2) ? 0 : 12
                luma[row * lumaStride + column] = (Self.lumaCodes[bar] + UInt16(motion)) << 6
            }
        }
        for row in 0..<(Self.height / 2) {
            for column in 0..<(Self.width / 2) {
                chroma[row * chromaStride + column * 2] = 512 << 6
                chroma[row * chromaStride + column * 2 + 1] = 512 << 6
            }
        }
    }

    private func samples(_ url: URL, settings: [String: Any]?) async throws -> [CMSampleBuffer] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.decodeFailed("fixture read") }
        var found: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            // Reader marker buffers carry no frame.
            if CMSampleBufferGetNumSamples(sample) > 0 { found.append(sample) }
        }
        if reader.status == .failed { throw reader.error ?? EngineError.decodeFailed("fixture read") }
        return found
    }

    private func audioPayloads(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.decodeFailed("audio packet read") }
        var packets: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0 else { throw EngineError.decodeFailed("empty audio packet") }
            var payload = Data(count: size)
            let status = payload.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: destination)
            }
            guard status == noErr else { throw EngineError.decodeFailed("audio packet copy") }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { throw EngineError.decodeFailed("empty audio sample") }
            var offset = 0
            for index in 0..<count {
                let length = count == 1 ? size : CMSampleBufferGetSampleSize(sample, at: index)
                guard length > 0, offset + length <= size else {
                    throw EngineError.decodeFailed("audio packet size")
                }
                packets.append(payload.subdata(in: offset..<(offset + length)))
                offset += length
            }
            guard offset == size else { throw EngineError.decodeFailed("audio packet trailing bytes") }
        }
        if reader.status == .failed { throw reader.error ?? EngineError.decodeFailed("audio packet read") }
        return packets
    }

    private func grayLevels(_ frame: CVPixelBuffer) throws -> [Double] {
        guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else {
            throw EngineError.decodeFailed("SDR pixel lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        return (0..<Self.lumaCodes.count).map { bar in
            let column = bar * Self.barWidth + Self.barWidth / 2
            let offset = (Self.height / 2) * stride + column * 4
            return Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
        }
    }

    private func neutralDeltaE(_ frame: CVPixelBuffer) throws -> [Double] {
        guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else {
            throw EngineError.decodeFailed("SDR pixel lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        let linear: (UInt8) -> Double = { channel in
            let normalized = Double(channel) / 255
            return normalized <= 0.04045 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
        }
        let lab: (Double) -> Double = { component in
            component > 0.008856 ? pow(component, 1.0 / 3) : 7.787 * component + 16.0 / 116
        }
        return (0..<Self.lumaCodes.count).map { bar in
            let column = bar * Self.barWidth + Self.barWidth / 2
            let offset = (Self.height / 2) * stride + column * 4
            let red = linear(bytes[offset + 2])
            let green = linear(bytes[offset + 1])
            let blue = linear(bytes[offset])
            let x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047
            let y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
            let z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883
            let a = 500 * (lab(x) - lab(y))
            let b = 200 * (lab(y) - lab(z))
            return hypot(a, b)
        }
    }

    private func referenceLevels(_ sample: CMSampleBuffer) throws -> [Double] {
        let source = try #require(CMSampleBufferGetImageBuffer(sample))
        var destination: CVPixelBuffer?
        let attributes =
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ] as CFDictionary
        guard
            CVPixelBufferCreate(
                nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, attributes, &destination) == kCVReturnSuccess
        else { throw EngineError.decodeFailed("reference pixel buffer") }
        let output = try #require(destination)
        CVBufferSetAttachment(
            output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr else {
            throw EngineError.decodeFailed("reference transfer session")
        }
        let session = try #require(created)
        defer { VTPixelTransferSessionInvalidate(session) }
        let properties: [(CFString, CFString)] = [
            (kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            guard VTSessionSetProperty(session, key: key, value: value) == noErr else {
                throw EngineError.decodeFailed("reference color configuration")
            }
        }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else {
            throw EngineError.decodeFailed("reference tone map")
        }
        return try grayLevels(output)
    }

    @Test(arguments: Transfer.allCases) func toneMapsTaggedMain10Video(transfer: Transfer) async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await fixture(in: directory, transfer: transfer)
        #expect(try await HDRClassification.video(at: source) == .unknownHDR)
        let sourceBytes = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoSDR.run(url: source, context: context)
        guard case .replace(let original, let staged) = result else {
            Issue.record("expected staged SDR video")
            return
        }
        #expect(original == source)
        guard case .sdrVideo = staged.check else {
            Issue.record("expected strict SDR output check")
            return
        }
        #expect(context.warnings.contains(.hdrProvenanceUnknown))
        try await OutputVerifier.verify(staged)
        #expect(try Data(contentsOf: source) == sourceBytes)

        let asset = AVURLAsset(url: staged.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let expected: [(CFString, CFString)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in expected {
            #expect(CMFormatDescriptionGetExtension(format, extensionKey: key) as? String == value as String)
        }
        #expect(try await track.load(.preferredTransform) == Self.mirroredQuarterTurn)
        let metadata = try await asset.load(.metadata)
        var titles: [String] = []
        for entry in metadata {
            if let title = try await entry.load(.stringValue) { titles.append(title) }
        }
        #expect(titles.contains(Self.title))

        let sourcePackets = try await samples(source, settings: nil).sorted {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        }
        let outputPackets = try await samples(staged.url, settings: nil).sorted {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        }
        try #require(sourcePackets.count == Self.frameTimes.count)
        try #require(outputPackets.count == sourcePackets.count)
        for (index, packet) in sourcePackets.enumerated() {
            let expectedTime = CMTime(value: Self.frameTimes[index], timescale: Self.timescale)
            let expectedDuration = CMTime(value: Self.frameDurations[index], timescale: Self.timescale)
            #expect(CMTimeCompare(packet.presentationTimeStamp, expectedTime) == 0)
            #expect(CMTimeCompare(packet.duration, expectedDuration) == 0)
        }
        for (before, after) in zip(sourcePackets, outputPackets) {
            #expect(CMTimeCompare(before.presentationTimeStamp, after.presentationTimeStamp) == 0)
            #expect(CMTimeCompare(before.duration, after.duration) == 0)
        }

        let hdrFrames = try await samples(
            source,
            settings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ]
        ).sorted { CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0 }
        let sdrFrames = try await samples(
            staged.url,
            settings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
        ).sorted { CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0 }
        #expect(hdrFrames.count == sdrFrames.count)
        var frameLevels: [[Double]] = []
        for (hdr, sdr) in zip(hdrFrames, sdrFrames) {
            let frame = try #require(CMSampleBufferGetImageBuffer(sdr))
            let actual = try grayLevels(frame)
            let reference = try referenceLevels(hdr)
            let errors = zip(actual, reference).map { abs($0 - $1) }
            #expect(errors.allSatisfy { $0 <= Self.referenceMaximumError })
            #expect(errors.reduce(0, +) / Double(errors.count) <= Self.referenceMeanError)
            #expect(zip(actual, actual.dropFirst()).allSatisfy { $1 + Self.monotonicRoundingAllowance >= $0 })
            #expect(actual[7] - actual[6] > 2)
            #expect(actual[7] < 252)
            #expect(try neutralDeltaE(frame).allSatisfy { $0 <= Self.neutralDeltaELimit })
            frameLevels.append(actual)
        }
        try #require(frameLevels.count == Self.frameTimes.count)
        for index in 0..<(frameLevels.count - Self.repeatedPatternSeparation) {
            #expect(
                zip(frameLevels[index], frameLevels[index + Self.repeatedPatternSeparation]).allSatisfy {
                    abs($0 - $1) <= Self.temporalVariationLimit
                })
        }
    }

    @Test func audioPacketsSurviveHDRConversion() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await fixture(in: directory, transfer: .pq, withAudio: true)
        let before = try await audioPayloads(source)
        #expect(!before.isEmpty)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoSDR.run(url: source, context: context)
        guard case .replace(_, let staged) = result else {
            Issue.record("expected staged SDR video with audio")
            return
        }
        try await OutputVerifier.verify(staged)
        #expect(try await audioPayloads(staged.url) == before)
        let sourceTrack = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).first)
        let outputTrack = try #require(try await AVURLAsset(url: staged.url).loadTracks(withMediaType: .audio).first)
        let sourceLanguage = try await sourceTrack.load(.languageCode)
        let sourceTag = try await sourceTrack.load(.extendedLanguageTag)
        let sourceVolume = try await sourceTrack.load(.preferredVolume)
        let sourceEnabled = try await sourceTrack.load(.isEnabled)
        #expect(sourceLanguage == "jpn")
        #expect(sourceTag == "ja")
        #expect(sourceVolume == Self.audioPreferredVolume)
        #expect(try await outputTrack.load(.languageCode) == sourceLanguage)
        #expect(try await outputTrack.load(.extendedLanguageTag) == sourceTag)
        #expect(try await outputTrack.load(.preferredVolume) == sourceVolume)
        #expect(try await outputTrack.load(.isEnabled) == sourceEnabled)
        let sourceMetadata = try await sourceTrack.load(.metadata)
        let outputMetadata = try await outputTrack.load(.metadata)
        var sourceTitles: [String] = []
        var outputTitles: [String] = []
        for entry in sourceMetadata {
            if let title = try await entry.load(.stringValue) { sourceTitles.append(title) }
        }
        for entry in outputMetadata {
            if let title = try await entry.load(.stringValue) { outputTitles.append(title) }
        }
        #expect(sourceTitles.contains(Self.audioTitle))
        #expect(outputTitles == sourceTitles)
    }

    @Test func ordinarySDRSkipsWithoutWriting() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try #require(
            Bundle.module.url(
                forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let video = directory.appending(path: "ordinary.mp4")
        try FileManager.default.copyItem(at: source, to: video)
        let bytes = try Data(contentsOf: video)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        guard case .skipped(.alreadySDR) = try await VideoSDR.run(url: video, context: context) else {
            Issue.record("expected ordinary SDR skip")
            return
        }
        #expect(try Data(contentsOf: video) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["ordinary.mp4"])
    }

    @Test func strictOutputCheckRejectsHDR() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await fixture(in: directory, transfer: .pq)
        let staged = StagedFile(url: source, name: source.lastPathComponent, check: .sdrVideo)
        await #expect(throws: EngineError.sdrVerificationFailed) {
            try await OutputVerifier.verify(staged)
        }
    }

    @Test func newFilePlanningUsesSDRSuffix() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await fixture(in: directory, transfer: .hlg)
        let settings = Settings()
        let request = OperationRequest(op: .videoConvert, options: .video(.hdrToSDR), inputs: [source])
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let work = try #require(batch.items.first)
        #expect(work.lane == .hardwareVideo)
        #expect(work.newFileNaming?.name(for: source, outputName: source.lastPathComponent) == "hlg_sdr.mov")
    }

    @Test func sourceFormatRejectsNonSquarePixelsAndPartialAperture() throws {
        try VideoSDR.validateSourceFormat(describedHDR())
        let fullAperture: [CFString: Any] = [
            kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
            kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
            kCMFormatDescriptionKey_CleanApertureHorizontalOffset: 0,
            kCMFormatDescriptionKey_CleanApertureVerticalOffset: 0,
        ]
        try VideoSDR.validateSourceFormat(
            describedHDR(extra: [kCMFormatDescriptionExtension_CleanAperture: fullAperture]))
        let apertureWithoutOffsets: [CFString: Any] = [
            kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
            kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
        ]
        try VideoSDR.validateSourceFormat(
            describedHDR(extra: [kCMFormatDescriptionExtension_CleanAperture: apertureWithoutOffsets]))
        var zeroRationalAperture = apertureWithoutOffsets
        zeroRationalAperture[kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational] = [0, 1]
        try VideoSDR.validateSourceFormat(
            describedHDR(extra: [kCMFormatDescriptionExtension_CleanAperture: zeroRationalAperture]))
        let widePixels = try describedHDR(extra: [
            kCMFormatDescriptionExtension_PixelAspectRatio: [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: 2,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: 1,
            ] as [CFString: Any]
        ])
        #expect(throws: EngineError.hdrConversionUnsupported) {
            try VideoSDR.validateSourceFormat(widePixels)
        }
        let apertures: [[CFString: Any]] = [
            [
                kCMFormatDescriptionKey_CleanApertureWidth: Self.width - 2,
                kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset: 0,
                kCMFormatDescriptionKey_CleanApertureVerticalOffset: 0,
            ],
            [
                kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
                kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset: 1,
                kCMFormatDescriptionKey_CleanApertureVerticalOffset: 0,
            ],
            [
                kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
                kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset: 0,
                kCMFormatDescriptionKey_CleanApertureVerticalOffset: 0,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational: [1, 1],
            ],
            [
                kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
                kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational: [1, 1],
            ],
            [
                kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
                kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational: [0, 0],
            ],
            [
                kCMFormatDescriptionKey_CleanApertureWidth: Self.width,
                kCMFormatDescriptionKey_CleanApertureHeight: Self.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational: [0],
            ],
        ]
        for aperture in apertures {
            let cropped = try describedHDR(extra: [kCMFormatDescriptionExtension_CleanAperture: aperture])
            #expect(throws: EngineError.hdrConversionUnsupported) {
                try VideoSDR.validateSourceFormat(cropped)
            }
        }
    }
}
