import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite struct ImageGainMapTests {
    private static let width = 16
    private static let height = 8
    private static let values: [UInt8] = [24, 88, 152, 216]

    private static func map(width: Int = width, height: Int = height, stride: Int? = nil) -> ImageGainMap {
        let rowBytes = stride ?? width
        var pixels = Data(repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * rowBytes + x] = values[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
            }
        }
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "urn:macease:test" as CFString, "gain" as CFString, nil)
        CGImageMetadataSetValueWithPath(metadata, nil, "gain:calibration" as CFString, "unchanged" as CFString)
        return ImageGainMap(
            type: kCGImageAuxiliaryDataTypeHDRGainMap,
            payload: [
                kCGImageAuxiliaryDataInfoData: pixels,
                kCGImageAuxiliaryDataInfoMetadata: metadata,
                kCGImageAuxiliaryDataInfoDataDescription: [
                    kCGImagePropertyWidth: width, kCGImagePropertyHeight: height,
                    kCGImagePropertyBytesPerRow: rowBytes,
                    kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8,
                ],
            ] as CFDictionary)
    }

    private static func expectCorners(_ map: ImageGainMap, width: Int, height: Int, corners: [UInt8]) throws {
        let contents = try #require(map.payload as? [CFString: Any])
        let description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        let pixels = try #require(contents[kCGImageAuxiliaryDataInfoData] as? Data)
        let stride = try #require(description[kCGImagePropertyBytesPerRow] as? Int)
        #expect(description[kCGImagePropertyWidth] as? Int == width)
        #expect(description[kCGImagePropertyHeight] as? Int == height)
        for (corner, expected) in corners.enumerated() {
            let x = (corner % 2 == 0 ? 1 : 3) * width / 4
            let y = (corner < 2 ? 1 : 3) * height / 4
            #expect(pixels[y * stride + x] == expected)
        }
    }

    @Test func mirroredMapKeepsCalibrationAndPaddedRows() throws {
        let original = Self.map(stride: Self.width + 4)
        let flipped = try original.applying(
            .orientation(CGSize(width: 64, height: 32), .upMirrored))
        try Self.expectCorners(flipped, width: 16, height: 8, corners: [88, 24, 216, 152])
        let before = try #require((original.payload as NSDictionary)[kCGImageAuxiliaryDataInfoMetadata])
        let after = try #require((flipped.payload as NSDictionary)[kCGImageAuxiliaryDataInfoMetadata])
        #expect(CFEqual(before as CFTypeRef, after as CFTypeRef))
    }

    @Test func quarterTurnSwapsMapAxes() throws {
        let rotated = try Self.map().applying(.orientation(CGSize(width: 64, height: 32), .right))
        try Self.expectCorners(rotated, width: 8, height: 16, corners: [152, 24, 216, 88])
    }

    @Test func resizingScalesMapResolution() throws {
        let resized = try Self.map().applying(
            GainMapGeometry(
                source: CGSize(width: 64, height: 32), output: CGSize(width: 32, height: 16),
                transform: CGAffineTransform(scaleX: 0.5, y: 0.5)))
        try Self.expectCorners(resized, width: 8, height: 4, corners: Self.values)
    }

    @Test func cropUsesBaseImageCoordinates() throws {
        let cropped = try Self.map().applying(
            GainMapGeometry(
                source: CGSize(width: 64, height: 32), output: CGSize(width: 32, height: 32),
                transform: CGAffineTransform(translationX: -32, y: 0)))
        try Self.expectCorners(cropped, width: 8, height: 8, corners: [88, 88, 216, 216])
    }

    @Test func paddingRefusesUnknownNeutralGain() {
        let geometry = GainMapGeometry(
            source: CGSize(width: 64, height: 32), output: CGSize(width: 64, height: 64),
            transform: CGAffineTransform(translationX: 0, y: 16))
        #expect(throws: EngineError.imageGainMapUnsupported) { try Self.map().applying(geometry) }
    }

    @Test func nonRightAngleRotationRefusesUndefinedCornerGain() throws {
        let source = try ImageFixtures.photo(width: 64, height: 32)
        let canvas = try ImageFixtures.photo(width: 68, height: 68)
        let geometry = GainMapGeometry.rotation(source, to: canvas, degrees: 45)
        #expect(throws: EngineError.imageGainMapUnsupported) { try Self.map().applying(geometry) }
    }

    @Test func malformedMapRefusesBeforeAllocation() throws {
        var payload = try #require(Self.map().payload as? [CFString: Any])
        payload[kCGImageAuxiliaryDataInfoDataDescription] = [
            kCGImagePropertyWidth: Int.max, kCGImagePropertyHeight: 8,
            kCGImagePropertyBytesPerRow: Int.max, kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8,
        ]
        let malformed = ImageGainMap(type: kCGImageAuxiliaryDataTypeHDRGainMap, payload: payload as CFDictionary)
        #expect(throws: EngineError.imageGainMapUnsupported) {
            try malformed.applying(.orientation(CGSize(width: 64, height: 32), .upMirrored))
        }
    }

    @Test func explicitAuxiliaryOrientationOverridesBase() throws {
        var payload = try #require(Self.map().payload as? [CFString: Any])
        var description = try #require(payload[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        description[kCGImagePropertyOrientation] = UInt32(5)
        payload[kCGImageAuxiliaryDataInfoDataDescription] = description
        let oriented = try ImageGainMap(
            type: kCGImageAuxiliaryDataTypeHDRGainMap,
            payload: payload as CFDictionary
        ).oriented(.upMirrored)
        try Self.expectCorners(oriented, width: 8, height: 16, corners: [24, 152, 88, 216])
        let orientedDescription = try #require(
            (oriented.payload as NSDictionary)[
                kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        #expect(orientedDescription[kCGImagePropertyOrientation] as? UInt32 == 1)
    }

    @Test func invalidAuxiliaryOrientationRefuses() throws {
        var payload = try #require(Self.map().payload as? [CFString: Any])
        var description = try #require(payload[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        description[kCGImagePropertyOrientation] = UInt32(9)
        payload[kCGImageAuxiliaryDataInfoDataDescription] = description
        let malformed = ImageGainMap(type: kCGImageAuxiliaryDataTypeHDRGainMap, payload: payload as CFDictionary)
        #expect(throws: EngineError.imageGainMapUnsupported) { try malformed.oriented(.up) }
    }

    @Test func explicitUprightOrientationClearsStaleMetadataOrientation() throws {
        var contents = try #require(Self.map().payload as? [CFString: Any])
        var description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        description[kCGImagePropertyOrientation] = UInt32(1)
        contents[kCGImageAuxiliaryDataInfoDataDescription] = description
        let value = try #require(contents[kCGImageAuxiliaryDataInfoMetadata])
        guard case let metadata as CGImageMetadata = value else { throw EngineError.imageGainMapUnsupported }
        let changed = try #require(CGImageMetadataCreateMutableCopy(metadata))
        CGImageMetadataRegisterNamespaceForPrefix(
            changed, "http://ns.adobe.com/tiff/1.0/" as CFString, "tiff" as CFString, nil)
        #expect(CGImageMetadataSetValueWithPath(changed, nil, "tiff:Orientation" as CFString, "6" as CFString))
        contents[kCGImageAuxiliaryDataInfoMetadata] = changed
        let originalPixels = try #require(contents[kCGImageAuxiliaryDataInfoData] as? Data)
        let oriented = try ImageGainMap(
            type: kCGImageAuxiliaryDataTypeHDRGainMap, payload: contents as CFDictionary
        ).oriented(.upMirrored)
        try Self.expectCorners(oriented, width: 16, height: 8, corners: Self.values)
        let result = try #require(oriented.payload as? [CFString: Any])
        let resultDescription = try #require(result[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        #expect(resultDescription[kCGImagePropertyOrientation] as? UInt32 == 1)
        #expect(result[kCGImageAuxiliaryDataInfoData] as? Data == originalPixels)
        let resultValue = try #require(result[kCGImageAuxiliaryDataInfoMetadata])
        guard case let resultMetadata as CGImageMetadata = resultValue else {
            throw EngineError.imageGainMapUnsupported
        }
        #expect(
            CGImageMetadataCopyStringValueWithPath(
                resultMetadata, nil,
                "tiff:Orientation" as CFString) as String? == "1")
    }
}

private enum GainMapVariant: CaseIterable {
    case apple, isoMono, isoRGB

    var type: CFString {
        self == .apple ? kCGImageAuxiliaryDataTypeHDRGainMap : kCGImageAuxiliaryDataTypeISOGainMap
    }
}

private enum GainMapFixture: CaseIterable {
    case appleJPEG, appleHEIC, isoMonoJPEG, isoMonoHEIC, isoRGBJPEG, isoRGBHEIC

    var variant: GainMapVariant {
        switch self {
        case .appleJPEG, .appleHEIC: .apple
        case .isoMonoJPEG, .isoMonoHEIC: .isoMono
        case .isoRGBJPEG, .isoRGBHEIC: .isoRGB
        }
    }

    var heic: Bool {
        switch self {
        case .appleHEIC, .isoMonoHEIC, .isoRGBHEIC: true
        default: false
        }
    }
}

private enum LegacyGainMapEdit: CaseIterable {
    case horizontal, vertical, quarterTurn, resize
}

private enum GainMapEdit: CaseIterable {
    case horizontal, vertical, rotate90, rotate180, rotate270, resize, crop, compress, convert

    var outputSize: (Int, Int) {
        switch self {
        case .rotate90, .rotate270: (128, 256)
        case .resize: (128, 64)
        case .crop: (128, 128)
        default: (256, 128)
        }
    }

    func sourcePoint(_ x: Double, _ y: Double) -> (Double, Double) {
        switch self {
        case .horizontal: (1 - x, y)
        case .vertical: (x, 1 - y)
        case .rotate90: (y, 1 - x)
        case .rotate180: (1 - x, 1 - y)
        case .rotate270: (1 - y, x)
        case .crop: (0.25 + 0.5 * x, y)
        default: (x, y)
        }
    }
}

private enum GainMapExif: UInt32, CaseIterable {
    case horizontal = 2
    case upsideDown = 3
    case vertical = 4
    case transpose = 5
    case right = 6
    case transverse = 7
    case left = 8

    var swapsAxes: Bool { [Self.transpose, .right, .transverse, .left].contains(self) }

    func sourcePoint(_ x: Double, _ y: Double) -> (Double, Double) {
        switch self {
        case .horizontal: (1 - x, y)
        case .upsideDown: (1 - x, 1 - y)
        case .vertical: (x, 1 - y)
        case .transpose: (y, x)
        case .right: (y, 1 - x)
        case .transverse: (1 - y, 1 - x)
        case .left: (1 - y, x)
        }
    }
}

@Suite(.serialized) struct ImageGainMapIntegrationTests {
    private static let width = 256
    private static let height = 128
    private static let tolerance = 12

    private static func originalJPEGFixture(_ url: URL) throws {
        let base = CIImage(cgImage: try ImageFixtures.photo(width: width, height: height))
        let boosted = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2])
        let hdr = boosted.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128)).composited(over: base)
        let encoded = try #require(
            CIContext().jpegRepresentation(of: base, colorSpace: ImageFixtures.sRGB, options: [.hdrImage: hdr]))
        try encoded.write(to: url)
    }

    private static func originalSample(_ payload: CFDictionary, x: Double, y: Double) throws -> Int {
        let contents = try #require(payload as? [CFString: Any])
        let description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        let pixels = try #require(contents[kCGImageAuxiliaryDataInfoData] as? Data)
        let width = try #require(description[kCGImagePropertyWidth] as? Int)
        let height = try #require(description[kCGImagePropertyHeight] as? Int)
        let stride = try #require(description[kCGImagePropertyBytesPerRow] as? Int)
        #expect(description[kCGImagePropertyPixelFormat] as? OSType == kCVPixelFormatType_OneComponent8)
        return Int(pixels[Int(y * Double(height)) * stride + Int(x * Double(width))])
    }

    @Test(arguments: LegacyGainMapEdit.allCases)
    private func jpegEditsKeepGainMapGeometry(_ edit: LegacyGainMapEdit) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.jpg")
        try Self.originalJPEGFixture(input)
        let original = try Data(contentsOf: input)
        let source = try ImageFixtures.source(input)
        let gainMaps = try ImageGainMap.read(source, at: 0)
        let originalMap = try #require(gainMaps.first)
        let description = try #require(
            (originalMap.payload as NSDictionary)[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        var width = try #require(description[kCGImagePropertyWidth] as? Int)
        var height = try #require(description[kCGImagePropertyHeight] as? Int)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result: ItemResult
        switch edit {
        case .horizontal: result = try await ImageEdits.flip(input, .horizontal, context: context)
        case .vertical: result = try await ImageEdits.flip(input, .vertical, context: context)
        case .quarterTurn:
            result = try await ImageEdits.rotate(input, degrees: 90, fill: nil, context: context)
            swap(&width, &height)
        case .resize:
            result = try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
            width /= 2
            height /= 2
        }
        guard case .replace(_, let output) = result else {
            Issue.record("expected staged HDR replacement")
            return
        }
        let written = try ImageFixtures.source(output.url)
        let actual = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, originalMap.type))
        let dimensions = try #require(
            (actual as NSDictionary)[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        #expect(dimensions[kCGImagePropertyWidth] as? Int == width)
        #expect(dimensions[kCGImagePropertyHeight] as? Int == height)
        let tolerance = 12
        for x in [0.25, 0.75] {
            for y in [0.25, 0.75] {
                let sourcePoint: (Double, Double)
                switch edit {
                case .horizontal: sourcePoint = (1 - x, y)
                case .vertical: sourcePoint = (x, 1 - y)
                case .quarterTurn: sourcePoint = (y, 1 - x)
                case .resize: sourcePoint = (x, y)
                }
                let expected = try Self.originalSample(originalMap.payload, x: sourcePoint.0, y: sourcePoint.1)
                #expect(abs(try Self.originalSample(actual, x: x, y: y) - expected) <= tolerance)
            }
        }
        #expect(try Data(contentsOf: input) == original)
    }

    private static func tiles(_ colors: [CIColor]) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let quadrants = [
            CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2),
            CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2),
            CGRect(x: 0, y: 0, width: width / 2, height: height / 2),
            CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2),
        ]
        return zip(colors, quadrants).reduce(CIImage(color: .black).cropped(to: canvas)) { image, tile in
            CIImage(color: tile.0).cropped(to: tile.1).composited(over: image)
        }
    }

    private static func fixture(_ url: URL, variant: GainMapVariant, heic: Bool) throws {
        let base = CIImage(cgImage: try ImageFixtures.photo(width: width, height: height))
        let gray: [CGFloat] = [0.35, 0.55, 0.75, 0.95]
        let map = tiles(gray.map { CIColor(red: $0, green: $0, blue: $0) })
        let hdr = tiles([
            CIColor(red: 0.6, green: 0.4, blue: 0.5),
            CIColor(red: 1.8, green: 0.5, blue: 0.7),
            CIColor(red: 0.7, green: 1.6, blue: 0.9),
            CIColor(red: 1.1, green: 0.8, blue: 2.0),
        ]).settingContentHeadroom(4)
        let options: [CIImageRepresentationOption: Any]
        switch variant {
        case .apple:
            options = [.hdrGainMapImage: map.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))]
        case .isoMono: options = [.hdrImage: hdr]
        case .isoRGB: options = [.hdrImage: hdr, .hdrGainMapAsRGB: true]
        }
        let context = CIContext()
        let encoded = try #require(
            heic
                ? context.heifRepresentation(of: base, format: .RGBA8, colorSpace: ImageFixtures.sRGB, options: options)
                : context.jpegRepresentation(of: base, colorSpace: ImageFixtures.sRGB, options: options))
        try encoded.write(to: url)
        let source = try ImageFixtures.source(url)
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, variant.type) != nil)
    }

    private static func dimensions(_ payload: CFDictionary) throws -> (Int, Int) {
        let contents = try #require(payload as? [CFString: Any])
        let description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        return (
            try #require(description[kCGImagePropertyWidth] as? Int),
            try #require(description[kCGImagePropertyHeight] as? Int)
        )
    }

    private struct AuxiliaryRaster {
        let pixels: Data
        let width: Int
        let height: Int
        let stride: Int
        let channels: Int

        init(_ source: CGImageSource, type: CFString) throws {
            let payload = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type))
            let contents = try #require(payload as? [CFString: Any])
            let description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
            (width, height) = try ImageGainMapIntegrationTests.dimensions(payload)
            if let data = contents[kCGImageAuxiliaryDataInfoData] as? Data {
                let format = try #require(description[kCGImagePropertyPixelFormat] as? OSType)
                channels = format == kCVPixelFormatType_OneComponent8 ? 1 : 3
                stride = try #require(description[kCGImagePropertyBytesPerRow] as? Int)
                pixels = data
            } else {
                let auxiliary = CIImage(
                    cgImageSource: source, index: 0,
                    options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: false, .colorSpace: NSNull()])
                let image = try #require(
                    CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(
                        auxiliary, from: CGRect(x: 0, y: 0, width: width, height: height),
                        format: .RGBA8, colorSpace: nil))
                pixels = try #require(image.dataProvider?.data as Data?)
                stride = image.bytesPerRow
                channels = 4
            }
            #expect(pixels.count >= stride * height)
            guard pixels.count >= stride * height else { throw EngineError.imageGainMapUnsupported }
        }

        func sample(_ column: Int, _ row: Int) -> [Int] {
            let offset = row * stride + column * channels
            return (0..<(channels == 1 ? 1 : 3)).map { Int(pixels[offset + $0]) }
        }

        func atFraction(_ x: Double, _ y: Double) -> [Int] {
            sample(min(width - 1, Int(x * Double(width))), min(height - 1, Int(y * Double(height))))
        }

        func interpolated(_ x: Double, _ y: Double) -> [Int] {
            let column = min(max(x * Double(width) - 0.5, 0), Double(width - 1))
            let row = min(max(y * Double(height) - 0.5, 0), Double(height - 1))
            let left = Int(column)
            let top = Int(row)
            let right = min(left + 1, width - 1)
            let bottom = min(top + 1, height - 1)
            let upperLeft = sample(left, top)
            let upperRight = sample(right, top)
            let lowerLeft = sample(left, bottom)
            let lowerRight = sample(right, bottom)
            let horizontal = column - Double(left)
            let vertical = row - Double(top)
            return upperLeft.indices.map { channel in
                let upper = Double(upperLeft[channel]) * (1 - horizontal) + Double(upperRight[channel]) * horizontal
                let lower = Double(lowerLeft[channel]) * (1 - horizontal) + Double(lowerRight[channel]) * horizontal
                return Int((upper * (1 - vertical) + lower * vertical).rounded())
            }
        }
    }

    private static func calibration(_ payload: CFDictionary) throws -> Data {
        let contents = try #require(payload as? [CFString: Any])
        let value = try #require(contents[kCGImageAuxiliaryDataInfoMetadata])
        #expect(CFGetTypeID(value as CFTypeRef) == CGImageMetadataGetTypeID())
        guard case let metadata as CGImageMetadata = value else { throw EngineError.imageGainMapUnsupported }
        return try #require(CGImageMetadataCreateXMPData(metadata, nil) as Data?)
    }

    private static func squarePreset() -> PlatformPreset {
        var limits = MediaLimits()
        limits.aspect = AspectRange(
            min: AspectRatio(width: 1, height: 1), max: AspectRatio(width: 1, height: 1), fit: .crop)
        limits.quality = 5
        return PlatformPreset(
            id: "square-hdr", name: LocalizedName(en: "Square", ja: "Square"),
            image: limits, gif: nil, video: nil, audio: nil)
    }

    private static func orientedFixture(
        _ input: URL, from original: URL, orientation: GainMapExif,
        type: CFString
    ) throws {
        let source = try ImageFixtures.source(original)
        let auxiliary = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type))
        var contents = try #require(auxiliary as? [CFString: Any])
        if contents[kCGImageAuxiliaryDataInfoData] == nil {
            var description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
            let width = try #require(description[kCGImagePropertyWidth] as? Int)
            let height = try #require(description[kCGImagePropertyHeight] as? Int)
            let image = CIImage(
                cgImageSource: source, index: 0,
                options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: false, .colorSpace: NSNull()])
            let rendered = try #require(
                CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(
                    image, from: CGRect(x: 0, y: 0, width: width, height: height),
                    format: .RGBA8, colorSpace: nil))
            let rgba = try #require(rendered.dataProvider?.data as Data?)
            var rgb = Data(count: width * height * 3)
            for row in 0..<height {
                for column in 0..<width {
                    let sourceOffset = row * rendered.bytesPerRow + column * 4
                    let targetOffset = (row * width + column) * 3
                    for channel in 0..<3 { rgb[targetOffset + channel] = rgba[sourceOffset + channel] }
                }
            }
            description[kCGImagePropertyPixelFormat] = kCVPixelFormatType_24RGB
            description[kCGImagePropertyBytesPerRow] = width * 3
            contents[kCGImageAuxiliaryDataInfoDataDescription] = description
            contents[kCGImageAuxiliaryDataInfoData] = rgb
        }
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                input as CFURL, (input.pathExtension == "heic" ? UTType.heic : UTType.jpeg).identifier as CFString,
                1, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        CGImageDestinationAddImage(
            destination, image,
            [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, type, contents as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try ImageFixtures.properties(input)[kCGImagePropertyOrientation] as? UInt32 == orientation.rawValue)
    }

    @Test(arguments: GainMapFixture.allCases, GainMapEdit.allCases)
    private func editsPreserveGainMap(fixture: GainMapFixture, edit: GainMapEdit) async throws {
        let variant = fixture.variant
        let heic = fixture.heic
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: heic ? "hdr.heic" : "hdr.jpg")
        try Self.fixture(input, variant: variant, heic: heic)
        let original = try Data(contentsOf: input)
        let source = try ImageFixtures.source(input)
        let originalMap = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, variant.type))
        let (sourceWidth, sourceHeight) = try Self.dimensions(originalMap)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result: ItemResult
        switch edit {
        case .horizontal: result = try await ImageEdits.flip(input, .horizontal, context: context)
        case .vertical: result = try await ImageEdits.flip(input, .vertical, context: context)
        case .rotate90: result = try await ImageEdits.rotate(input, degrees: 90, fill: nil, context: context)
        case .rotate180: result = try await ImageEdits.rotate(input, degrees: 180, fill: nil, context: context)
        case .rotate270: result = try await ImageEdits.rotate(input, degrees: 270, fill: nil, context: context)
        case .resize: result = try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
        case .crop:
            result = try await ImageCompressor.compress(
                input,
                ImageCompression(
                    goal: .platform(Self.squarePreset()), allowsDownscale: false,
                    allowsFrameRateReduction: false, stripsGPS: false), context: context)
        case .compress:
            result = try await ImageCompressor.compress(
                input,
                ImageCompression(
                    goal: .quality(5), allowsDownscale: false,
                    allowsFrameRateReduction: false, stripsGPS: false), context: context)
        case .convert:
            result = try await ImageEdits.convert(
                input,
                ImageConversion(format: heic ? .jpeg : .heic), context: context)
        }
        guard case .replace(let replaced, let output) = result else {
            Issue.record("expected staged HDR replacement")
            return
        }
        #expect(replaced == input)
        #expect(try Data(contentsOf: input) == original)
        let written = try ImageFixtures.source(output.url)
        let actual = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, variant.type))
        let (width, height) = try Self.dimensions(actual)
        let (expectedWidth, expectedHeight) = edit.outputSize
        #expect(width == sourceWidth * expectedWidth / Self.width)
        #expect(height == sourceHeight * expectedHeight / Self.height)
        #expect(try Self.calibration(originalMap) == Self.calibration(actual))
        #expect(try ImageFixtures.properties(output.url)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        let originalRaster = try Self.AuxiliaryRaster(source, type: variant.type)
        let writtenRaster = try Self.AuxiliaryRaster(written, type: variant.type)
        for x in [0.25, 0.75] {
            for y in [0.25, 0.75] {
                let centerX = (Double(Int(x * Double(width))) + 0.5) / Double(width)
                let centerY = (Double(Int(y * Double(height))) + 0.5) / Double(height)
                let (sourceX, sourceY) = edit.sourcePoint(centerX, centerY)
                let expected = originalRaster.interpolated(sourceX, sourceY)
                let observed = writtenRaster.atFraction(x, y)
                #expect(expected.count == observed.count)
                for channel in zip(expected, observed) {
                    #expect(abs(channel.0 - channel.1) <= Self.tolerance)
                }
            }
        }
    }

    @Test(arguments: GainMapFixture.allCases, GainMapExif.allCases)
    private func exifOrientationTransformsMap(
        fixture: GainMapFixture,
        orientation: GainMapExif
    ) async throws {
        let variant = fixture.variant
        let heic = fixture.heic
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let suffix = heic ? "heic" : "jpg"
        let seed = folder.appending(path: "seed.\(suffix)")
        let input = folder.appending(path: "oriented.\(suffix)")
        try Self.fixture(seed, variant: variant, heic: heic)
        try Self.orientedFixture(input, from: seed, orientation: orientation, type: variant.type)
        let original = try Data(contentsOf: input)
        let source = try ImageFixtures.source(input)
        let sourceMap = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, variant.type))
        let (sourceWidth, sourceHeight) = try Self.dimensions(sourceMap)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await ImageEdits.resize(input, ImageResize(size: .percent(50)), context: context)
        guard case .replace(_, let output) = result else {
            Issue.record("expected oriented HDR replacement")
            return
        }
        #expect(try Data(contentsOf: input) == original)
        let written = try ImageFixtures.source(output.url)
        let actual = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, variant.type))
        let (width, height) = try Self.dimensions(actual)
        #expect(width == (orientation.swapsAxes ? sourceHeight : sourceWidth) / 2)
        #expect(height == (orientation.swapsAxes ? sourceWidth : sourceHeight) / 2)
        #expect(try Self.calibration(sourceMap) == Self.calibration(actual))
        #expect(try ImageFixtures.properties(output.url)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        let originalRaster = try Self.AuxiliaryRaster(source, type: variant.type)
        let writtenRaster = try Self.AuxiliaryRaster(written, type: variant.type)
        for x in [0.25, 0.75] {
            for y in [0.25, 0.75] {
                let centerX = (Double(Int(x * Double(width))) + 0.5) / Double(width)
                let centerY = (Double(Int(y * Double(height))) + 0.5) / Double(height)
                let (sourceX, sourceY) = orientation.sourcePoint(centerX, centerY)
                let expected = originalRaster.interpolated(sourceX, sourceY)
                let observed = writtenRaster.atFraction(x, y)
                #expect(expected.count == observed.count)
                for channel in zip(expected, observed) {
                    #expect(abs(channel.0 - channel.1) <= Self.tolerance)
                }
            }
        }
    }

    @Test func verificationRefusesMissingCalibrationAndChangedPixels() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.jpg")
        try Self.fixture(input, variant: .isoMono, heic: false)
        let source = try ImageFixtures.source(input)
        let map = try #require(ImageGainMap.read(source, at: 0).first)
        var contents = try #require(map.payload as? [CFString: Any])
        contents.removeValue(forKey: kCGImageAuxiliaryDataInfoMetadata)
        #expect(throws: EngineError.imageGainMapUnsupported) {
            try ImageGainMap.verify([ImageGainMap(type: map.type, payload: contents as CFDictionary)], in: source)
        }
        contents = try #require(map.payload as? [CFString: Any])
        let pixels = try #require(contents[kCGImageAuxiliaryDataInfoData] as? Data)
        contents[kCGImageAuxiliaryDataInfoData] = Data(repeating: 255, count: pixels.count)
        #expect(throws: EngineError.imageGainMapUnsupported) {
            try ImageGainMap.verify([ImageGainMap(type: map.type, payload: contents as CFDictionary)], in: source)
        }
    }

    @Test func verificationRefusesNestedISOGammaChange() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "hdr.heic")
        try Self.fixture(input, variant: .isoMono, heic: true)
        let source = try ImageFixtures.source(input)
        let map = try #require(ImageGainMap.read(source, at: 0).first)
        var contents = try #require(map.payload as? [CFString: Any])
        let xmp = try #require(String(data: Self.calibration(map.payload), encoding: .utf8))
        let originalGamma = "<HDRToneMap:Gamma>1.000000</HDRToneMap:Gamma>"
        let changedGamma = "<HDRToneMap:Gamma>9.000000</HDRToneMap:Gamma>"
        #expect(xmp.contains(originalGamma))
        guard xmp.contains(originalGamma) else { throw EngineError.imageGainMapUnsupported }
        let changedData = Data(xmp.replacingOccurrences(of: originalGamma, with: changedGamma).utf8)
        let changed = try #require(CGImageMetadataCreateFromXMPData(changedData as CFData))
        contents[kCGImageAuxiliaryDataInfoMetadata] = changed
        #expect(throws: EngineError.imageGainMapUnsupported) {
            try ImageGainMap.verify([ImageGainMap(type: map.type, payload: contents as CFDictionary)], in: source)
        }
    }

    @Test func verificationRefusesChangedRGBChannel() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "rgb.jpg")
        try Self.fixture(input, variant: .isoRGB, heic: false)
        let source = try ImageFixtures.source(input)
        let map = try #require(ImageGainMap.read(source, at: 0).first)
        var contents = try #require(map.payload as? [CFString: Any])
        let description = try #require(contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        #expect(description[kCGImagePropertyPixelFormat] as? OSType == kCVPixelFormatType_24RGB)
        var pixels = try #require(contents[kCGImageAuxiliaryDataInfoData] as? Data)
        let (width, height) = try Self.dimensions(map.payload)
        let rowBytes = try #require(description[kCGImagePropertyBytesPerRow] as? Int)
        let changesSample = [0.25, 0.5, 0.75].contains { fraction in
            pixels[Int(fraction * Double(height)) * rowBytes + Int(fraction * Double(width)) * 3] > 32
        }
        try #require(changesSample)
        for offset in stride(from: 0, to: pixels.count, by: 3) { pixels[offset] = 0 }
        contents[kCGImageAuxiliaryDataInfoData] = pixels
        #expect(throws: EngineError.imageGainMapUnsupported) {
            try ImageGainMap.verify([ImageGainMap(type: map.type, payload: contents as CFDictionary)], in: source)
        }
    }
}
