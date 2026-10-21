import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

struct ImageGainMap {
    let type: CFString
    let payload: CFDictionary

    private static let coordinateTolerance = 1e-8
    private static let maximumRasterBytes = 64 * 1_024 * 1_024

    static func read(_ source: CGImageSource, at index: Int) throws -> [Self] {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let contents = properties?[kCGImagePropertyFileContentsDictionary] as? [CFString: Any]
        let images = contents?[kCGImagePropertyImages] as? [[CFString: Any]]
        let auxiliary = images?.flatMap { $0[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]] ?? [] } ?? []
        return try [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].compactMap { type in
            if let payload = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) {
                return try Self(type: type, payload: rasterPayload(payload, source: source, index: index, type: type))
            }
            guard !auxiliary.contains(where: { $0[kCGImagePropertyAuxiliaryDataType] as? String == type as String })
            else {
                throw EngineError.imageGainMapUnsupported
            }
            return nil
        }
    }

    private static func rasterPayload(_ payload: CFDictionary, source: CGImageSource, index: Int, type: CFString)
        throws -> CFDictionary
    {
        guard var contents = payload as? [CFString: Any],
            var description = contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
            let pixelFormat = description[kCGImagePropertyPixelFormat] as? OSType
        else { throw EngineError.imageGainMapUnsupported }
        let planarFormats = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        ]
        guard planarFormats.contains(pixelFormat) else { return payload }
        let rgbaChannels = 4
        let rgbChannels = 3
        guard type == kCGImageAuxiliaryDataTypeISOGainMap,
            let width = description[kCGImagePropertyWidth] as? Int,
            let height = description[kCGImagePropertyHeight] as? Int,
            width > 0, height > 0, width <= maximumRasterBytes / rgbaChannels,
            height <= maximumRasterBytes / (width * rgbaChannels)
        else { throw EngineError.imageGainMapUnsupported }
        let auxiliary = CIImage(
            cgImageSource: source, index: index,
            options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: false, .colorSpace: NSNull()])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard auxiliary.extent == bounds,
            let rendered = context.createCGImage(auxiliary, from: bounds, format: .RGBA8, colorSpace: nil),
            let rgba = rendered.dataProvider?.data as Data?,
            rendered.bitsPerPixel == rgbaChannels * 8, rendered.bytesPerRow >= width * rgbaChannels,
            rgba.count >= rendered.bytesPerRow * height
        else { throw EngineError.imageGainMapUnsupported }
        var pixels = Data(count: width * height * rgbChannels)
        for row in 0..<height {
            try Task.checkCancellation()
            for column in 0..<width {
                let sourceOffset = row * rendered.bytesPerRow + column * rgbaChannels
                let targetOffset = (row * width + column) * rgbChannels
                for channel in 0..<rgbChannels { pixels[targetOffset + channel] = rgba[sourceOffset + channel] }
            }
        }
        description[kCGImagePropertyPixelFormat] = kCVPixelFormatType_24RGB
        description[kCGImagePropertyBytesPerRow] = width * rgbChannels
        contents[kCGImageAuxiliaryDataInfoDataDescription] = description
        contents[kCGImageAuxiliaryDataInfoData] = pixels
        return contents as CFDictionary
    }

    func oriented(_ inherited: CGImagePropertyOrientation) throws -> Self {
        let raster = try Raster(payload)
        let contents = payload as NSDictionary
        let description = contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
        let calibration = try Self.metadata(payload)
        let metadataOrientation = calibration.flatMap {
            CGImageMetadataCopyStringValueWithPath($0, nil, "tiff:Orientation" as CFString) as String?
        }
        let rawOrientation: UInt32
        if let value = description?[kCGImagePropertyOrientation] {
            guard let raw = value as? UInt32 else { throw EngineError.imageGainMapUnsupported }
            rawOrientation = raw
        } else if let metadataOrientation {
            guard let raw = UInt32(metadataOrientation) else { throw EngineError.imageGainMapUnsupported }
            rawOrientation = raw
        } else {
            rawOrientation = inherited.rawValue
        }
        guard let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) else {
            throw EngineError.imageGainMapUnsupported
        }
        guard orientation != .up else { return try upright() }
        return try applying(.orientation(CGSize(width: raster.width, height: raster.height), orientation))
    }

    func applying(_ geometry: GainMapGeometry) throws -> Self {
        guard var contents = payload as? [CFString: Any],
            var description = contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
        else { throw EngineError.imageGainMapUnsupported }
        let raster = try Raster(payload)
        let (pixels, width, height, stride, channels) =
            (raster.pixels, raster.width, raster.height, raster.stride, raster.channels)
        let density = CGSize(
            width: Double(geometry.swapsAxes ? height : width)
                / (geometry.swapsAxes ? geometry.source.height : geometry.source.width),
            height: Double(geometry.swapsAxes ? width : height)
                / (geometry.swapsAxes ? geometry.source.width : geometry.source.height))
        guard let roundedWidth = Int(exactly: (geometry.output.width * density.width).rounded()),
            let roundedHeight = Int(exactly: (geometry.output.height * density.height).rounded())
        else { throw EngineError.imageGainMapUnsupported }
        let outputWidth = max(1, roundedWidth)
        let outputHeight = max(1, roundedHeight)
        guard outputWidth <= Self.maximumRasterBytes / channels,
            outputHeight <= Self.maximumRasterBytes / (outputWidth * channels)
        else { throw EngineError.imageGainMapUnsupported }
        let inverse = geometry.transform.inverted()
        let corners = [
            CGPoint.zero, CGPoint(x: geometry.output.width, y: 0),
            CGPoint(x: 0, y: geometry.output.height),
            CGPoint(x: geometry.output.width, y: geometry.output.height),
        ]
        let bounds = CGRect(origin: .zero, size: geometry.source).insetBy(
            dx: -Self.coordinateTolerance, dy: -Self.coordinateTolerance)
        guard corners.allSatisfy({ bounds.contains($0.applying(inverse)) }) else {
            throw EngineError.imageGainMapUnsupported
        }
        let outputStride = outputWidth * channels
        var rendered = Data(count: outputStride * outputHeight)
        try rendered.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            try pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for y in 0..<outputHeight {
                    try Task.checkCancellation()
                    for x in 0..<outputWidth {
                        let point = CGPoint(
                            x: (Double(x) + 0.5) * geometry.output.width / Double(outputWidth),
                            y: (Double(y) + 0.5) * geometry.output.height / Double(outputHeight)
                        ).applying(inverse)
                        guard point.x >= 0, point.y >= 0,
                            point.x <= geometry.source.width, point.y <= geometry.source.height
                        else { throw EngineError.imageGainMapUnsupported }
                        let sampleX = min(
                            max(point.x / geometry.source.width * Double(width) - 0.5, 0), Double(width - 1))
                        let sampleY = min(
                            max(point.y / geometry.source.height * Double(height) - 0.5, 0), Double(height - 1))
                        let left = Int(sampleX)
                        let top = Int(sampleY)
                        let right = min(left + 1, width - 1)
                        let bottom = min(top + 1, height - 1)
                        let fractionX = sampleX - Double(left)
                        let fractionY = sampleY - Double(top)
                        for channel in 0..<channels {
                            let upper =
                                Double(source[top * stride + left * channels + channel]) * (1 - fractionX)
                                + Double(source[top * stride + right * channels + channel]) * fractionX
                            let lower =
                                Double(source[bottom * stride + left * channels + channel]) * (1 - fractionX)
                                + Double(source[bottom * stride + right * channels + channel]) * fractionX
                            destination[y * outputStride + x * channels + channel] = UInt8(
                                (upper * (1 - fractionY) + lower * fractionY).rounded())
                        }
                    }
                }
            }
        }
        description[kCGImagePropertyWidth] = outputWidth
        description[kCGImagePropertyHeight] = outputHeight
        description[kCGImagePropertyBytesPerRow] = outputStride
        contents[kCGImageAuxiliaryDataInfoDataDescription] = description
        contents[kCGImageAuxiliaryDataInfoData] = rendered
        return try Self(type: type, payload: contents as CFDictionary).upright()
    }

    private func upright() throws -> Self {
        guard var contents = payload as? [CFString: Any],
            var description = contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
        else { throw EngineError.imageGainMapUnsupported }
        if description[kCGImagePropertyOrientation] != nil {
            description[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        }
        if let calibration = try Self.metadata(payload),
            CGImageMetadataCopyTagWithPath(calibration, nil, "tiff:Orientation" as CFString) != nil
        {
            guard let upright = CGImageMetadataCreateMutableCopy(calibration),
                CGImageMetadataSetValueWithPath(
                    upright, nil, "tiff:Orientation" as CFString, CGImagePropertyOrientation.up.rawValue as CFNumber)
            else { throw EngineError.imageGainMapUnsupported }
            contents[kCGImageAuxiliaryDataInfoMetadata] = upright
        }
        contents[kCGImageAuxiliaryDataInfoDataDescription] = description
        return Self(type: type, payload: contents as CFDictionary)
    }

    static func verify(_ expected: [Self], in source: CGImageSource) throws {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let decoded = try read(source, at: index)
        for gainMap in expected {
            guard let actual = decoded.first(where: { $0.type == gainMap.type })?.payload else {
                throw EngineError.imageGainMapUnsupported
            }
            let before = try Raster(gainMap.payload)
            let after = try Raster(actual)
            guard before.width == after.width, before.height == after.height, before.pixelFormat == after.pixelFormat,
                try calibrationMatches(gainMap.payload, actual)
            else { throw EngineError.imageGainMapUnsupported }
            let sampleFractions = [0.25, 0.5, 0.75]
            let maximumSampleDifference = 16
            // Chroma interpolation spans adjacent RGB pixels.
            let sampleRadius = before.channels == 1 ? 0 : 1
            for y in sampleFractions {
                for x in sampleFractions {
                    let column = Int(x * Double(before.width))
                    let row = Int(y * Double(before.height))
                    let columns = max(0, column - sampleRadius)..<min(column + sampleRadius + 1, before.width)
                    let rows = max(0, row - sampleRadius)..<min(row + sampleRadius + 1, before.height)
                    for channel in 0..<before.channels {
                        var difference = 0
                        for sampleRow in rows {
                            for sampleColumn in columns {
                                let original = before.pixels[
                                    sampleRow * before.stride + sampleColumn * before.channels + channel]
                                let decoded = after.pixels[
                                    sampleRow * after.stride + sampleColumn * after.channels + channel]
                                difference += abs(Int(original) - Int(decoded))
                            }
                        }
                        guard difference <= maximumSampleDifference * columns.count * rows.count else {
                            throw EngineError.imageGainMapUnsupported
                        }
                    }
                }
            }
        }
    }

    private static func metadata(_ payload: CFDictionary) throws -> CGImageMetadata? {
        guard let value = (payload as NSDictionary)[kCGImageAuxiliaryDataInfoMetadata] else { return nil }
        guard CFGetTypeID(value as CFTypeRef) == CGImageMetadataGetTypeID()
        else { throw EngineError.imageGainMapUnsupported }
        switch value {
        case let calibration as CGImageMetadata: return calibration
        default: throw EngineError.imageGainMapUnsupported
        }
    }

    private static func calibrationMatches(_ original: CFDictionary, _ decoded: CFDictionary) throws -> Bool {
        let expected = try metadata(original)
        let actual = try metadata(decoded)
        guard let expected, let actual else { return expected == nil && actual == nil }
        func containsMatchingTags(_ lhs: CGImageMetadata, _ rhs: CGImageMetadata) -> Bool {
            var matches = true
            CGImageMetadataEnumerateTagsUsingBlock(lhs, nil, nil) { path, tag in
                guard let other = CGImageMetadataCopyTagWithPath(rhs, nil, path), Self.tagsMatch(tag, other)
                else {
                    matches = false
                    return false
                }
                return true
            }
            return matches
        }
        return containsMatchingTags(expected, actual) && containsMatchingTags(actual, expected)
    }

    private static func tagsMatch(_ lhs: CGImageMetadataTag, _ rhs: CGImageMetadataTag) -> Bool {
        let type = CGImageMetadataTagGetType(lhs)
        guard CGImageMetadataTagCopyNamespace(lhs) == CGImageMetadataTagCopyNamespace(rhs),
            CGImageMetadataTagCopyName(lhs) == CGImageMetadataTagCopyName(rhs),
            type == CGImageMetadataTagGetType(rhs),
            let leftValue = CGImageMetadataTagCopyValue(lhs),
            let rightValue = CGImageMetadataTagCopyValue(rhs)
        else { return false }
        let valuesEqual: Bool
        if type == .arrayUnordered {
            guard CFGetTypeID(leftValue) == CFArrayGetTypeID(), CFGetTypeID(rightValue) == CFArrayGetTypeID(),
                let leftArray = leftValue as? [Any], let rightArray = rightValue as? [Any]
            else { return false }
            valuesEqual = arraysMatch(leftArray, rightArray, unordered: true)
        } else {
            valuesEqual = valuesMatch(leftValue, rightValue)
        }
        guard valuesEqual else { return false }
        let leftQualifiers = CGImageMetadataTagCopyQualifiers(lhs)
        let rightQualifiers = CGImageMetadataTagCopyQualifiers(rhs)
        guard let leftQualifiers else { return rightQualifiers == nil }
        guard let rightQualifiers, let leftArray = leftQualifiers as? [Any],
            let rightArray = rightQualifiers as? [Any]
        else { return false }
        return arraysMatch(leftArray, rightArray, unordered: true)
    }

    private static func valuesMatch(_ lhs: Any, _ rhs: Any) -> Bool {
        let leftValue = lhs as CFTypeRef
        let rightValue = rhs as CFTypeRef
        let type = CFGetTypeID(leftValue)
        guard type == CFGetTypeID(rightValue) else { return false }
        if type == CGImageMetadataTagGetTypeID() {
            guard case let leftTag as CGImageMetadataTag = lhs,
                case let rightTag as CGImageMetadataTag = rhs
            else { return false }
            return tagsMatch(leftTag, rightTag)
        }
        if type == CFArrayGetTypeID() {
            guard let leftArray = lhs as? [Any], let rightArray = rhs as? [Any] else { return false }
            return arraysMatch(leftArray, rightArray, unordered: false)
        }
        if type == CFDictionaryGetTypeID() {
            guard let leftFields = lhs as? [String: Any], let rightFields = rhs as? [String: Any],
                leftFields.count == rightFields.count
            else { return false }
            return leftFields.allSatisfy { name, value in
                guard let other = rightFields[name] else { return false }
                return valuesMatch(value as CFTypeRef, other as CFTypeRef)
            }
        }
        return (type == CFStringGetTypeID() || type == CFNumberGetTypeID() || type == CFBooleanGetTypeID())
            && CFEqual(leftValue, rightValue)
    }

    private static func arraysMatch(_ lhs: [Any], _ rhs: [Any], unordered: Bool) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if !unordered {
            return zip(lhs, rhs).allSatisfy { valuesMatch($0 as CFTypeRef, $1 as CFTypeRef) }
        }
        var unmatched = rhs
        for value in lhs {
            guard let index = unmatched.firstIndex(where: { valuesMatch(value as CFTypeRef, $0 as CFTypeRef) })
            else { return false }
            unmatched.remove(at: index)
        }
        return true
    }

    private struct Raster {
        let pixels: Data
        let width: Int
        let height: Int
        let stride: Int
        let channels: Int
        let pixelFormat: OSType

        init(_ payload: CFDictionary) throws {
            guard let contents = payload as? [CFString: Any],
                let description = contents[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
                let pixels = contents[kCGImageAuxiliaryDataInfoData] as? Data,
                let width = description[kCGImagePropertyWidth] as? Int,
                let height = description[kCGImagePropertyHeight] as? Int,
                let stride = description[kCGImagePropertyBytesPerRow] as? Int,
                let pixelFormat = description[kCGImagePropertyPixelFormat] as? OSType
            else { throw EngineError.imageGainMapUnsupported }
            switch pixelFormat {
            case kCVPixelFormatType_OneComponent8: channels = 1
            case kCVPixelFormatType_24RGB: channels = 3
            case kCVPixelFormatType_32RGBA, kCVPixelFormatType_32BGRA: channels = 4
            default: throw EngineError.imageGainMapUnsupported
            }
            guard width > 0, height > 0, stride > 0,
                width <= maximumRasterBytes / channels, stride >= width * channels,
                height <= maximumRasterBytes / stride, pixels.count >= height * stride
            else { throw EngineError.imageGainMapUnsupported }
            self.pixels = pixels
            self.width = width
            self.height = height
            self.stride = stride
            self.pixelFormat = pixelFormat
        }
    }

}

struct GainMapGeometry {
    let source: CGSize
    let output: CGSize
    let transform: CGAffineTransform
    var swapsAxes = false

    static func resize(_ source: CGImage, to output: CGImage) -> Self {
        Self(
            source: CGSize(width: source.width, height: source.height),
            output: CGSize(width: output.width, height: output.height),
            transform: CGAffineTransform(
                scaleX: Double(output.width) / Double(source.width),
                y: Double(output.height) / Double(source.height)))
    }

    static func crop(_ source: CGImage, to rect: CGRect) -> Self {
        Self(
            source: CGSize(width: source.width, height: source.height), output: rect.size,
            transform: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    static func orientation(_ source: CGSize, _ orientation: CGImagePropertyOrientation) -> Self {
        let width = source.width
        let height = source.height
        let matrix: CGAffineTransform
        switch orientation {
        case .up: matrix = .identity
        case .upMirrored: matrix = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case .down: matrix = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case .downMirrored: matrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case .leftMirrored: matrix = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right: matrix = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case .rightMirrored: matrix = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case .left: matrix = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        }
        return Self(
            source: source, output: orientation.swapsAxes ? CGSize(width: height, height: width) : source,
            transform: matrix, swapsAxes: orientation.swapsAxes)
    }

    static func rotation(_ source: CGImage, to output: CGImage, degrees: Double) -> Self {
        let radians = degrees * .pi / 180
        let transform = CGAffineTransform(translationX: -Double(source.width) / 2, y: -Double(source.height) / 2)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: Double(output.width) / 2, y: Double(output.height) / 2))
        return Self(
            source: CGSize(width: source.width, height: source.height),
            output: CGSize(width: output.width, height: output.height), transform: transform,
            swapsAxes: abs(degrees.truncatingRemainder(dividingBy: 180)) == 90)
    }
}
