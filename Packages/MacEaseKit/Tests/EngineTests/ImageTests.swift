import CoreGraphics
import Foundation
import ImageIO
import MenuCatalog
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import Engine

private typealias Fixture = ImageFixtures

private var exifProperties: [CFString: Any] {
    [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.0, kCGImagePropertyGPSLongitudeRef: "E",
        ],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["fixture"]],
    ]
}

private func animatedGIF(in folder: URL, frames: Int = 4) throws -> URL {
    let images = try (0..<frames).map { try Fixture.photo(width: 120, height: 90, seed: $0 + 1) }
    let gifFrame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
    return try Fixture.write(
        images, as: .gif, to: folder.appending(path: "anim.gif"),
        properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]], frameProperties: gifFrame)
}

@Suite struct ImagePlanningTests {
    private let operations: [OperationID] = [
        .imageResize, .imageCompress, .imageConvert, .imageRotate, .imageFlip, .imageBackground,
        .imageStripMetadata, .imageOCR, .imageIconSet,
    ]

    @Test func everyMenuPresetMapsAndCustomAsksForAPanel() {
        for op in operations {
            for preset in op.presets {
                #expect(ImagePlanner.operation(for: op, preset: preset, settings: Settings()) != nil, "\(op) \(preset)")
            }
            #expect(ImagePlanner.operation(for: op, preset: nil, settings: Settings()) == nil)
            #expect(ImagePlanner.operation(for: op, preset: "unknown", settings: Settings()) == nil)
        }
        for leaf in [OperationID.imageTrimBorders, .imageToPDF, .imageCopyBase64] {
            #expect(ImagePlanner.operation(for: leaf, preset: nil, settings: Settings()) != nil)
        }
        #expect(OperationPlanner.options(for: .imageConvert, preset: "webp", settings: Settings()) != nil)
    }

    @Test func platformPresetsCarryTheirLimitsAndGPSSetting() throws {
        var settings = Settings()
        settings.image.keepGPSOnPlatformPresets = true
        let operation = ImagePlanner.operation(for: .imageCompress, preset: "instagram", settings: settings)
        guard case .compress(let compression) = operation, case .platform(let preset) = compression.goal else {
            Issue.record("expected a platform compression")
            return
        }
        #expect(preset.image?.formats == ["jpeg"])
        #expect(!compression.stripsGPS)
    }

    @Test func orientationComposesWithRotation() {
        #expect(Orientation.rotating(1, clockwiseQuarterTurns: 1) == 6)
        #expect(Orientation.rotating(6, clockwiseQuarterTurns: 1) == 3)
        #expect(Orientation.rotating(1, clockwiseQuarterTurns: -1) == 8)
        #expect(Orientation.rotating(2, clockwiseQuarterTurns: 2) == 4)
        #expect(Orientation.rotating(5, clockwiseQuarterTurns: 1) == 2)
        #expect(Orientation.rotating(8, clockwiseQuarterTurns: 4) == 8)
    }

    @Test func formatsMapFromContentTypes() {
        #expect(ImageFormat(contentType: .jpeg) == .jpeg)
        #expect(ImageFormat(contentType: .heics) == .heic)
        #expect(ImageFormat(contentType: UTType("com.adobe.raw-image") ?? .rawImage) == nil)
        #expect(ImageFormat(contentType: UTType("com.canon.cr2-raw-image") ?? .rawImage) == nil)
    }
}

@Suite(.serialized) struct ImageEditTests {
    @Test func resizeHalvesKeepsNameMetadataAndTrashesOriginal() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo()], as: .jpeg, to: folder.appending(path: "photo.jpg"), properties: [:],
            frameProperties: exifProperties)

        let outcome = try await Fixture.run(.imageResize, preset: "percent-50", inputs: [input])

        let output = try Fixture.output(of: outcome)
        #expect(output == input)
        #expect(try Fixture.image(output).width == 320)
        let exif = try Fixture.properties(output)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifLensModel] as? String == "Test Lens")
        guard case .replaced(_, let trashed, _, _, _) = try #require(outcome.record?.items.first) else {
            Issue.record("expected a replace record")
            return
        }
        #expect(try Fixture.image(URL(fileURLWithPath: trashed)).width == 640)
    }

    @Test func resizeNeverUpscalesFromPresets() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write([try Fixture.disc()], as: .png, to: folder.appending(path: "small.png"))
        let outcome = try await Fixture.run(.imageResize, preset: "long-3840", inputs: [input])
        #expect(outcome.outcomes == [.skipped(.noUpscale)])
        let custom = try await Fixture.run(
            .imageResize, .resize(ImageResize(size: .exact(width: 300, height: 100), allowsUpscale: true)),
            inputs: [input])
        let image = try Fixture.image(try Fixture.output(of: custom))
        #expect(image.width == 300 && image.height == 100)
    }

    @Test func resizeKeepsEveryAnimationFrame() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try animatedGIF(in: folder)
        let outcome = try await Fixture.run(.imageResize, preset: "percent-50", inputs: [input])
        let output = try Fixture.output(of: outcome)
        let source = try Fixture.source(output)
        #expect(CGImageSourceGetCount(source) == 4)
        #expect(try Fixture.image(output).width == 60)
        let gif = try Fixture.properties(output, index: 2)[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(abs((gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0) - 0.2) < 0.011)
    }

    @Test func convertWritesEveryTargetFormat() async throws {
        let folder = try TestVolume.makeFolder()
        var formats = ImageFormat.allCases.filter { $0 != .png && ($0 != .tga || ImageFormat.supportsTGA) }
        if !Fixture.canEncodeHEIC { formats.removeAll { $0 == .heic } }
        for format in formats {
            let input = try Fixture.write(
                [try Fixture.disc()], as: .png, to: folder.appending(path: "logo-\(format).png"))
            let outcome = try await Fixture.run(.imageConvert, preset: format.rawValue, inputs: [input])
            let output = try Fixture.output(of: outcome)
            #expect(output.pathExtension == format.fileExtension, "\(format)")
            #expect(FileManager.default.fileExists(atPath: input.path) == (format == .pdf), "\(format)")
            switch format {
            case .svg: #expect(try String(contentsOf: output, encoding: .utf8).contains("<path"))
            case .pdf: #expect(PDFDocument(url: output)?.pageCount == 1)
            default: #expect(try Fixture.image(output).width > 0, "\(format)")
            }
        }
    }

    @Test func convertedOutputsAreUprightWithOrientationOne() async throws {
        let folder = try TestVolume.makeFolder()
        for format in [ImageFormat.webp, .avif, .jxl, .png] {
            let input = try Fixture.write(
                [try Fixture.photo(width: 80, height: 40)], as: .jpeg, to: folder.appending(path: "o-\(format).jpg"),
                frameProperties: exifProperties.merging([kCGImagePropertyOrientation: 6]) { first, _ in first })
            let outcome = try await Fixture.run(.imageConvert, preset: format.rawValue, inputs: [input])
            let output = try Fixture.output(of: outcome)
            #expect(try Fixture.properties(output)[kCGImagePropertyOrientation] as? Int ?? 1 == 1, "\(format)")
            let image = try Fixture.image(output)
            #expect(image.width == 40 && image.height == 80, "\(format)")
        }
    }

    @Test func newFileTransparencyFlattensOntoWhiteWithWarning() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.disc(background: nil)], as: .png, to: folder.appending(path: "clear.png"))
        let outcome = try await Fixture.run(.imageConvert, preset: "jpeg", inputs: [input], outputMode: .newFile)
        #expect(Fixture.warnings(of: outcome) == [.imageTransparencyFlattened])
        #expect(FileManager.default.fileExists(atPath: input.path))
        let corner = try Fixture.pixel(try Fixture.image(try Fixture.output(of: outcome)), x: 2, y: 2)
        #expect(corner[0] > 245 && corner[1] > 245 && corner[2] > 245)
    }

    @Test func convertRefusesAnimationLoss() async throws {
        let folder = try TestVolume.makeFolder()
        let webP = try await Fixture.run(.imageConvert, preset: "webp", inputs: [try animatedGIF(in: folder)])
        #expect(CGImageSourceGetCount(try Fixture.source(try Fixture.output(of: webP))) == 4)
        let png = try await Fixture.run(.imageConvert, preset: "png", inputs: [try animatedGIF(in: folder)])
        #expect(CGImageSourceGetCount(try Fixture.source(try Fixture.output(of: png))) == 4)
        let jpeg = try await Fixture.run(.imageConvert, preset: "jpeg", inputs: [try animatedGIF(in: folder)])
        #expect(jpeg.outcomes == [.failed(.imageSequenceUnsupported)])
    }

    @Test func multiPageTIFFConvertsEveryPageOrRefuses() async throws {
        let folder = try TestVolume.makeFolder()
        let pages = try (0..<3).map { try Fixture.photo(width: 100, height: 80, seed: $0) }
        let tiff = try Fixture.write(pages, as: .tiff, to: folder.appending(path: "scan.tiff"))
        let pdf = try await Fixture.run(.imageConvert, preset: "pdf", inputs: [tiff])
        #expect(PDFDocument(url: try Fixture.output(of: pdf))?.pageCount == 3)
        let other = try Fixture.write(pages, as: .tiff, to: folder.appending(path: "scan2.tiff"))
        let png = try await Fixture.run(.imageConvert, preset: "png", inputs: [other])
        #expect(png.outcomes == [.failed(.imageSequenceUnsupported)])
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func jpegQuarterTurnsOnlyEditTheOrientationTag() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 64, height: 48)], as: .jpeg, to: folder.appending(path: "turn.jpg"),
            frameProperties: [kCGImagePropertyOrientation: 6])
        let pixels = try Fixture.rawBytes(input)

        let outcome = try await Fixture.run(.imageRotate, preset: "right-90", inputs: [input])

        let output = try Fixture.output(of: outcome)
        #expect(try Fixture.properties(output)[kCGImagePropertyOrientation] as? Int == 3)
        #expect(try Fixture.rawBytes(output) == pixels)
    }

    @Test func pixelRotationFillsCornersByFormat() async throws {
        let folder = try TestVolume.makeFolder()
        let png = try Fixture.write(
            [try Fixture.photo(width: 100, height: 60)], as: .png, to: folder.appending(path: "a.png"))
        let rotated = try await Fixture.run(.imageRotate, preset: "right-90", inputs: [png])
        let quarter = try Fixture.image(try Fixture.output(of: rotated))
        #expect(quarter.width == 60 && quarter.height == 100)
        #expect(try Fixture.properties(png)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)

        let tilted = try await Fixture.run(.imageRotate, .rotate(degrees: 30, fill: nil), inputs: [png])
        let transparent = try Fixture.image(try Fixture.output(of: tilted))
        #expect(transparent.width > 100)
        #expect(try Fixture.pixel(transparent, x: 0, y: 0)[3] == 0)

        let jpeg = try Fixture.write(
            [try Fixture.photo(width: 100, height: 60)], as: .jpeg, to: folder.appending(path: "b.jpg"))
        let filled = try await Fixture.run(.imageRotate, .rotate(degrees: 30, fill: nil), inputs: [jpeg])
        let corner = try Fixture.pixel(try Fixture.image(try Fixture.output(of: filled)), x: 0, y: 0)
        #expect(corner[0] > 240 && corner[1] > 240 && corner[2] > 240)
    }

    @Test func flipMirrorsPixels() async throws {
        let folder = try TestVolume.makeFolder()
        let marked = try Fixture.canvas(width: 40, height: 20) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        }
        let input = try Fixture.write([marked], as: .png, to: folder.appending(path: "flip.png"))
        let outcome = try await Fixture.run(.imageFlip, preset: "horizontal", inputs: [input])
        let image = try Fixture.image(try Fixture.output(of: outcome))
        #expect(try Fixture.pixel(image, x: 39, y: 10)[2] == 255)
        #expect(try Fixture.pixel(image, x: 0, y: 10)[0] == 255)
    }

    @Test func trimRemovesUniformBordersOnly() async throws {
        let folder = try TestVolume.makeFolder()
        let bordered = try Fixture.write(
            [try Fixture.disc(size: 200)], as: .png, to: folder.appending(path: "border.png"))
        let outcome = try await Fixture.run(.imageTrimBorders, preset: nil, inputs: [bordered])
        let image = try Fixture.image(try Fixture.output(of: outcome))
        #expect(abs(image.width - 100) <= 2 && abs(image.height - 100) <= 2)
        let again = try await Fixture.run(.imageTrimBorders, preset: nil, inputs: [bordered])
        #expect(again.outcomes == [.skipped(.nothingToRemove)])
    }

    @Test func colorKeyRemovesTheBackgroundAndJPEGBecomesPNG() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.disc()], as: .jpeg, to: folder.appending(path: "key.jpg"), quality: 1)
        let outcome = try await Fixture.run(.imageBackground, preset: "color-key", inputs: [input])
        let output = try Fixture.output(of: outcome)
        #expect(output.lastPathComponent == "key.png")
        let image = try Fixture.image(output)
        #expect(try Fixture.pixel(image, x: 5, y: 5)[3] == 0)
        #expect(try Fixture.pixel(image, x: 100, y: 100)[3] == 255)
    }

    @Test func subjectMaskReplacesTheBackgroundColor() async throws {
        let folder = try TestVolume.makeFolder()
        let scene = try Fixture.disc(size: 400, background: CGColor(gray: 0.95, alpha: 1))
        let input = try Fixture.write([scene], as: .png, to: folder.appending(path: "scene.png"))
        let options = BackgroundOptions(mask: .subject, fill: .color(.chromaGreen))
        let outcome = try await Fixture.run(.imageBackground, .background(options), inputs: [input])
        let image = try Fixture.image(try Fixture.output(of: outcome))
        #expect(try Fixture.pixel(image, x: 5, y: 5) == [0x00, 0xB1, 0x40, 255])
        #expect(try Fixture.pixel(image, x: 200, y: 200)[0] > 200)
    }
}

@Suite(.serialized) struct ImageMetadataTests {
    @Test func stripAllFromJPEGKeepsCompressedPixels() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 64, height: 48)], as: .jpeg, to: folder.appending(path: "meta.jpg"),
            frameProperties: exifProperties.merging([kCGImagePropertyOrientation: 6]) { first, _ in first })
        let pixels = try Fixture.rawBytes(input)

        let outcome = try await Fixture.run(.imageStripMetadata, preset: "all", inputs: [input])

        let output = try Fixture.output(of: outcome)
        let properties = try Fixture.properties(output)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyIPTCDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(try Fixture.rawBytes(output) == pixels)
        let again = try await Fixture.run(.imageStripMetadata, preset: "all", inputs: [output])
        #expect(again.outcomes == [.skipped(.nothingToRemove)])
    }

    @Test func stripGPSKeepsOtherFields() async throws {
        let folder = try TestVolume.makeFolder()
        for type in [UTType.jpeg, .png] {
            let input = try Fixture.write(
                [try Fixture.photo(width: 64, height: 48)], as: type,
                to: folder.appending(path: "gps.\(type.preferredFilenameExtension ?? "img")"),
                frameProperties: exifProperties)
            let pixels = try Fixture.rawBytes(input)
            let outcome = try await Fixture.run(.imageStripMetadata, preset: "gps", inputs: [input])
            let output = try Fixture.output(of: outcome)
            let properties = try Fixture.properties(output)
            #expect(properties[kCGImagePropertyGPSDictionary] == nil, "\(type)")
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifLensModel] as? String == "Test Lens", "\(type)")
            #expect(try Fixture.rawBytes(output) == pixels, "\(type)")
        }
    }

    @Test(.enabled(if: ImageFixtures.canEncodeHEIC)) func stripRemovesGPSFromHEIC() async throws {
        let folder = try TestVolume.makeFolder()
        let input = try Fixture.write(
            [try Fixture.photo(width: 64, height: 48)], as: .heic, to: folder.appending(path: "gps.heic"),
            frameProperties: exifProperties)
        let outcome = try await Fixture.run(.imageStripMetadata, preset: "all", inputs: [input])
        let properties = try Fixture.properties(try Fixture.output(of: outcome))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyIPTCDictionary] == nil)
    }
}
