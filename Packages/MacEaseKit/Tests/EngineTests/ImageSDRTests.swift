import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite(.serialized) struct ImageSDRTests {
    enum GainMapRetryOperation: CaseIterable {
        case resize, convert, compress
    }

    private static let width = 128
    private static let height = 64
    private static let colorTolerance = 2
    private static let lossyTolerance = 12
    private static let maximumDeltaE = 2.0
    private static let maximumMeanLuminanceError = 0.01
    private static let sampleColumns = [8, 24, 40, 56, 72, 88, 104, 120]
    private static let referenceWhiteNits: Float = 203
    private static let pqPeakNits: Float = 10_000
    private static let hlgPeakNits: Float = 1_000

    private static func ramp(_ colorSpace: CGColorSpace) throws -> CGImage {
        let samples = (0..<width * height).flatMap { position -> [UInt16] in
            let value = UInt16((position % width) * Int(UInt16.max) / (width - 1))
            return [value, value, value, UInt16.max]
        }
        let bytes = samples.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func writeRamp(_ url: URL, colorSpace: CGColorSpace, orientation: UInt32 = 1) throws {
        let metadata = CGImageMetadataCreateMutable()
        #expect(
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment,
                "Keep this comment" as CFString))
        #expect(
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber))
        #expect(
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "urn:macease:test" as CFString, "fixture" as CFString, nil))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "fixture:marker" as CFString, "unchanged" as CFString))
        #expect(
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifColorSpace, 1 as CFNumber))
        #expect(
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "http://ns.adobe.com/photoshop/1.0/" as CFString, "photoshop" as CFString, nil))
        #expect(
            CGImageMetadataSetValueWithPath(
                metadata, nil, "photoshop:ICCProfile" as CFString, "ITU-R BT.2100 PQ" as CFString))
        #expect(
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "http://ns.adobe.com/hdr-gain-map/1.0/" as CFString, "hdrgm" as CFString, nil))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "hdrgm:Version" as CFString, "1.0" as CFString))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, try ramp(colorSpace), metadata, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private static func platformReference(_ url: URL) throws -> CGImage {
        let source = try ImageFixtures.source(url)
        let native = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        if let space = native.colorSpace, CGColorSpaceUsesITUR_2100TF(space) {
            let peak = space.name == CGColorSpace.itur_2100_PQ ? pqPeakNits : hlgPeakNits
            let calibrated = try #require(CGImageCreateCopyWithContentHeadroom(peak / referenceWhiteNits, native))
            let outputSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))
            let canvas = try #require(
                CGContext(
                    data: nil, width: native.width, height: native.height, bitsPerComponent: 16,
                    bytesPerRow: 0, space: outputSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            try #require(
                canvas.draw(
                    calibrated, in: CGRect(x: 0, y: 0, width: native.width, height: native.height),
                    by: .referenceWhiteBased, options: nil))
            return try #require(canvas.makeImage())
        }
        return try #require(
            CGImageSourceCreateImageAtIndex(
                source, 0,
                [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary))
    }

    private static func runGainMapRetry(
        _ operation: GainMapRetryOperation, input: URL, context: ItemContext
    ) async throws -> ItemResult {
        switch operation {
        case .resize:
            return try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
        case .convert:
            return try await ImageEdits.convert(input, ImageConversion(format: .heic, quality: 100), context: context)
        case .compress:
            var limits = MediaLimits()
            limits.maxWidth = 64
            limits.quality = 85
            let preset = PlatformPreset(
                id: "negative-gain-map", name: LocalizedName(en: "Small", ja: "Small"),
                image: limits, gif: nil, video: nil, audio: nil)
            return try await ImageCompressor.compress(
                input,
                ImageCompression(
                    goal: .platform(preset), allowsDownscale: false,
                    allowsFrameRateReduction: false, stripsGPS: false), context: context)
        }
    }

    @Test(arguments: GainMapRetryOperation.allCases)
    func negativeISOGainMapKeepsCalibrationOrToneMapsAfterEncodeFailure(_ operation: GainMapRetryOperation)
        async throws
    {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let resource = try #require(
            Bundle.module.url(forResource: "negative-iso-gain-map", withExtension: "jpg", subdirectory: "Resources"))
        let input = folder.appending(path: "hdr.jpg")
        let original = try Data(contentsOf: resource)
        try original.write(to: input)
        let source = try ImageFixtures.source(input)
        let sourceMap = try #require(
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        let sourceValue = try #require((sourceMap as NSDictionary)[kCGImageAuxiliaryDataInfoMetadata])
        guard case let sourceMetadata as CGImageMetadata = sourceValue else {
            throw EngineError.imageGainMapUnsupported
        }
        let calibrationPath = "HDRToneMap:ChannelMetadata[0].GainMapMin" as CFString
        #expect(CGImageMetadataCopyStringValueWithPath(sourceMetadata, nil, calibrationPath) as String? == "-0.000131")
        let reference = try Self.platformReference(input)
        var settings = Settings()
        settings.outputMode = .newFile
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try await Self.runGainMapRetry(operation, input: input, context: context)
        else { Issue.record("Expected a staged image"); return }
        try await OutputVerifier.verify(output)
        let written = try ImageFixtures.source(output.url)
        if context.warnings == [.imageToneMappedToSDR] {
            guard case .sdrImage = output.check else { Issue.record("Expected SDR verification"); return }
            #expect(try ImageSDR.classification(output.url) == .sdr)
            #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, kCGImageAuxiliaryDataTypeISOGainMap) == nil)
            let rendered = try ImageFixtures.image(output.url)
            for fraction in [0.25, 0.75] {
                let actual = try ImageFixtures.pixel(
                    rendered, x: Int(Double(rendered.width) * fraction), y: rendered.height / 2)
                let expected = try ImageFixtures.pixel(
                    reference, x: Int(Double(reference.width) * fraction), y: reference.height / 2)
                for channel in 0..<3 { #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 24) }
            }
            settings.outputMode = .replace
            let replacement = ItemContext(
                settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
            defer { replacement.removeStaging() }
            await #expect(throws: EngineError.imageHDRUnsupported) {
                try await Self.runGainMapRetry(operation, input: input, context: replacement)
            }
            #expect(replacement.warnings.isEmpty)
        } else {
            #expect(context.warnings.isEmpty)
            guard case .image = output.check else { Issue.record("Expected HDR image verification"); return }
            let writtenMap = try #require(
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, kCGImageAuxiliaryDataTypeISOGainMap))
            let writtenValue = try #require((writtenMap as NSDictionary)[kCGImageAuxiliaryDataInfoMetadata])
            guard case let writtenMetadata as CGImageMetadata = writtenValue else {
                throw EngineError.imageGainMapUnsupported
            }
            #expect(
                CGImageMetadataCreateXMPData(sourceMetadata, nil) as Data?
                    == CGImageMetadataCreateXMPData(writtenMetadata, nil) as Data?)
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func postReadGainMapGeometryFailureToneMapsNewFileAndRefusesReplacement() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(input, variant: .isoMono, heic: false)
        let original = try Data(contentsOf: input)
        let document = try await ImageDocument.load(input)
        let reference = try Self.platformReference(input)
        var settings = Settings()
        settings.outputMode = .newFile
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        func rotate(_ context: ItemContext) async throws -> ItemResult {
            try await ImageOutput.transformed(
                document, as: .jpeg, context: context,
                geometry: { source, output in GainMapGeometry.rotation(source, to: output, degrees: 45) }
            ) { image in try ImagePixels.rotated(image, degrees: 45, fill: CGColor(gray: 1, alpha: 1)) }
        }
        guard case .replace(_, let output) = try await rotate(context) else {
            Issue.record("Expected a staged SDR rotation")
            return
        }
        #expect(context.warnings == [.imageToneMappedToSDR])
        guard case .sdrImage = output.check else { Issue.record("Expected SDR verification"); return }
        try await OutputVerifier.verify(output)
        #expect(try ImageSDR.classification(output.url) == .sdr)
        let written = try ImageFixtures.source(output.url)
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, kCGImageAuxiliaryDataTypeISOGainMap) == nil)
        let rendered = try ImageFixtures.image(output.url)
        let actual = try ImageFixtures.pixel(rendered, x: rendered.width / 2, y: rendered.height / 2)
        let expected = try ImageFixtures.pixel(reference, x: reference.width / 2, y: reference.height / 2)
        for channel in 0..<3 { #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 24) }
        settings.outputMode = .replace
        let replacement = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { replacement.removeStaging() }
        await #expect(throws: EngineError.imageHDRUnsupported) { try await rotate(replacement) }
        #expect(replacement.warnings.isEmpty)
        #expect(try Data(contentsOf: input) == original)
    }

    private static func expectDistinctRamp(_ image: CGImage) throws {
        let outputSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let canvas = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                space: outputSpace,
                bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let samples = try #require(canvas.data).assumingMemoryBound(to: UInt16.self)
        var previous = Int(samples[(height / 2) * width * 4])
        for column in 1..<width {
            let current = Int(samples[((height / 2) * width + column) * 4])
            #expect(current > previous, "Column \(column) must retain its luminance step")
            previous = current
        }
    }

    private static func lab(_ rgba: [UInt8]) throws -> (lightness: Double, a: Double, b: Double) {
        let scale = Double(UInt8.max)
        let color = CGColor(
            srgbRed: Double(rgba[0]) / scale, green: Double(rgba[1]) / scale,
            blue: Double(rgba[2]) / scale, alpha: 1)
        let space = try #require(CGColorSpace(name: CGColorSpace.genericLab))
        let components = try #require(
            color.converted(to: space, intent: .relativeColorimetric, options: nil)?.components)
        try #require(components.count >= 3)
        return (Double(components[0]), Double(components[1]), Double(components[2]))
    }

    private static func luminance(_ rgba: [UInt8]) -> Double {
        let linear = rgba.prefix(3).map { component in
            let encoded = Double(component) / Double(UInt8.max)
            return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    @Test(arguments: [CGColorSpace.sRGB as String, CGColorSpace.displayP3 as String])
    func wideGamutAndSixteenBitsDoNotProveHDR(_ spaceName: String) throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "sdr.png")
        try ImageFixtures.write([Self.ramp(#require(CGColorSpace(name: spaceName as CFString)))], as: .png, to: input)
        let original = try Data(contentsOf: input)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        #expect(try ImageSDR.classification(input) == .sdr)
        guard case .skipped(.alreadySDR) = try ImageSDR.convert(input, context: context) else {
            Issue.record("SDR input must skip before encoding")
            return
        }
        #expect(try Data(contentsOf: input) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == contents)
        #expect(context.warnings.isEmpty)
    }

    @Test(arguments: [CGColorSpace.itur_2100_PQ as String, CGColorSpace.itur_2100_HLG as String])
    func transferRampsKeepNeutralHighlightDistinctions(_ spaceName: String) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.png")
        try Self.writeRamp(input, colorSpace: #require(CGColorSpace(name: spaceName as CFString)))
        let original = try Data(contentsOf: input)
        #expect(try ImageSDR.classification(input) == .unknownHDR)
        let reference = try Self.platformReference(input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(let source, let output) = try ImageSDR.convert(input, context: context) else {
            Issue.record("Expected a staged SDR image")
            return
        }
        #expect(source == input)
        guard case .sdrImage = output.check else {
            Issue.record("SDR output must request SDR verification")
            return
        }
        try await OutputVerifier.verify(output)
        #expect(try ImageSDR.classification(output.url) == .sdr)
        #expect(context.warnings == [.hdrProvenanceUnknown])
        #expect(try Data(contentsOf: input) == original)
        let rendered = try ImageFixtures.image(output.url)
        #expect(rendered.colorSpace?.name == CGColorSpace.displayP3)
        var previous = -1
        var luminanceError = 0.0
        for column in Self.sampleColumns {
            let actual = try ImageFixtures.pixel(rendered, x: column, y: Self.height / 2)
            let expected = try ImageFixtures.pixel(reference, x: column, y: Self.height / 2)
            #expect(Int(actual[0]) > previous)
            #expect(abs(Int(actual[0]) - Int(actual[1])) <= Self.colorTolerance)
            #expect(abs(Int(actual[1]) - Int(actual[2])) <= Self.colorTolerance)
            for channel in 0..<3 {
                #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= Self.colorTolerance)
            }
            let actualLab = try Self.lab(actual)
            let expectedLab = try Self.lab(expected)
            let neutralDeltaE = hypot(actualLab.a, actualLab.b)
            let referenceDeltaE = sqrt(
                pow(actualLab.lightness - expectedLab.lightness, 2)
                    + pow(actualLab.a - expectedLab.a, 2) + pow(actualLab.b - expectedLab.b, 2))
            #expect(neutralDeltaE <= Self.maximumDeltaE)
            #expect(referenceDeltaE <= Self.maximumDeltaE)
            luminanceError += abs(Self.luminance(actual) - Self.luminance(expected))
            previous = Int(actual[0])
        }
        #expect(luminanceError / Double(Self.sampleColumns.count) <= Self.maximumMeanLuminanceError)
        #expect(previous < Int(UInt8.max))
        try Self.expectDistinctRamp(rendered)
        for column in [124, Self.width - 1] {
            let highlight = try ImageFixtures.pixel(rendered, x: column, y: Self.height / 2)
            #expect(Int(highlight[0]) > previous)
            previous = Int(highlight[0])
        }
        let written = try ImageFixtures.source(output.url)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(written, 0, nil))
        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "fixture:marker" as CFString) as String?
                == "unchanged")
        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "exif:UserComment" as CFString) as String?
                == "Keep this comment")
        #expect(CGImageMetadataCopyTagWithPath(metadata, nil, "hdrgm:Version" as CFString) == nil)
        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "exif:ColorSpace" as CFString) as String? == "65535")
        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "photoshop:ICCProfile" as CFString) as String?
                == "Display P3")
    }

    @Test(arguments: Array(UInt32(1)...UInt32(8)))
    func orientationRemainsVisuallyUpright(_ orientation: UInt32) throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "oriented.png")
        try Self.writeRamp(
            input, colorSpace: #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ)), orientation: orientation)
        let reference = try Self.platformReference(input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try ImageSDR.convert(input, context: context) else {
            Issue.record("Expected an oriented SDR image")
            return
        }
        let rendered = try ImageFixtures.image(output.url)
        let swapsAxes = orientation >= 5
        #expect(rendered.width == (swapsAxes ? Self.height : Self.width))
        #expect(rendered.height == (swapsAxes ? Self.width : Self.height))
        #expect(try ImageFixtures.properties(output.url)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        for fraction in [0.25, 0.75] {
            let column = Int(Double(rendered.width) * fraction)
            let row = Int(Double(rendered.height) * fraction)
            let sourceColumn: Int
            switch orientation {
            case 1, 4: sourceColumn = column
            case 2, 3: sourceColumn = Self.width - 1 - column
            case 5, 6: sourceColumn = row
            default: sourceColumn = Self.width - 1 - row
            }
            let actual = try ImageFixtures.pixel(rendered, x: column, y: row)
            let expected = try ImageFixtures.pixel(reference, x: sourceColumn, y: Self.height / 2)
            #expect(abs(Int(actual[0]) - Int(expected[0])) <= Self.colorTolerance)
        }
    }

    @Test(arguments: GainMapFixture.allCases)
    func gainMapsAreRemovedOnlyFromSDROutput(_ fixture: GainMapFixture) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: fixture.heic ? "gain-map.heic" : "gain-map.jpg")
        try ImageGainMapIntegrationTests.fixture(input, variant: fixture.variant, heic: fixture.heic)
        let original = try Data(contentsOf: input)
        #expect(try ImageSDR.classification(input) == .unknownHDR)
        let reference = try Self.platformReference(input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try ImageSDR.convert(input, context: context) else {
            Issue.record("Expected a staged gain-map conversion")
            return
        }
        try await OutputVerifier.verify(output)
        #expect(try Data(contentsOf: input) == original)
        let source = try ImageFixtures.source(output.url)
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) == nil)
        }
        let rendered = try ImageFixtures.image(output.url)
        for x in [rendered.width / 4, rendered.width * 3 / 4] {
            for y in [rendered.height / 4, rendered.height * 3 / 4] {
                let actual = try ImageFixtures.pixel(rendered, x: x, y: y)
                let expected = try ImageFixtures.pixel(reference, x: x, y: y)
                for channel in 0..<3 {
                    #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= Self.lossyTolerance)
                }
            }
        }
    }

    @Test(arguments: GainMapFixture.allCases)
    func ordinaryConversionToneMapsGainMapsAndRefusesReplacement(_ fixture: GainMapFixture) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: fixture.heic ? "hdr.heic" : "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(input, variant: fixture.variant, heic: fixture.heic)
        let original = try Data(contentsOf: input)
        let reference = try Self.platformReference(input)
        var settings = Settings()
        settings.outputMode = .replace
        let replacement = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { replacement.removeStaging() }
        await #expect(throws: EngineError.imageHDRUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: .png), context: replacement)
        }
        #expect(replacement.warnings.isEmpty)
        settings.outputMode = .newFile
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageEdits.convert(
                input, ImageConversion(format: .png), context: context)
        else { Issue.record("Expected a staged SDR conversion"); return }
        #expect(context.warnings == [.imageToneMappedToSDR])
        try await OutputVerifier.verify(output)
        #expect(try ImageSDR.classification(output.url) == .sdr)
        let rendered = try ImageFixtures.image(output.url)
        for column in [rendered.width / 4, rendered.width * 3 / 4] {
            let actual = try ImageFixtures.pixel(rendered, x: column, y: rendered.height / 2)
            let expected = try ImageFixtures.pixel(reference, x: column, y: reference.height / 2)
            for channel in 0..<3 {
                #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= Self.colorTolerance)
            }
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(arguments: [CGColorSpace.itur_2100_PQ as String, CGColorSpace.itur_2100_HLG as String])
    func ordinaryJPEGConversionToneMapsTransferRamps(_ spaceName: String) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.png")
        try Self.writeRamp(input, colorSpace: #require(CGColorSpace(name: spaceName as CFString)))
        let original = try Data(contentsOf: input)
        let reference = try Self.platformReference(input)
        var settings = Settings()
        settings.outputMode = .replace
        let replacement = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { replacement.removeStaging() }
        await #expect(throws: EngineError.imageHDRUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: .jpeg), context: replacement)
        }
        settings.outputMode = .newFile
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageEdits.convert(
                input, ImageConversion(format: .jpeg, quality: 100), context: context)
        else { Issue.record("Expected a staged SDR conversion"); return }
        #expect(context.warnings == [.imageToneMappedToSDR])
        try await OutputVerifier.verify(output)
        let rendered = try ImageFixtures.image(output.url)
        for column in Self.sampleColumns {
            let actual = try ImageFixtures.pixel(rendered, x: column, y: Self.height / 2)
            let expected = try ImageFixtures.pixel(reference, x: column, y: Self.height / 2)
            for channel in 0..<3 {
                #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= Self.lossyTolerance)
            }
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(arguments: [ImageFormat.bmp, .gif, .ico, .icns, .tga, .avif, .jxl, .webp, .tiff])
    func toneMappedOutputPassesVerificationAcrossRasterFormats(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(input, variant: .isoMono, heic: false)
        let original = try Data(contentsOf: input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageEdits.convert(
                input, ImageConversion(format: format), context: context)
        else { Issue.record("Expected a staged SDR conversion"); return }
        // These formats cannot store the fixture's EXIF.
        let dropsEXIF: Set<ImageFormat> = [.bmp, .gif, .ico, .icns, .tga]
        let expected: [ItemWarning] =
            dropsEXIF.contains(format)
            ? [.imageMetadataDropped([.exif]), .imageToneMappedToSDR] : [.imageToneMappedToSDR]
        #expect(context.warnings == expected)
        try await OutputVerifier.verify(output)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func flatteningGainMapTransparencyToneMapsBeforeCompositing() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "transparent-hdr.heic")
        let extent = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let base = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1, alpha: 0.5)).cropped(to: extent)
        let hdr = CIImage(color: CIColor(red: 1.8, green: 0.5, blue: 0.2, alpha: 0.5))
            .cropped(to: extent).settingContentHeadroom(4)
        let encoded = try #require(
            CIContext().heifRepresentation(
                of: base, format: .RGBA8, colorSpace: ImageFixtures.sRGB, options: [.hdrImage: hdr]))
        try encoded.write(to: input)
        let loaded = try await ImageDocument.load(input)
        try #require(loaded.containsHDR)
        try #require(try ImageEncoder.hasTransparency(loaded.first))
        let reference = try Self.platformReference(input)
        let expectedCanvas = try ImageFixtures.canvas(width: Self.width, height: Self.height) { canvas in
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            canvas.fill(extent)
            canvas.draw(reference, in: extent)
        }
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageEdits.convert(
                input, ImageConversion(format: .jpeg, quality: 100), context: context)
        else { Issue.record("Expected a staged SDR conversion"); return }
        #expect(context.warnings == [.imageTransparencyFlattened, .imageToneMappedToSDR])
        try ImageSDR.verify(output.url)
        let actual = try ImageFixtures.pixel(ImageFixtures.image(output.url), x: Self.width / 2, y: Self.height / 2)
        let expected = try ImageFixtures.pixel(expectedCanvas, x: Self.width / 2, y: Self.height / 2)
        for channel in 0..<3 {
            #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= Self.lossyTolerance)
        }
        #expect(try Data(contentsOf: input) == encoded)
    }

    @Test func fullDepthTIFFConversionPreservesPQWithoutWarning() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.png")
        try Self.writeRamp(input, colorSpace: #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ)))
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageEdits.convert(
                input, ImageConversion(format: .tiff), context: context)
        else { Issue.record("Expected a staged HDR conversion"); return }
        let rendered = try ImageFixtures.image(output.url)
        #expect(rendered.bitsPerComponent == 16)
        #expect(rendered.colorSpace?.name == CGColorSpace.itur_2100_PQ)
        #expect(try ImageSDR.classification(output.url) == .unknownHDR)
        #expect(context.warnings.isEmpty)
    }

    @Test func iconExportToneMapsEvenWithReplaceSelected() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(input, variant: .isoMono, heic: false)
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .derived(_, let outputs) = try await ImageExports.iconSet(input, kind: .ico, context: context)
        else { Issue.record("Icons must remain derived"); return }
        #expect(context.warnings == [.imageMetadataDropped([.exif]), .imageToneMappedToSDR])
        try await OutputVerifier.verify(#require(outputs.first))
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func presetCompressionToneMapsGainMapsBeforeEncoding() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.jpg")
        try ImageGainMapIntegrationTests.fixture(input, variant: .isoMono, heic: false)
        let original = try Data(contentsOf: input)
        var preset = try #require(PresetLibrary.bundledPresets.first)
        var limits = MediaLimits()
        limits.formats = ["webp"]
        preset.image = limits
        let compression = ImageCompression(
            goal: .platform(preset), allowsDownscale: false, allowsFrameRateReduction: false, stripsGPS: false)
        var settings = Settings()
        settings.outputMode = .replace
        let replacement = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { replacement.removeStaging() }
        await #expect(throws: EngineError.imageHDRUnsupported) {
            try await ImageCompressor.compress(input, compression, context: replacement)
        }
        settings.outputMode = .newFile
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try await ImageCompressor.compress(input, compression, context: context)
        else { Issue.record("Expected a staged SDR preset"); return }
        #expect(context.warnings == [.imageToneMappedToSDR])
        try await OutputVerifier.verify(output)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func verificationRejectsRemainingHDR() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.png")
        try Self.writeRamp(input, colorSpace: #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ)))
        #expect(throws: EngineError.sdrVerificationFailed) { try ImageSDR.verify(input) }
    }

    @Test func metadataWithoutHDRPixelsCannotAuthorizeConversion() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "ambiguous.png")
        try Self.writeRamp(input, colorSpace: #require(CGColorSpace(name: CGColorSpace.sRGB)))
        let original = try Data(contentsOf: input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        #expect(try ImageSDR.classification(input) == .unknownHDR)
        #expect(throws: EngineError.hdrConversionUnsupported) { try ImageSDR.convert(input, context: context) }
        #expect(try Data(contentsOf: input) == original)
        #expect(context.warnings.isEmpty)
    }

    @Test func cancellationLeavesOriginalAndFolderUntouched() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.png")
        try Self.writeRamp(input, colorSpace: #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ)))
        let original = try Data(contentsOf: input)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImageSDR.convert(input, context: context)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try Data(contentsOf: input) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == contents)
    }
}
