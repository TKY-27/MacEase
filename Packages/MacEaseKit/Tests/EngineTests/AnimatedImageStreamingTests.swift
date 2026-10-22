import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite(.serialized) struct AnimatedImageStreamingTests {
    private static let frameCount = 300
    private static let width = 640
    private static let height = 480
    private static let border = 20
    private static let lens = "Streaming Test Lens"

    @Test func targetCompressionReplaysFramesAndKeepsDuration() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let frames = try (0..<6).map { try ImageFixtures.photo(width: 160, height: 120, seed: $0) }
        let input = try ImageFixtures.write(
            frames, as: .gif, to: folder.appending(path: "candidate.gif"),
            frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
        let original = try Data(contentsOf: input)
        let target = Int64(original.count / 2)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let output = try Self.output(
            try await ImageCompressor.compress(
                input,
                ImageCompression(
                    goal: .bytes(target), allowsDownscale: true,
                    allowsFrameRateReduction: true, stripsGPS: false), context: context))
        #expect(try ImageFixtures.fileSize(output) <= target)
        let source = try ImageFixtures.source(output)
        #expect(CGImageSourceGetCount(source) > 1)
        let seconds = try (0..<CGImageSourceGetCount(source)).reduce(0.0) { total, index in
            let properties = try ImageFixtures.properties(output, index: index)
            let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            return total + (try #require(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double))
        }
        #expect(abs(seconds - 0.6) < 0.001)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func webPStreamingPreservesAndStripsMetadata() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try ImageFixtures.write(
            [try ImageFixtures.disc(size: 32), try ImageFixtures.photo(width: 32, height: 32)], as: .png,
            to: folder.appending(path: "tagged.png"),
            frameProperties: [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: Self.lens],
            ])
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let converted = try Self.output(
            try await ImageEdits.convert(input, ImageConversion(format: .webp), context: context))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(try ImageFixtures.source(converted), 0, nil))
        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "exifEX:LensModel" as CFString) as String?
                == Self.lens)
        let stripped = try Self.output(try await ImageMetadata.strip(converted, fields: [.exif], context: context))
        #expect(CGImageSourceGetCount(try ImageFixtures.source(stripped)) == 2)
        if let remaining = CGImageSourceCopyMetadataAtIndex(try ImageFixtures.source(stripped), 0, nil) {
            #expect(CGImageMetadataCopyStringValueWithPath(remaining, nil, "exifEX:LensModel" as CFString) == nil)
        }
    }

    @Test(arguments: ["gif", "png"])
    func ordinaryAnimationEditsPreserveFramesAndTiming(_ format: String) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try Self.animation(in: folder, format: format)
        let original = try Data(contentsOf: input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        let resized = try Self.output(
            try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context))
        try Self.verify(resized, width: Self.width / 2, height: Self.height / 2)

        var limits = MediaLimits()
        limits.maxWidth = Self.width / 2
        limits.maxBytes = 1_000_000
        let preset = PlatformPreset(
            id: "animation-test", name: LocalizedName(en: "Animation test", ja: "Animation test"),
            image: limits, gif: limits)
        let compression = ImageCompression(
            goal: .platform(preset), allowsDownscale: true, allowsFrameRateReduction: false, stripsGPS: false)
        let compressed = try Self.output(try await ImageCompressor.compress(input, compression, context: context))
        try Self.verify(compressed, width: Self.width / 2, height: Self.height / 2)
        #expect(try ImageFixtures.fileSize(compressed) <= #require(limits.targetBytes))

        let trimmed = try Self.output(try await ImageEdits.trimBorders(input, context: context))
        try Self.verify(trimmed, width: Self.width - 2 * Self.border, height: Self.height - 2 * Self.border)
        let last = try ImageFixtures.image(trimmed, index: Self.frameCount - 1)
        let pixel = try ImageFixtures.pixel(last, x: last.width - 1, y: last.height / 2)
        #expect(pixel[2] > 240 && pixel[0] < 15)

        if format == "png" {
            let stripped = try Self.output(
                try await ImageMetadata.strip(input, fields: [.exif], context: context))
            try Self.verify(stripped, width: Self.width, height: Self.height)
            for index in [0, Self.frameCount - 1] {
                let properties = try ImageFixtures.properties(stripped, index: index)
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                #expect(exif?[kCGImagePropertyExifLensModel] == nil)
                let before = try ImageFixtures.image(input, index: index)
                let after = try ImageFixtures.image(stripped, index: index)
                #expect(before.dataProvider?.data as Data? == after.dataProvider?.data as Data?)
            }
        } else {
            let converted = try Self.output(
                try await ImageEdits.convert(input, ImageConversion(format: .webp), context: context))
            try Self.verify(converted, width: Self.width, height: Self.height)
            let rotated = try Self.output(
                try await ImageEdits.rotate(converted, degrees: 90, fill: nil, context: context))
            try Self.verify(rotated, width: Self.height, height: Self.width)
            let flipped = try Self.output(try await ImageEdits.flip(input, .horizontal, context: context))
            try Self.verify(flipped, width: Self.width, height: Self.height)
            let apng = try Self.output(
                try await ImageEdits.convert(converted, ImageConversion(format: .png), context: context))
            try Self.verify(apng, width: Self.width, height: Self.height)
        }
        #expect(try Data(contentsOf: input) == original)
    }

    private static func animation(in folder: URL, format: String) throws -> URL {
        let url = folder.appending(path: "animation.\(format)")
        let type: UTType = format == "gif" ? .gif : .png
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frameCount, nil))
        let dictionary = format == "gif" ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let delay = format == "gif" ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
        let loop = format == "gif" ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        CGImageDestinationSetProperties(destination, [dictionary: [loop: 0]] as CFDictionary)
        for index in 0..<frameCount {
            try autoreleasepool {
                let image = try ImageFixtures.canvas(width: width, height: height) { canvas in
                    canvas.setFillColor(CGColor(gray: 1, alpha: 1))
                    canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    let isLast = index == frameCount - 1
                    let horizontalInset = isLast ? border : border * 2
                    canvas.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
                    canvas.fill(
                        CGRect(
                            x: horizontalInset, y: border, width: width - 2 * horizontalInset,
                            height: height - 2 * border))
                    canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                    let markerSize = 8
                    canvas.fill(CGRect(x: border * 2 + index, y: height / 2, width: markerSize, height: markerSize))
                }
                let duration = index % 3 == 2 ? 0.04 : 0.03
                let properties: [CFString: Any] = [
                    dictionary: [delay: duration],
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: lens],
                ]
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
        }
        try #require(CGImageDestinationFinalize(destination))
        #expect(CGImageSourceGetCount(try ImageFixtures.source(url)) == frameCount)
        if format == "png" {
            let exif = try ImageFixtures.properties(url)[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifLensModel] as? String == lens)
        }
        return url
    }

    private static func output(_ result: ItemResult) throws -> URL {
        guard case .replace(_, let staged) = result else {
            Issue.record("Expected a staged animation, received \(result)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return staged.url
    }

    private static func verify(_ url: URL, width: Int, height: Int) throws {
        let source = try ImageFixtures.source(url)
        #expect(CGImageSourceGetCount(source) == frameCount)
        let type = try #require(CGImageSourceGetType(source).flatMap { UTType($0 as String) })
        let keys = try #require(AnimationKeys(type: type))
        var seconds = 0.0
        for index in 0..<frameCount {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
            let duration = try #require(keys.delay(in: properties))
            #expect(abs(duration - (index % 3 == 2 ? 0.04 : 0.03)) < 0.001)
            seconds += duration
        }
        #expect(abs(seconds - 10) < 0.001)
        let container = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        #expect(keys.loopCount(in: container) == 0)
        for index in [0, frameCount - 1] {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(image.width == width && image.height == height)
        }
    }
}
