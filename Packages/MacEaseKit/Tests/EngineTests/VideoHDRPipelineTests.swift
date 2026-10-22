import AVFoundation
import CoreMedia
import CoreVideo
import Formats
import Foundation
import ImageIO
import Testing
import VideoToolbox

@testable import Engine

@Suite(.serialized) struct VideoHDRPipelineTests {
    private static let barCount = 8
    private static let maximumLuminanceError = 512
    private static let rampWidth = 64
    private static let rampHeight = 48
    private static let firstRampCode: UInt16 = 510
    private static let maximumRampCodeError = 1
    private static let videoComponentShift = 6
    private static let neutralChromaCode: UInt16 = 512
    private static let dolbyConfigurationBytes = 24
    private static let writerTimeout = Duration.seconds(30)

    enum Transfer: String, CaseIterable {
        case pq = "x265-pq.mp4"
        case hlg = "x265-hlg.mov"
    }

    @Test(arguments: Transfer.allCases)
    func parameterSetsRetainHDRSignals(transfer: Transfer) async throws {
        let source = try copiedFixture(transfer)
        let format = try await format(at: source)
        let expected = try #require(VideoHDRConfiguration(format: format))
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let codecPrivate = try #require(VideoFormat.decoderConfiguration(of: format))
        let track = MediaTrack(
            number: 1, kind: .video(width: Int(dimensions.width), height: Int(dimensions.height)),
            codec: .hevc, codecPrivate: codecPrivate)
        let rebuilt = try VideoFormat.description(for: track)
        #expect(VideoHDRConfiguration(format: rebuilt) == expected)
    }

    @Test func geometryKeepsAdjacentTenBitLuminanceCodes() async throws {
        let source = try copiedFixture(.pq)
        let format = try await format(at: source)
        let hdr = try #require(VideoHDRConfiguration(format: format))
        let ramp = try tenBitRamp(transfer: hdr.transferFunction)
        let processor = try FrameProcessor(
            source: PixelSize(width: Self.rampWidth, height: Self.rampHeight), edit: FrameEdit(), hdr: hdr)
        let output = try processor.process(ramp)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let actual = try luminanceSamples(output).map { $0 >> Self.videoComponentShift }
        let expected = (0..<Self.barCount).map { Self.firstRampCode + UInt16($0) }
        #expect(Set(actual).count == Self.barCount)
        #expect(
            zip(actual, expected).allSatisfy {
                abs(Int($0) - Int($1)) <= Self.maximumRampCodeError
            })
    }

    @Test(arguments: Transfer.allCases)
    func writtenMatroskaHDRMustMatchPlannedEncoding(transfer: Transfer) async throws {
        let expectedSource = try copiedFixture(.pq)
        let expected = try #require(VideoHDRConfiguration(format: try await format(at: expectedSource)))
        let source = try await MediaInput.open(copiedFixture(transfer))
        let track = try #require(source.video)
        let output = expectedSource.deletingLastPathComponent().appending(path: "written.mkv")
        var muxer = try MatroskaMuxer(url: output, tracks: [track], webm: false)
        try muxer.write(MediaPacket(track: track.number, timestamp: 0, isKeyframe: true, payload: Data([1])))
        try muxer.finish()
        var encoding = VideoEncoding(
            codec: .hevc, width: source.codedSize.width, height: source.codedSize.height,
            frameDuration: source.frameDuration, bitrate: nil)
        encoding.hdr = expected
        let plan = TranscodePlan(container: .mkv, video: .encode(encoding, FrameEdit()), audio: nil)
        let context = context(for: expectedSource, outputMode: .replace)
        if transfer == .pq {
            try await VideoProperties.verify(plan, output: output, context: context)
        } else {
            await #expect(throws: EngineError.encodeFailed("HDR output format differs from source")) {
                try await VideoProperties.verify(plan, output: output, context: context)
            }
        }
    }

    @Test(arguments: Transfer.allCases)
    func resizeKeepsTenBitHDR(transfer: Transfer) async throws {
        let source = try copiedFixture(transfer)
        let original = try Data(contentsOf: source)
        let inputFormat = try await format(at: source)
        let expected = try #require(VideoHDRConfiguration(format: inputFormat))
        let sourceSamples = try await luminanceSamples(at: source)
        let context = context(for: source, outputMode: .replace)
        defer { context.removeStaging() }
        let result = try await VideoEdits.run(.resize(.percent(50)), url: source, context: context)
        guard case .replace(let originalURL, let staged) = result else {
            Issue.record("expected staged resized video")
            return
        }
        #expect(originalURL == source)
        #expect(try Data(contentsOf: source) == original)
        #expect(!context.warnings.contains(.videoToneMappedToSDR))
        let output = staged.url
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let outputFormat = try #require(try await track.load(.formatDescriptions).first)
        let size = CMVideoFormatDescriptionGetDimensions(outputFormat)
        #expect(size.width == 32)
        #expect(size.height == 24)
        #expect(VideoHDRConfiguration(format: outputFormat) == expected)
        let frame = try #require(
            try await AssetTrackReader(
                asset: asset, track: track, number: 1, mode: .hdrFrames
            ).nextFrame())
        let image = frame.image
        #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let samples = try luminanceSamples(image)
        #expect(Set(samples).count == Self.barCount)
        #expect(
            zip(sourceSamples, samples).allSatisfy {
                abs(Int($0) - Int($1)) <= Self.maximumLuminanceError
            })
    }

    @Test func hlgEncodingDoesNotAddDolbyVision() async throws {
        let source = try copiedFixture(.hlg)
        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        let context = context(for: source, outputMode: .replace)
        let initial = try VideoEdits.plan(
            .resize(.percent(50)), input: input, source: track, settings: context.settings.video)
        let plan = try await VideoProperties.prepare(initial, input: input, context: context)
        let output = source.deletingLastPathComponent().appending(path: "encoded.mov")
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
        let written = try await format(at: output)
        #expect(VideoHDRConfiguration(format: written)?.transfer == .hlg)
        #expect(try DolbyVisionConfiguration.isProfile84(written) == false)
    }

    @Test func hlgStaticMetadataSurvivesNativeOutputAndRefusesContainerLoss() async throws {
        let source = try copiedFixture(.hlg)
        let input = try await MediaInput.open(source)
        let plain = try await format(at: source)
        let pq = try await format(at: copiedFixture(.pq))
        var extensions = try #require(CMFormatDescriptionGetExtensions(plain) as? [CFString: Any])
        for key in [
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
            kCMFormatDescriptionExtension_ContentLightLevelInfo,
        ] {
            let payload = try #require(CMFormatDescriptionGetExtension(pq, extensionKey: key) as? Data)
            extensions[key] = payload
        }
        var description: CMVideoFormatDescription?
        let size = CMVideoFormatDescriptionGetDimensions(plain)
        try #require(
            CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: kCMVideoCodecType_HEVC, width: size.width, height: size.height,
                extensions: extensions as CFDictionary, formatDescriptionOut: &description) == noErr)
        let configured = try #require(description)
        let expected = try #require(VideoHDRConfiguration(format: configured))
        var encoding = VideoEncoding(
            codec: .hevc, width: Int(size.width), height: Int(size.height),
            frameDuration: input.frameDuration, bitrate: nil)
        encoding.hdr = expected
        let plan = TranscodePlan(container: .mov, video: .encode(encoding, FrameEdit()), audio: nil)
        let output = source.deletingLastPathComponent().appending(path: "static-hlg.mov")
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
        #expect(VideoHDRConfiguration(format: try await format(at: output)) == expected)
        #expect(try DolbyVisionConfiguration.isProfile84(try await format(at: output)) == false)
        let context = context(for: source, outputMode: .replace)
        try await VideoProperties.verify(plan, output: output, context: context)
        let unsupportedOutput = source.deletingLastPathComponent().appending(path: "static-hlg.mkv")
        var unsupportedPlan = plan
        unsupportedPlan.container = .mkv
        try await Transcoder.run(input, plan: unsupportedPlan, to: unsupportedOutput) { _ in }
        await #expect(throws: EngineError.encodeFailed("HDR output format differs from source")) {
            try await VideoProperties.verify(unsupportedPlan, output: unsupportedOutput, context: context)
        }
    }

    @Test func dolbyVisionCompressionKeepsHLGBaseLayer() async throws {
        let source = try await dolbyVisionFixture()
        let original = try Data(contentsOf: source)
        let expected = try #require(VideoHDRConfiguration(format: try await format(at: source)))
        let context = context(for: source, outputMode: .newFile)
        defer { context.removeStaging() }
        let result = try await VideoCompressor.run(
            VideoCompression(goal: .quality(0.85)), url: source, context: context)
        guard case .replace(_, let staged) = result else {
            Issue.record("expected staged HLG video")
            return
        }
        let written = try await format(at: staged.url)
        #expect(VideoHDRConfiguration(format: written) == expected)
        #expect(try DolbyVisionConfiguration.isProfile84(written) == false)
        #expect(context.warnings.contains(.dolbyVisionRemoved))
        #expect(!context.warnings.contains(.videoToneMappedToSDR))
        let bitDepth = CMFormatDescriptionGetExtension(
            written, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
        #expect((bitDepth as? NSNumber)?.intValue == 10)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func dolbyVisionH264TargetDisclosesBothLosses() async throws {
        let source = try await dolbyVisionFixture()
        let context = context(for: source, outputMode: .newFile)
        defer { context.removeStaging() }
        let result = try await VideoCompressor.run(
            VideoCompression(goal: .platform(try h264PlatformPreset())), url: source, context: context)
        guard case .replace(_, let staged) = result else {
            Issue.record("expected staged SDR video")
            return
        }
        #expect(context.warnings.contains(.dolbyVisionRemoved))
        #expect(context.warnings.contains(.videoToneMappedToSDR))
        try await VideoSDR.verify(staged.url)
    }

    @Test func dolbyVisionReplacementRefusesBeforeStaging() async throws {
        let source = try await dolbyVisionFixture()
        let original = try Data(contentsOf: source)
        let folder = source.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let context = context(for: source, outputMode: .replace)
        defer { context.removeStaging() }
        await #expect(throws: EngineError.videoDolbyVisionUnsupported) {
            _ = try await VideoCompressor.run(
                VideoCompression(goal: .quality(0.85)), url: source, context: context)
        }
        await #expect(throws: EngineError.videoDolbyVisionUnsupported) {
            _ = try await VideoEdits.run(.rotate(degrees: 90, fill: .black), url: source, context: context)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
        #expect(context.warnings.isEmpty)
    }

    @Test func dolbyVisionAnimationStaysDerivedUnderReplaceSetting() async throws {
        let source = try await dolbyVisionFixture()
        let original = try Data(contentsOf: source)
        let context = context(for: source, outputMode: .replace)
        defer { context.removeStaging() }
        let result = try await VideoAnimations.gif(
            AnimationRendering(width: 64, framesPerSecond: 24), url: source, context: context)
        guard case .derived(_, let outputs) = result, let output = outputs.first else {
            Issue.record("expected staged GIF")
            return
        }
        let frames = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        #expect(CGImageSourceGetCount(frames) > 1)
        #expect(context.warnings.contains(.videoToneMappedToSDR))
        #expect(context.warnings.contains(.dolbyVisionRemoved))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func dolbyVisionCopyEditReencodesWithoutDynamicMetadata() async throws {
        let source = try await dolbyVisionFixture()
        let context = context(for: source, outputMode: .newFile)
        defer { context.removeStaging() }
        let result = try await VideoEdits.run(.rotate(degrees: 90, fill: .black), url: source, context: context)
        guard case .replace(_, let staged) = result else {
            Issue.record("expected staged rotated HLG video")
            return
        }
        let written = try await format(at: staged.url)
        let size = CMVideoFormatDescriptionGetDimensions(written)
        #expect(size.width == 48)
        #expect(size.height == 64)
        #expect(VideoHDRConfiguration(format: written)?.transfer == .hlg)
        #expect(try DolbyVisionConfiguration.isProfile84(written) == false)
        #expect(context.warnings.contains(.dolbyVisionRemoved))
    }

    @Test func mixedDolbyVisionAndPlainHLGRefuses() async throws {
        let plain = try await format(at: copiedFixture(.hlg))
        let dolby = try dolbyVisionFormat(plain)
        for formats in [[plain, dolby], [dolby, plain]] {
            #expect(throws: EngineError.hdrConversionUnsupported) {
                try VideoProperties.hdrConfiguration(formats)
            }
        }
    }

    @Test func h264TargetDisclosesOrRefusesHDRLoss() async throws {
        let source = try copiedFixture(.pq)
        let original = try Data(contentsOf: source)
        let directory = source.deletingLastPathComponent()
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let input = try await MediaInput.open(source)
        let size = input.codedSize
        let encoding = VideoEncoding(
            codec: .h264, width: size.width, height: size.height,
            frameDuration: input.frameDuration, bitrate: nil)
        let plan = TranscodePlan(container: .mp4, video: .encode(encoding, FrameEdit()), audio: nil)
        let newFile = context(for: source, outputMode: .newFile)
        defer { newFile.removeStaging() }
        let prepared = try await VideoProperties.prepare(plan, input: input, context: newFile, allowsCodecChange: false)
        #expect(prepared.toneMapToSDR)
        #expect(newFile.warnings.contains(.videoToneMappedToSDR))
        let replacement = context(for: source, outputMode: .replace)
        defer { replacement.removeStaging() }
        await #expect(throws: EngineError.videoHDRUnsupported) {
            _ = try await VideoProperties.prepare(plan, input: input, context: replacement, allowsCodecChange: false)
        }
        #expect(replacement.warnings.isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == originalNames)
    }

    @Test func animatedGIFUsesSDRToneMapping() async throws {
        let source = try copiedFixture(.pq)
        let context = context(for: source, outputMode: .newFile)
        defer { context.removeStaging() }
        let result = try await VideoAnimations.gif(
            AnimationRendering(width: 64, framesPerSecond: 24), url: source, context: context)
        guard case .derived(_, let outputs) = result, let output = outputs.first else {
            Issue.record("expected staged GIF")
            return
        }
        #expect(context.warnings.contains(.videoToneMappedToSDR))
        let frames = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        #expect(CGImageSourceGetCount(frames) > 1)
        let first = try #require(CGImageSourceCreateImageAtIndex(frames, 0, nil))
        let pixels = try PixelBuffer(cgImage: first)
        let red = stride(from: 0, to: pixels.width, by: pixels.width / Self.barCount).map {
            pixels.rgba[(pixels.height / 2 * pixels.width + $0) * 4]
        }
        #expect(Set(red).count > 2)
    }

    @Test func h264PlatformToneMapsNewFile() async throws {
        let source = try copiedFixture(.pq)
        let original = try Data(contentsOf: source)
        let context = context(for: source, outputMode: .newFile)
        defer { context.removeStaging() }
        let preset = try h264PlatformPreset()
        let result = try await VideoCompressor.run(
            VideoCompression(goal: .platform(preset)), url: source, context: context)
        guard case .replace(let originalURL, let staged) = result else {
            Issue.record("expected staged compressed video")
            return
        }
        #expect(originalURL == source)
        #expect(context.warnings.contains(.videoToneMappedToSDR))
        try await VideoSDR.verify(staged.url)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func h264PlatformRefusesHDRReplacementBeforeStaging() async throws {
        let source = try copiedFixture(.pq)
        let original = try Data(contentsOf: source)
        let directory = source.deletingLastPathComponent()
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let context = context(for: source, outputMode: .replace)
        defer { context.removeStaging() }
        let preset = try h264PlatformPreset()
        await #expect(throws: EngineError.videoHDRUnsupported) {
            _ = try await VideoCompressor.run(VideoCompression(goal: .platform(preset)), url: source, context: context)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == originalNames)
    }

    private func copiedFixture(_ transfer: Transfer) throws -> URL {
        let fixture = try #require(
            Bundle.module.url(
                forResource: transfer.rawValue, withExtension: nil, subdirectory: "Resources"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "VideoHDR-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appending(path: transfer.rawValue)
        try FileManager.default.copyItem(at: fixture, to: source)
        return source
    }

    private func dolbyVisionFormat(_ source: CMFormatDescription) throws -> CMFormatDescription {
        var extensions = try #require(CMFormatDescriptionGetExtensions(source) as? [CFString: Any])
        var atoms = try #require(
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data])
        var record = Data(repeating: 0, count: Self.dolbyConfigurationBytes)
        record[0] = 1
        record[2] = 0x10
        record[3] = 0x35
        record[4] = 0x40
        atoms["dvvC"] = record
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
        extensions.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription)
        extensions.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry)
        let size = CMVideoFormatDescriptionGetDimensions(source)
        var description: CMVideoFormatDescription?
        try #require(
            CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: kCMVideoCodecType_HEVC, width: size.width, height: size.height,
                extensions: extensions as CFDictionary, formatDescriptionOut: &description) == noErr)
        return try #require(description)
    }

    private func dolbyVisionFixture() async throws -> URL {
        let source = try copiedFixture(.hlg)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = CMVideoFormatDescriptionGetDimensions(try await format(at: source))
        let output = source.deletingLastPathComponent().appending(path: "dolby-vision.mov")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: kVTHDRMetadataInsertionMode_Auto,
            ],
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        try #require(writer.canAdd(writerInput))
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw writer.error ?? EngineError.encodeFailed("Dolby Vision fixture writer start")
        }
        writer.startSession(atSourceTime: .zero)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .hdrFrames)
        let deadline = ContinuousClock.now.advanced(by: Self.writerTimeout)
        while let sample = try await reader.nextSample() {
            while !writerInput.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? EngineError.encodeFailed("Dolby Vision fixture writer stalled")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writerInput.append(sample) else {
                throw writer.error ?? EngineError.encodeFailed("Dolby Vision fixture append")
            }
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? EngineError.encodeFailed("Dolby Vision fixture finish")
        }
        try #require(DolbyVisionConfiguration.isProfile84(try await format(at: output)))
        return output
    }

    private func h264PlatformPreset() throws -> PlatformPreset {
        var preset = try #require(Settings().platformPresets.first { $0.id == "discord" })
        preset.video?.maxBytes = nil
        return preset
    }

    private func context(for source: URL, outputMode: Settings.OutputMode) -> ItemContext {
        var settings = Settings()
        settings.outputMode = outputMode
        return ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: source.deletingLastPathComponent()),
            progress: { _ in })
    }

    private func format(at url: URL) async throws -> CMFormatDescription {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        return try #require(try await track.load(.formatDescriptions).first)
    }

    private func luminanceSamples(_ image: CVPixelBuffer) throws -> [UInt16] {
        try #require(CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let row = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 0))
            .assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0) / MemoryLayout<UInt16>.stride
        let middle = CVPixelBufferGetHeight(image) / 2
        let barWidth = CVPixelBufferGetWidth(image) / Self.barCount
        return (0..<Self.barCount).map { row[middle * stride + barWidth / 2 + $0 * barWidth] }
    }

    private func luminanceSamples(at url: URL) async throws -> [UInt16] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let frame = try #require(
            try await AssetTrackReader(asset: asset, track: track, number: 1, mode: .hdrFrames).nextFrame())
        return try luminanceSamples(frame.image)
    }

    private func tenBitRamp(transfer: CFString) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary
        try #require(
            CVPixelBufferCreate(
                nil, Self.rampWidth, Self.rampHeight, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                attributes, &created) == kCVReturnSuccess)
        let ramp = try #require(created)
        try #require(CVPixelBufferLockBaseAddress(ramp, []) == kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(ramp, []) }
            let luminance = try #require(CVPixelBufferGetBaseAddressOfPlane(ramp, 0))
                .assumingMemoryBound(to: UInt16.self)
            let luminanceStride = CVPixelBufferGetBytesPerRowOfPlane(ramp, 0) / MemoryLayout<UInt16>.stride
            let barWidth = Self.rampWidth / Self.barCount
            for y in 0..<Self.rampHeight {
                for x in 0..<Self.rampWidth {
                    luminance[y * luminanceStride + x] =
                        (Self.firstRampCode + UInt16(x / barWidth)) << Self.videoComponentShift
                }
            }
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(ramp, 1))
                .assumingMemoryBound(to: UInt16.self)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(ramp, 1) / MemoryLayout<UInt16>.stride
            for y in 0..<(Self.rampHeight / 2) {
                for x in 0..<Self.rampWidth {
                    chroma[y * chromaStride + x] = Self.neutralChromaCode << Self.videoComponentShift
                }
            }
        }
        CVBufferSetAttachment(
            ramp, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(ramp, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(
            ramp, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return ramp
    }
}
