import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Engine

@Suite(.serialized) struct ImagePropertyLossTests {
    private func taggedJPEG(in folder: URL, fields: [MetadataField]) throws -> URL {
        let metadata = CGImageMetadataCreateMutable()
        if fields.contains(.exif) {
            try #require(
                CGImageMetadataSetValueMatchingImageProperty(
                    metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel, "Fixture Lens" as CFString)
            )
        }
        if fields.contains(.iptc) {
            try #require(
                CGImageMetadataSetValueMatchingImageProperty(
                    metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract,
                    "Fixture Caption" as CFString))
        }
        if fields.contains(.xmp) {
            try #require(
                CGImageMetadataRegisterNamespaceForPrefix(
                    metadata, "urn:macease:fixture" as CFString, "fixture" as CFString, nil))
            try #require(
                CGImageMetadataSetValueWithPath(metadata, nil, "fixture:label" as CFString, "Fixture XMP" as CFString))
        }
        let input = folder.appending(path: "tagged.jpg")
        let destination = try #require(
            CGImageDestinationCreateWithURL(input as CFURL, ImageFormat.jpeg.contentType.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImageAndMetadata(
            destination, try ImageFixtures.photo(width: 16, height: 16), metadata, nil)
        try #require(CGImageDestinationFinalize(destination))
        return input
    }

    @Test(arguments: [ImageFormat.bmp, .tga, .ico], [Settings.OutputMode.newFile, .replace])
    func metadataLossFollowsTheOutputMode(format: ImageFormat, mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let fields: [MetadataField] = [.exif, .xmp, .iptc]
        let input = try taggedJPEG(in: folder, fields: fields)
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = mode
        let support = folder.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: support), progress: { _ in })
        defer { context.removeStaging() }
        if mode == .replace {
            await #expect(throws: EngineError.imageMetadataUnsupported(fields)) {
                try await ImageEdits.convert(input, ImageConversion(format: format), context: context)
            }
            #expect(context.warnings.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)
        } else {
            guard
                case .replace(_, let output) = try await ImageEdits.convert(
                    input, ImageConversion(format: format), context: context)
            else { Issue.record("Expected a staged conversion"); return }
            #expect(context.warnings == [.imageMetadataDropped(fields)])
            try await OutputVerifier.verify(output)
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test(arguments: [[MetadataField.exif], [.xmp], [.iptc]])
    func metadataWarningsNameOnlyPresentClasses(fields: [MetadataField]) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try taggedJPEG(in: folder, fields: fields)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        _ = try await ImageEdits.convert(input, ImageConversion(format: .bmp), context: context)
        #expect(context.warnings == [.imageMetadataDropped(fields)])
    }

    @Test func emptyMetadataDoesNotRefuseReplacement() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try taggedJPEG(in: folder, fields: [])
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace = try await ImageEdits.convert(input, ImageConversion(format: .bmp), context: context)
        else { Issue.record("Expected an untagged conversion"); return }
        #expect(context.warnings.isEmpty)
        #expect(
            ImageMetadata.presentFields(
                nil,
                properties: [
                    kCGImagePropertyExifDictionary: [:], kCGImagePropertyIPTCDictionary: [:],
                    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitudeRef: ""],
                ]
            ).isEmpty)
    }

    @Test(arguments: ["", "Retained value"])
    func structuredMetadataCountsOnlyNonemptyValues(text: String) throws {
        let namespace = "urn:macease:fixture" as CFString
        let prefix = "fixture" as CFString
        let child = try #require(
            CGImageMetadataTagCreate(namespace, prefix, "child" as CFString, .string, text as CFString))
        let parent = try #require(
            CGImageMetadataTagCreate(
                namespace, prefix, "parent" as CFString, .structure, ["fixture:child": child] as CFDictionary))
        let metadata = CGImageMetadataCreateMutable()
        try #require(CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, nil))
        try #require(CGImageMetadataSetTagWithPath(metadata, nil, "fixture:parent" as CFString, parent))
        #expect(ImageMetadata.presentFields(metadata) == (text.isEmpty ? [] : [.xmp]))
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func explicitMetadataStrippingDoesNotWarnAboutLoss(mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try taggedJPEG(in: folder, fields: [.exif, .xmp, .iptc])
        var settings = Settings()
        settings.outputMode = mode
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageMetadata.strip(
                input, fields: Set(MetadataField.allCases), context: context)
        else { Issue.record("Expected stripped metadata"); return }
        let document = try await ImageDocument.load(output.url)
        #expect(try document.metadataFields().isEmpty)
        #expect(context.warnings.isEmpty)
    }

    @Test func replacementRefusesTransparencyLossBeforeStaging() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [ImageFixtures.disc(background: nil)], as: .png, to: folder.appending(path: "transparent.png"))
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.imageTransparencyUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: .jpeg), context: context)
        }
        #expect(try Data(contentsOf: input) == original)
        #expect(context.warnings.isEmpty)
    }

    @Test(arguments: [ImageFormat.jpeg, .bmp], [RGBColor.white, .chromaBlue])
    func newFileDisclosesTransparencyLoss(_ format: ImageFormat, _ background: RGBColor) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [ImageFixtures.disc(background: nil)], as: .png, to: folder.appending(path: "transparent.png"))
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.image.customBackground = background
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let output) = try await ImageEdits.convert(
                input, ImageConversion(format: format), context: context)
        else { Issue.record("Expected a staged conversion"); return }
        #expect(context.warnings == [.imageTransparencyFlattened])
        let corner = try ImageFixtures.pixel(ImageFixtures.image(output.url), x: 2, y: 2)
        let tolerance = 4
        for (actual, expected) in zip(corner.prefix(3), [background.red, background.green, background.blue]) {
            #expect(abs(Int(actual) - Int(expected)) <= tolerance)
        }
        #expect(corner[3] == UInt8.max)
        #expect(try Data(contentsOf: input) == original)
    }
    @Test(arguments: [ImageFormat.gif, .svg], [Settings.OutputMode.newFile, .replace])
    func binaryAlphaFormatsDisclosePartialTransparencyLoss(_ format: ImageFormat, _ mode: Settings.OutputMode)
        async throws
    {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let edge = 32
        let translucent = try ImageFixtures.canvas(width: edge, height: edge) { canvas in
            canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
            canvas.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        let input = try ImageFixtures.write([translucent], as: .png, to: folder.appending(path: "translucent.png"))
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = mode
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        if mode == .replace {
            await #expect(throws: EngineError.imageTransparencyUnsupported) {
                try await ImageEdits.convert(input, ImageConversion(format: format), context: context)
            }
            #expect(context.warnings.isEmpty)
        } else {
            guard
                case .replace(_, let output) = try await ImageEdits.convert(
                    input, ImageConversion(format: format, svgColors: 4), context: context)
            else { Issue.record("Expected a staged conversion"); return }
            #expect(context.warnings == [.imageTransparencyFlattened])
            try await OutputVerifier.verify(output)
            if format == .svg {
                let markup = try String(contentsOf: output.url, encoding: .utf8)
                #expect(markup.contains("fill=\"#ff7f7f\""))
            } else {
                let center = try ImageFixtures.pixel(ImageFixtures.image(output.url), x: edge / 2, y: edge / 2)
                #expect(center == [255, 127, 127, 255])
            }
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func opaqueAlphaChannelDoesNotRefuseReplacement() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [ImageFixtures.disc()], as: .png, to: folder.appending(path: "opaque.png"))
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace = try await ImageEdits.convert(input, ImageConversion(format: .jpeg), context: context)
        else { Issue.record("Opaque pixels must convert"); return }
        #expect(context.warnings.isEmpty)
    }

    @Test func almostOpaqueSixteenBitAlphaStillRefusesReplacement() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let samples: [UInt16] = [0, 0, 0, UInt16.max - 1]
        let pixels = samples.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(
            CGImage(
                width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8,
                space: ImageFixtures.sRGB,
                bitmapInfo: [.byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try ImageFixtures.write([image], as: .png, to: folder.appending(path: "almost-opaque.png"))
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.imageTransparencyUnsupported) {
            try await ImageEdits.convert(input, ImageConversion(format: .jpeg), context: context)
        }
    }

    @Test(arguments: [ImageFormat.jpeg, .gif], [Settings.OutputMode.newFile, .replace])
    func platformFormatsUseTheSameTransparencyPolicy(_ format: ImageFormat, _ mode: Settings.OutputMode) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [ImageFixtures.disc(background: nil)], as: .png, to: folder.appending(path: "transparent.png"))
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = mode
        settings.image.customBackground = .chromaBlue
        var preset = try #require(PresetLibrary.bundledPresets.first)
        var limits = MediaLimits()
        limits.formats = [format.rawValue]
        preset.image = limits
        let compression = ImageCompression(
            goal: .platform(preset), allowsDownscale: false, allowsFrameRateReduction: false, stripsGPS: false)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        if mode == .replace {
            await #expect(throws: EngineError.imageTransparencyUnsupported) {
                try await ImageCompressor.compress(input, compression, context: context)
            }
        } else {
            guard
                case .replace(_, let output) = try await ImageCompressor.compress(input, compression, context: context)
            else { Issue.record("Expected a staged preset"); return }
            #expect(context.warnings == [.imageTransparencyFlattened])
            let corner = try ImageFixtures.pixel(ImageFixtures.image(output.url), x: 2, y: 2)
            let tolerance = 4
            #expect(abs(Int(corner[2]) - Int(RGBColor.chromaBlue.blue)) <= tolerance)
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func letterboxPreservesSourceTransparency() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let edge = 40
        let input = try ImageFixtures.write(
            [ImageFixtures.disc(size: edge, background: nil)], as: .png, to: folder.appending(path: "logo.png"))
        var settings = Settings()
        settings.outputMode = .replace
        var preset = try #require(PresetLibrary.bundledPresets.first)
        var limits = MediaLimits()
        limits.formats = ["png"]
        let ratio = AspectRatio(width: 2, height: 1)
        limits.aspect = AspectRange(min: ratio, max: ratio, fit: .letterbox)
        preset.image = limits
        let compression = ImageCompression(
            goal: .platform(preset), allowsDownscale: false, allowsFrameRateReduction: false, stripsGPS: false)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try await ImageCompressor.compress(input, compression, context: context)
        else { Issue.record("Expected a letterboxed image"); return }
        let rendered = try ImageFixtures.image(output.url)
        #expect(rendered.width == edge * 2)
        #expect(try ImageFixtures.pixel(rendered, x: edge / 2 + 2, y: 2)[3] == 0)
        #expect(try ImageFixtures.pixel(rendered, x: 2, y: 2)[3] == UInt8.max)
        #expect(context.warnings.isEmpty)
    }

}
