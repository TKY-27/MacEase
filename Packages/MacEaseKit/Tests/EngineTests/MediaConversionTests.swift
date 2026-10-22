import CoreGraphics
import Foundation
import ImageIO
import MenuCatalog
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import Engine
@testable import Formats

@Suite(.serialized) struct MediaConversionTests {
    @Test func pcmVideoAudioExtractsAsALACM4A() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "clip.mkv")
        let image = try ImageFixtures.photo(width: 32, height: 24)
        let video = MediaTrack(number: 1, kind: .video(width: 32, height: 24), codec: .mjpeg)
        let audio = MediaTrack(
            number: 2, kind: .audio(sampleRate: 48_000, channels: 2),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        let duration = Nanoseconds.perSecond / 10
        var pcm = Data()
        let samples = AudioSignals.music(seconds: 0.1, sampleRate: 48_000, channels: 2)
        for sample in samples {
            let integer = Int16((sample * 32_768).rounded())
            withUnsafeBytes(of: integer.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let encoded = NSMutableData()
        let jpeg = try #require(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(jpeg, image, nil)
        #expect(CGImageDestinationFinalize(jpeg))
        var muxer = try MatroskaMuxer(url: input, tracks: [video, audio], webm: false)
        try muxer.write(
            MediaPacket(track: 1, timestamp: 0, duration: duration, isKeyframe: true, payload: encoded as Data))
        try muxer.write(MediaPacket(track: 2, timestamp: 0, duration: duration, isKeyframe: true, payload: pcm))
        try muxer.finish()
        let original = try Data(contentsOf: input)
        let options = try #require(
            OperationPlanner.options(for: .videoExtractAudio, preset: "m4a-alac", settings: Settings()))
        guard case .video(.extractAudio(let format, _)) = options else {
            Issue.record("expected ALAC extraction")
            return
        }
        #expect(format == .m4aALAC)
        let context = context(in: folder)
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(format, url: input, context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("audio extraction must retain video")
            return
        }
        let output = try #require(outputs.first)
        #expect(output.name == "clip.m4a")
        let (decoded, decodedSamples) = try AudioSignals.decode(output.url)
        #expect(decoded.codec == .alac)
        #expect(decodedSamples.count == samples.count)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(arguments: [0, 1, 3, Int(UInt16.max) + 1])
    func finiteGIFLoopsSurviveStreamingEncode(_ loopCount: Int) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try animation(in: folder, loopCount: loopCount)
        let document = try await ImageDocument.load(input)
        let output = folder.appending(path: "copied.gif")
        var options = EncodeOptions(quality: 100)
        options.loopCount = document.loopCount
        try await ImageEncoder.encodeStreaming(frameCount: document.frameCount, as: .gif, options: options, to: output)
        {
            try document.frame(at: $0)
        }
        let source = try ImageFixtures.source(output)
        #expect(CGImageSourceGetCount(source) == 2)
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        #expect(AnimationKeys(type: .gif)?.loopCount(in: properties) == loopCount)
    }

    @Test(arguments: [ImageFormat.png, .jpeg, .tiff])
    func photoshopCompositeStagesDecodedPixels(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let photoshop = UTType(importedAs: "com.adobe.photoshop-image", conformingTo: .image)
        let input = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 32, height: 24)], as: photoshop, to: folder.appending(path: "layers.psd"))
        let context = context(in: folder)
        defer { context.removeStaging() }
        let result = try await ImageEdits.convert(input, ImageConversion(format: format), context: context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("PSD export must retain layers in original")
            return
        }
        let output = try #require(outputs.first)
        let image = try ImageFixtures.image(output.url)
        #expect(image.width == 32 && image.height == 24)
        if format != .jpeg {
            #expect(try ImageFixtures.rawBytes(output.url) == ImageFixtures.rawBytes(input))
        }
    }

    @Test func transparentPhotoshopCompositeExportsJPEGWithWarning() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let photoshop = UTType(importedAs: "com.adobe.photoshop-image", conformingTo: .image)
        let input = try ImageFixtures.write(
            [try ImageFixtures.disc(size: 32, background: nil)], as: photoshop,
            to: folder.appending(path: "transparent.psd"))
        #expect(try !PixelBuffer(cgImage: ImageFixtures.image(input)).isOpaque)
        let original = try Data(contentsOf: input)
        let context = context(in: folder)
        defer { context.removeStaging() }
        guard
            case .derived(_, let outputs) = try await ImageEdits.convert(
                input, ImageConversion(format: .jpeg), context: context)
        else { Issue.record("PSD export must keep the source"); return }
        let output = try #require(outputs.first)
        let corner = try ImageFixtures.pixel(ImageFixtures.image(output.url), x: 1, y: 1)
        #expect(corner.prefix(3).allSatisfy { $0 > 245 })
        #expect(context.warnings == [.imageFlattened, .imageTransparencyFlattened])
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(arguments: [ImageFormat.jpeg, .tiff, .pdf, .svg, .tga])
    func animatedConversionRefusesFrameLoss(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try animation(in: folder, loopCount: 3)
        let original = try Data(contentsOf: input)
        let context = context(in: folder)
        defer { context.removeStaging() }
        await #expect(throws: EngineError.imageSequenceUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: format), context: context)
        }
        #expect(try Data(contentsOf: input) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [input.lastPathComponent])
    }

    @Test(arguments: [ImageFormat.png, .webp, .gif])
    func finiteLoopCountSurvivesConversionAndResize(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try animation(in: folder, loopCount: 3)
        let context = context(in: folder)
        defer { context.removeStaging() }
        let result =
            format == .gif
            ? try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
            : try await ImageEdits.convert(input, ImageConversion(format: format), context: context)
        let output = try stagedURL(result)
        let source = try ImageFixtures.source(output)
        #expect(CGImageSourceGetCount(source) == 2)
        let keys = try #require(AnimationKeys(type: format.contentType))
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        #expect(keys.loopCount(in: properties) == 3)
        for index in 0..<2 {
            let frame = try ImageFixtures.properties(output, index: index)
            #expect(abs(try #require(keys.delay(in: frame)) - 0.2) < 0.011)
        }
    }

    @Test(arguments: [(ImageFormat.gif, Int(UInt16.max) + 2), (.webp, Int(UInt16.max) + 1)])
    func unrepresentableLoopCountFailsBeforeWriting(_ format: ImageFormat, _ loopCount: Int) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [try ImageFixtures.disc(size: 32), try ImageFixtures.photo(width: 32, height: 32)], as: .png,
            to: folder.appending(path: "long-loop.png"),
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]],
            frameProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]])
        let context = context(in: folder)
        defer { context.removeStaging() }
        await #expect(throws: EngineError.imageLoopCountUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: format), context: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [input.lastPathComponent])
    }

    @Test func multiPageTIFFConvertsToPDFAndRefusesPNG() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 32, height: 24), try ImageFixtures.photo(width: 24, height: 32)],
            as: .tiff, to: folder.appending(path: "pages.tiff"))
        let original = try Data(contentsOf: input)
        let context = context(in: folder)
        defer { context.removeStaging() }
        await #expect(throws: EngineError.imageSequenceUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: .png), context: context)
        }
        let output = try stagedURL(try await ImageEdits.convert(input, ImageConversion(format: .pdf), context: context))
        #expect(PDFDocument(url: output)?.pageCount == 2)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(arguments: [ImageFormat.png, .jpeg, .tiff], [Settings.OutputMode.newFile, .replace])
    func photoshopCompositeExportsKeepOriginal(_ format: ImageFormat, _ mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let photoshop = UTType(importedAs: "com.adobe.photoshop-image", conformingTo: .image)
        let input = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 32, height: 24)], as: photoshop, to: folder.appending(path: "layers.psd"))
        let original = try Data(contentsOf: input)
        #expect(try ContentSniffer.matches(input, kind: .image))
        var settings = Settings()
        settings.outputMode = mode
        let options = try #require(
            OperationPlanner.options(for: .imageConvert, preset: format.rawValue, settings: settings))
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(op: .imageConvert, options: options, inputs: [input])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        #expect(output.pathExtension == format.fileExtension)
        #expect(try ImageFixtures.image(output).width == 32)
        #expect(ImageFixtures.warnings(of: outcome).contains(.imageFlattened))
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(.enabled(if: ImageFormat.supportsTGA))
    func tgaRoundTripUsesImageIO() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [try ImageFixtures.photo(width: 32, height: 24)], as: .png, to: folder.appending(path: "source.png"))
        let context = context(in: folder)
        defer { context.removeStaging() }
        let tga = try stagedURL(try await ImageEdits.convert(input, ImageConversion(format: .tga), context: context))
        #expect(try ContentSniffer.matches(tga, kind: .image))
        let output = try stagedURL(try await ImageEdits.convert(tga, ImageConversion(format: .png), context: context))
        #expect(try ImageFixtures.rawBytes(output) == ImageFixtures.rawBytes(input))
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func pdfTIFFExportKeepsEveryPageAtSettingsDPI(_ mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try pdf(in: folder)
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = mode
        settings.text.pdfImageDPI = 144
        let options = try #require(OperationPlanner.options(for: .pdfToImages, preset: "tiff", settings: settings))
        #expect(options == .pdf(.toTIFF(dpi: 144)))
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(op: .pdfToImages, options: options, inputs: [input])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        #expect(output.lastPathComponent == "pages.tiff")
        try verifyTIFF(output)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func pdfTIFFStagesEveryRasterPage() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try pdf(in: folder)
        let context = context(in: folder)
        defer { context.removeStaging() }
        let output = try stagedURL(PDFExport.tiff(of: input, dpi: 144, context: context))
        try verifyTIFF(output)
    }

    @Test func pdfTIFFRefusesExcessiveRasterBeforeWriting() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "large.pdf")
        var box = CGRect(x: 0, y: 0, width: 20_000, height: 20_000)
        let writer = try #require(CGContext(input as CFURL, mediaBox: &box, nil))
        writer.beginPDFPage(nil)
        writer.endPDFPage()
        writer.closePDF()
        let context = context(in: folder)
        defer { context.removeStaging() }
        #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            try PDFExport.tiff(of: input, dpi: 144, context: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [input.lastPathComponent])
    }

    private func pdf(in folder: URL) throws -> URL {
        let input = folder.appending(path: "pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 72, height: 36)
        let writer = try #require(CGContext(input as CFURL, mediaBox: &box, nil))
        for gray in [0.0, 1.0] {
            writer.beginPDFPage(nil)
            writer.setFillColor(CGColor(gray: gray, alpha: 1))
            writer.fill(box)
            writer.endPDFPage()
        }
        writer.closePDF()
        return input
    }

    private func verifyTIFF(_ output: URL) throws {
        #expect(CGImageSourceGetCount(try ImageFixtures.source(output)) == 2)
        for index in 0..<2 {
            let image = try ImageFixtures.image(output, index: index)
            #expect(image.width == 144 && image.height == 72)
            let properties = try ImageFixtures.properties(output, index: index)
            #expect(properties[kCGImagePropertyDPIWidth] as? Int == 144)
            let pixel = try ImageFixtures.pixel(image, x: 10, y: 10)
            #expect(index == 0 ? pixel[0] < 5 : pixel[0] > 250)
        }
    }

    private func context(in folder: URL) -> ItemContext {
        ItemContext(settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
    }

    private func stagedURL(_ result: ItemResult) throws -> URL {
        switch result {
        case .replace(_, let output): return output.url
        case .derived(_, let outputs): return try #require(outputs.first).url
        default: throw EngineError.encodeFailed("expected staged output")
        }
    }

    private func animation(in folder: URL, loopCount: Int) throws -> URL {
        let url = try ImageFixtures.write(
            [try ImageFixtures.disc(size: 32), try ImageFixtures.photo(width: 32, height: 32)], as: .gif,
            to: folder.appending(path: "finite.gif"),
            properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]],
            frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]])
        if loopCount == Int(UInt16.max) + 1 {
            // ImageIO truncates total plays before encoding.
            var payload = try Data(contentsOf: url)
            let marker = try #require(payload.range(of: Data("NETSCAPE2.0".utf8)))
            let subBlockHeaderBytes = 2
            let countOffset = marker.upperBound + subBlockHeaderBytes
            let repeats = withUnsafeBytes(of: UInt16.max.littleEndian) { Data($0) }
            payload.replaceSubrange(countOffset..<(countOffset + repeats.count), with: repeats)
            try payload.write(to: url)
        }
        return url
    }
}
