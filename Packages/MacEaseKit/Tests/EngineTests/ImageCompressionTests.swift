import CoreGraphics
import Formats
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine

private typealias Fixture = ImageFixtures

/// SPEC 8.10 lower bound.
private let acceptedShare = 0.92

private func compression(_ goal: CompressionGoal, downscale: Bool = true) -> ImageOperation {
    .compress(
        ImageCompression(goal: goal, allowsDownscale: downscale, allowsFrameRateReduction: true, stripsGPS: false))
}

private func expectTargetHit(for format: ImageFormat, minimumShare: Double = acceptedShare) async throws {
    let folder = try TestVolume.makeFolder()
    let source = try Fixture.write(
        [try Fixture.photo(width: 800, height: 600)], as: .png, to: folder.appending(path: "source.png"))
    let input = try Fixture.output(of: try await Fixture.run(.imageConvert, preset: format.rawValue, inputs: [source]))
    let target = try Fixture.fileSize(input) / 2

    let outcome = try await Fixture.run(.imageCompress, compression(.bytes(target)), inputs: [input])

    let output = try Fixture.output(of: outcome)
    #expect(output.pathExtension == input.pathExtension)
    let size = try Fixture.fileSize(output)
    #expect(size <= target, "\(format) \(size) > \(target)")
    #expect(Double(size) >= Double(target) * minimumShare, "\(format) \(size) under share of \(target)")
    #expect(try Fixture.image(output).width == 800)
}

@Suite(.serialized) struct ImageCompressionTests {
    @Test(arguments: [ImageFormat.jpeg, .webp, .jxl])
    func qualityFormatsLandJustUnderTheTarget(format: ImageFormat) async throws {
        try await expectTargetHit(for: format)
    }

    /// libaom exposes only 64 quantizer steps.
    @Test func avifStaysUnderTheTarget() async throws {
        try await expectTargetHit(for: .avif, minimumShare: 0)
    }

    /// ImageIO quantizes HEIC quality into coarse steps.
    @Test(.enabled(if: ImageFixtures.canEncodeHEIC)) func heicStaysUnderTheTarget() async throws {
        try await expectTargetHit(for: .heic, minimumShare: 0)
    }

    @Test(arguments: [false, true])
    func pngQuantizesUnderTheTarget(translucent: Bool) async throws {
        let folder = try TestVolume.makeFolder()
        let original = try PixelBuffer(cgImage: Fixture.photo(width: 400, height: 300))
        var rgba = original.rgba
        if translucent {
            for y in 0..<original.height {
                for x in 0..<original.width { rgba[(y * original.width + x) * 4 + 3] = UInt8(x * 255 / 399) }
            }
        }
        let profile = try #require(CGColorSpace(name: translucent ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
        let image = try PixelBuffer(width: 400, height: 300, rgba: rgba, colorSpace: profile).makeCGImage()
        let input = try Fixture.write([image], as: .png, to: folder.appending(path: "shot.png"))
        let saved = try Data(contentsOf: input)
        let target = Int64(saved.count / 2)
        let outcome = try await Fixture.run(
            .imageCompress, compression(.bytes(target)), inputs: [input], outputMode: .newFile)
        let output = try Fixture.output(of: outcome)
        let decoded = try Fixture.image(output)
        #expect(try Fixture.fileSize(output) <= target)
        #expect(try Data(contentsOf: input) == saved)
        #expect(decoded.width > 0 && decoded.width <= 400)
        #expect(decoded.height > 0 && decoded.height <= 300)
        let decodedProfile = decoded.colorSpace?.baseColorSpace ?? decoded.colorSpace
        #expect((decodedProfile?.copyICCData() as Data?) == (image.colorSpace?.copyICCData() as Data?))
        let details = try #require(outcome.details.first?.image)
        #expect(details.originalWidth == 400 && details.outputWidth == decoded.width)
        #expect(details.originalHeight == 300 && details.outputHeight == decoded.height)
        #expect(details.reducedDimensions == (decoded.width < 400 || decoded.height < 300))
        let outputBytes = try Data(contentsOf: output)
        let colorTypeOffset = 25
        let paletteOutput = outputBytes[colorTypeOffset] == 3
        #expect(details.quantized == paletteOutput)
        if translucent { #expect(!paletteOutput) }
        #expect(details.paletteColors == (paletteOutput ? 256 : nil))
        guard case .succeeded(_, let warnings) = try #require(outcome.outcomes.first) else {
            Issue.record("Expected PNG success")
            return
        }
        #expect(warnings.contains(.imagePaletteReduced(colors: 256)) == paletteOutput)
        #expect(warnings.contains(.imageDimensionsReduced) == details.reducedDimensions)
        let referenceContext = try #require(
            CGContext(
                data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: profile, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        referenceContext.interpolationQuality = .high
        referenceContext.draw(image, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        let reference = try PixelBuffer(cgImage: #require(referenceContext.makeImage()))
        let actual = try PixelBuffer(cgImage: decoded)
        var colorError = 0.0
        var alphaError = 0.0
        for pixel in 0..<actual.pixelCount {
            let base = pixel * 4
            let sourceAlpha = Double(reference.rgba[base + 3]) / 255
            let outputAlpha = Double(actual.rgba[base + 3]) / 255
            alphaError += abs(sourceAlpha - outputAlpha)
            for channel in 0..<3 {
                let source = Double(reference.rgba[base + channel]) / 255 * sourceAlpha + 1 - sourceAlpha
                let coded = Double(actual.rgba[base + channel]) / 255 * outputAlpha + 1 - outputAlpha
                colorError += abs(source - coded)
            }
        }
        #expect(colorError / Double(actual.pixelCount * 3) <= 0.05)
        #expect(alphaError / Double(actual.pixelCount) <= 0.02)
    }

    @Test func unsuitablePaletteFallsBackToExactRGBAWithItsProfile() throws {
        let width = 600
        let height = 400
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 42
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let base = (y * width + x) * 4
                let noise = Int(seed >> 60)
                rgba[base] = UInt8(clamping: x * 220 / width + noise)
                rgba[base + 1] = UInt8(clamping: y * 220 / height + noise)
                rgba[base + 2] = UInt8(clamping: (x + y) * 200 / (width + height) + noise * 2)
                rgba[base + 3] = UInt8(x * 255 / width)
            }
        }
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let original = PixelBuffer(width: width, height: height, rgba: rgba, colorSpace: profile)
        let image = try original.makeCGImage()
        var options = EncodeOptions(quality: ImageEncoder.maximumQuality)
        options.dithering = .none
        let candidate = try ImageEncoder.balancedPNG(
            [ImageFrame(image: image, duration: 0)], colors: 256, options: options, retaining: [])
        #expect(!candidate.usesPalette && !candidate.reducedColors)
        #expect(candidate.encoded[25] == 6)
        let source = try #require(CGImageSourceCreateWithData(candidate.encoded as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == width && decoded.height == height)
        #expect(try PixelBuffer(cgImage: decoded).rgba == original.rgba)
        #expect((decoded.colorSpace?.copyICCData() as Data?) == (profile.copyICCData() as Data?))
    }

    @Test func pngTargetFailuresKeepPixelsAndNeverLowerResolutionWithoutPermission() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 160, height: 120)], as: .png, to: folder.appending(path: "original.png"))
        let original = try Data(contentsOf: input)
        let roomy = try await Fixture.run(
            .imageCompress, compression(.bytes(10_000_000), downscale: false), inputs: [input])
        #expect(roomy.outcomes == [.skipped(.alreadyDone)])
        #expect(try Data(contentsOf: input) == original)
        let failure = try await Fixture.run(.imageCompress, compression(.bytes(1), downscale: false), inputs: [input])
        #expect(failure.outcomes == [.failed(.pngTargetNotReached)])
        #expect(failure.record == nil)
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(contents.map(\.lastPathComponent) == [input.lastPathComponent])
        #expect(try Data(contentsOf: input) == original)
        #expect(try Fixture.image(input).width == 160)
        #expect(try Fixture.image(input).height == 120)
    }

    @Test(arguments: [false, true])
    func paletteCandidatesKeepPriorityPixelsProfileAndMetadata(fewColors: Bool) async throws {
        let width = fewColors ? 2 : 192
        let height = fewColors ? 2 : 128
        let image = try Fixture.photo(width: width, height: height)
        let metadata = CGImageMetadataCreateMutable()
        #expect(
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment,
                "Concurrent palette metadata" as CFString))
        var options = EncodeOptions(quality: ImageEncoder.maximumQuality)
        options.metadata = metadata
        options.pngColors = 256
        options.maximumPNGBytes = 1_000_000
        let frames = [ImageFrame(image: image, duration: 0)]
        let sequential = try ImageEncoder.encode(frames, as: .png, options: options)
        let prepared = try #require(try ImageEncoder.preparePNGTargetPixels(frames, options: options, retaining: []))
        let candidate = try #require(
            await ImageEncoder.quantizedCandidates(
                frames, colors: [256, 128, 64], under: 1_000_000, options: options, preparedPixels: prepared))
        #expect(candidate.colors == 256)
        #expect(candidate.reducedColors == !fewColors)
        #expect(candidate.encoded.count <= 1_000_000)
        let decoder = try #require(CGImageSourceCreateWithData(candidate.encoded as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        let reference = try #require(CGImageSourceCreateWithData(sequential as CFData, nil))
        let expected = try #require(CGImageSourceCreateImageAtIndex(reference, 0, nil))
        #expect(decoded.width == width && decoded.height == height)
        #expect(try PixelBuffer(cgImage: decoded).rgba == PixelBuffer(cgImage: expected).rgba)
        #expect((decoded.colorSpace?.copyICCData() as Data?) == (expected.colorSpace?.copyICCData() as Data?))
        let sourceProfile = image.colorSpace?.baseColorSpace ?? image.colorSpace
        let decodedProfile = decoded.colorSpace?.baseColorSpace ?? decoded.colorSpace
        #expect((decodedProfile?.copyICCData() as Data?) == (sourceProfile?.copyICCData() as Data?))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(decoder, 0, nil) as? [CFString: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifUserComment] as? String == "Concurrent palette metadata")
    }

    @Test func cancellationStopsConcurrentPaletteCandidates() async throws {
        let image = try Fixture.photo(width: 1024, height: 768)
        let encoding = Task {
            try await ImageEncoder.quantizedCandidates(
                [ImageFrame(image: image, duration: 0)], colors: [256, 128, 64], under: 1_000_000,
                options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        }
        try await Task.sleep(for: .milliseconds(20))
        encoding.cancel()
        do {
            _ = try await encoding.value
            Issue.record("Cancelled palette encoding completed")
        } catch is CancellationError {}
    }

    @Test func pngTargetDownscaleRunsOnlyWhenAllowed() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 160, height: 120)], as: .png, to: folder.appending(path: "permission.png"))
        let original = try Data(contentsOf: input)
        let target: Int64 = 1_500
        let blocked = try await Fixture.run(
            .imageCompress, compression(.bytes(target), downscale: false), inputs: [input], outputMode: .newFile)
        #expect(blocked.outcomes == [.failed(.pngTargetNotReached)])
        #expect(try Data(contentsOf: input) == original)
        let allowed = try await Fixture.run(
            .imageCompress, compression(.bytes(target), downscale: true), inputs: [input], outputMode: .newFile)
        let output = try Fixture.output(of: allowed)
        let decoded = try Fixture.image(output)
        #expect(try Fixture.fileSize(output) <= target)
        #expect(decoded.width < 160 && decoded.height < 120)
        #expect(allowed.details.first?.image?.reducedDimensions == true)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func optimizedPNGConversionKeepsPixelsProfileAndDescriptiveMetadata() async throws {
        let folder = try TestVolume.makeFolder()
        let fields: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Preserved PNG comment"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        let input = try Fixture.write(
            [try Fixture.photo(width: 97, height: 63)], as: .tiff,
            to: folder.appending(path: "tagged.tiff"), frameProperties: fields)
        let original = try Fixture.image(input)
        let originalPixels = try PixelBuffer(cgImage: original)
        let outcome = try await Fixture.run(.imageConvert, preset: "png", inputs: [input])
        let output = try Fixture.output(of: outcome)
        let decoded = try Fixture.image(output)
        #expect(try PixelBuffer(cgImage: decoded).rgba == originalPixels.rgba)
        #expect((decoded.colorSpace?.copyICCData() as Data?) == (original.colorSpace?.copyICCData() as Data?))
        let properties = try Fixture.properties(output)
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifUserComment] as? String == "Preserved PNG comment")
        let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(gps[kCGImagePropertyGPSLatitude] as? Double == 35.0)
        #expect(outcome.details.first?.image?.quantized == false)
    }

    @Test func optimizedPNGConversionKeepsGrayscaleICCProfile() async throws {
        let folder = try TestVolume.makeFolder()
        let profile = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let provider = try #require(CGDataProvider(data: Data([32, 192]) as CFData))
        let gray = try #require(
            CGImage(
                width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2,
                space: profile, bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent))
        let input = try Fixture.write([gray], as: .tiff, to: folder.appending(path: "gray.tiff"))
        let original = try Fixture.image(input)
        let expectedPixels = try (0..<2).map { try Fixture.pixel(original, x: $0, y: 0) }
        let outcome = try await Fixture.run(.imageConvert, preset: "png", inputs: [input])
        let decoded = try Fixture.image(try Fixture.output(of: outcome))
        #expect(decoded.colorSpace?.model == .monochrome)
        #expect((decoded.colorSpace?.copyICCData() as Data?) == (original.colorSpace?.copyICCData() as Data?))
        #expect(decoded.bitsPerComponent == original.bitsPerComponent)
        for x in 0..<2 {
            let actual = try Fixture.pixel(decoded, x: x, y: 0)
            #expect(actual == expectedPixels[x])
        }
    }

    @Test func animatedGIFsShrinkUnderTheTarget() async throws {
        let folder = try TestVolume.makeFolder()
        let frames = try (0..<6).map { try Fixture.photo(width: 160, height: 120, seed: $0) }
        let delay: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
        let input = try Fixture.write(frames, as: .gif, to: folder.appending(path: "clip.gif"), frameProperties: delay)
        let target = try Fixture.fileSize(input) / 2
        let outcome = try await Fixture.run(.imageCompress, compression(.bytes(target)), inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(try Fixture.fileSize(output) <= target)
        #expect(CGImageSourceGetCount(try Fixture.source(output)) > 1)
    }

    @Test func instagramCropsToItsAspectAndWritesJPEG() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 1000, height: 1500)], as: .png, to: folder.appending(path: "tall.png"))
        let outcome = try await Fixture.run(.imageCompress, preset: "instagram", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(output.lastPathComponent == "tall.jpg")
        let image = try Fixture.image(output)
        #expect(image.width == 1000 && image.height == 1250)
        #expect(!FileManager.default.fileExists(atPath: input.path))
    }

    @Test func webPresetConvertsAndLimitsTheLongEdge() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 2400, height: 1200)], as: .jpeg, to: folder.appending(path: "wide.jpg"))
        let outcome = try await Fixture.run(.imageCompress, preset: "web", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(output.pathExtension == "webp")
        #expect(try Fixture.image(output).width == 1920)
    }

    @Test func qualityPresetsShrinkAndKeepTheFormat() async throws {
        let folder = try TestVolume.makeFolder()
        let jpeg = try Fixture.write(
            [try Fixture.photo()], as: .jpeg, to: folder.appending(path: "q.jpg"), quality: 0.98)
        let before = try Fixture.fileSize(jpeg)
        let low = try await Fixture.run(.imageCompress, preset: "quality-low", inputs: [jpeg])
        let output = try Fixture.output(of: low)
        #expect(output == jpeg)
        #expect(try Fixture.fileSize(output) < before)
        let again = try await Fixture.run(.imageCompress, preset: "quality-high", inputs: [output])
        #expect(again.outcomes == [.skipped(.outputNotSmaller)])

        let png = try Fixture.write([try Fixture.photo()], as: .png, to: folder.appending(path: "q.png"))
        let pngBefore = try Fixture.fileSize(png)
        let quantized = try await Fixture.run(.imageCompress, preset: "quality-medium", inputs: [png])
        #expect(try Fixture.fileSize(try Fixture.output(of: quantized)) < pngBefore / 2)
    }

    @Test func unreachableTargetsFailWithTheSmallestSizeAndKeepTheOriginal() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write([try Fixture.photo()], as: .jpeg, to: folder.appending(path: "big.jpg"))
        let original = try Data(contentsOf: input)
        let outcome = try await Fixture.run(.imageCompress, compression(.bytes(500), downscale: false), inputs: [input])
        guard case .failed(.targetUnreachable(let smallest)) = try #require(outcome.outcomes.first) else {
            Issue.record("expected targetUnreachable, got \(outcome.outcomes)")
            return
        }
        #expect(smallest > 500)
        #expect(try Data(contentsOf: input) == original)

        let roomy = try await Fixture.run(.imageCompress, compression(.bytes(100_000_000)), inputs: [input])
        #expect(roomy.outcomes == [.skipped(.alreadyDone)])
    }

    @Test func platformPresetsOnlyDropGPSFromFilesAlreadyUnderTheLimit() async throws {
        let folder = try TestVolume.makeFolder()
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ]
        let input = try Fixture.write(
            [try Fixture.photo(width: 1200, height: 900)], as: .jpeg, to: folder.appending(path: "trip.jpg"),
            frameProperties: gps, quality: 0.9)
        let pixels = try Fixture.rawBytes(input)
        let outcome = try await Fixture.run(.imageCompress, preset: "discord", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(try Fixture.properties(output)[kCGImagePropertyGPSDictionary] == nil)
        #expect(try Fixture.rawBytes(output) == pixels)

        let again = try await Fixture.run(.imageCompress, preset: "discord", inputs: [output])
        #expect(again.outcomes == [.skipped(.alreadyDone)])
    }

    @Test func instagramCropsSmallPortraitJPEGs() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 1080, height: 1920)], as: .jpeg, to: folder.appending(path: "story.jpg"))
        let outcome = try await Fixture.run(.imageCompress, preset: "instagram", inputs: [input])
        let image = try Fixture.image(try Fixture.output(of: outcome))
        #expect(image.width == 1080 && image.height == 1350)
    }
}
