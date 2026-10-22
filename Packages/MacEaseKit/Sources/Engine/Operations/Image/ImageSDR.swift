import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageSDR {
    private static let hdrNamespaces: Set<String> = [
        "http://ns.apple.com/HDRGainMap/1.0/", "http://ns.apple.com/HDRToneMap/1.0/",
        "http://ns.adobe.com/hdr-gain-map/1.0/",
    ]
    private static let standardHeadroom: Float = 1
    private static let headroomTolerance: Float = 0.001
    private static let decodeBytesPerPixel = 8
    private static let exifUncalibratedColorSpace = 65_535

    private enum SourceSignal {
        case sdr, hdr, metadataOnly
    }

    static func classification(_ url: URL) throws -> HDRClassification {
        let source = try source(url)
        return try signal(source, index: CGImageSourceGetPrimaryImageIndex(source)) == .sdr ? .sdr : .unknownHDR
    }

    static func convert(_ url: URL, context: ItemContext) throws -> ItemResult {
        try Task.checkCancellation()
        let source = try source(url)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        switch try signal(source, index: index) {
        case .sdr: return .skipped(.alreadySDR)
        case .hdr: context.warn(.hdrProvenanceUnknown)
        case .metadataOnly: throw EngineError.hdrConversionUnsupported
        }
        guard CGImageSourceGetCount(source) == 1,
            let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
            let format = ImageFormat(contentType: type), [.jpeg, .heic, .avif, .jxl, .png].contains(format)
        else { throw EngineError.hdrConversionUnsupported }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = try orientation(properties)
        let image = try decodedSDR(source, index: index, orientation: orientation)
        let metadata = try metadataForSDR(CGImageSourceCopyMetadataAtIndex(source, index, nil), image: image)
        let document = ImageDocument(
            url: url, contentType: type, frames: [ImageFrame(image: image, duration: 0)], metadata: metadata,
            pixelsPerInch: properties[kCGImagePropertyDPIWidth] as? Double ?? ImageDocument.defaultPixelsPerInch)
        let options = ImageOutput.defaultOptions(for: document, format: format, settings: context.settings.image)
        try Task.checkCancellation()
        let encoded = try ImageEncoder.encode(document.frames, as: format, options: options)
        try Task.checkCancellation()
        let name = ImageOutput.outputName(for: document, format: format)
        let staged = try context.stagingURL(for: url, name: name)
        try encoded.write(to: staged)
        return .replace(original: url, output: StagedFile(url: staged, name: name, check: .sdrImage))
    }

    static func verify(_ url: URL) throws {
        let source = try source(url)
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            try autoreleasepool {
                guard try signal(source, index: index) == .sdr,
                    !hasHDRMetadata(CGImageSourceCopyMetadataAtIndex(source, index, nil))
                else { throw EngineError.sdrVerificationFailed }
                var budget = FrameMemoryBudget()
                try budget.reserve(source: source, index: index)
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                    let colorSpace = image.colorSpace,
                    colorSpace.name == CGColorSpace.sRGB || colorSpace.name == CGColorSpace.displayP3,
                    image.contentHeadroom <= standardHeadroom + headroomTolerance
                else { throw EngineError.sdrVerificationFailed }
                var actual = FrameMemoryBudget()
                try actual.reserve(image)
            }
        }
    }

    private static func source(_ url: URL) throws -> CGImageSource {
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { throw EngineError.decodeFailed(url.lastPathComponent) }
        return source
    }

    private static func signal(_ source: CGImageSource, index: Int) throws -> SourceSignal {
        let content = try content(source, index: index)
        if content.gainMap || content.pixels { return .hdr }
        return hasHDRMetadata(CGImageSourceCopyMetadataAtIndex(source, index, nil)) ? .metadataOnly : .sdr
    }

    static func content(_ source: CGImageSource, index: Int) throws -> (gainMap: Bool, pixels: Bool) {
        var budget = FrameMemoryBudget()
        try budget.reserve(source: source, index: index)
        guard
            let image = CGImageSourceCreateImageAtIndex(
                source, index, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw EngineError.decodeFailed("image frame") }
        return (try ImageGainMap.contains(in: source, at: index), hasHDRPixels(image))
    }

    static func hasHDRPixels(_ image: CGImage) -> Bool {
        (image.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false)
            || image.contentHeadroom > standardHeadroom + headroomTolerance
    }

    private static func orientation(_ properties: [CFString: Any]) throws -> CGImagePropertyOrientation {
        guard let raw = properties[kCGImagePropertyOrientation] else { return .up }
        guard let value = raw as? UInt32, let orientation = CGImagePropertyOrientation(rawValue: value) else {
            throw EngineError.hdrConversionUnsupported
        }
        return orientation
    }

    static func decodedSDR(
        _ source: CGImageSource, index: Int, orientation: CGImagePropertyOrientation,
        retaining retained: FrameMemoryBudget = FrameMemoryBudget()
    ) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw EngineError.hdrConversionUnsupported }
        var budget = retained
        try budget.reserve(source: source, index: index)
        try budget.reserve(width: width, height: height, bytesPerPixel: decodeBytesPerPixel)
        let decoded = try toneMappingInput(source, index: index)
        var rendering = retained
        try rendering.reserve(decoded)
        try rendering.reserve(
            width: orientation.swapsAxes ? height : width, height: orientation.swapsAxes ? width : height,
            bytesPerPixel: decoded.bitsPerComponent > 8 ? 8 : 4, frameCount: 2)
        guard let sourceSpace = decoded.colorSpace,
            let outputSpace = CGColorSpace(
                name: sourceSpace.isWideGamutRGB ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        else { throw EngineError.hdrConversionUnsupported }
        let geometry = GainMapGeometry.orientation(CGSize(width: decoded.width, height: decoded.height), orientation)
        let precision = decoded.bitsPerComponent > 8 ? 16 : 8
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard
            let canvas = CGContext(
                data: nil, width: Int(geometry.output.width), height: Int(geometry.output.height),
                bitsPerComponent: precision, bytesPerRow: 0, space: outputSpace,
                bitmapInfo: (precision == 16 ? bitmap.union(.byteOrder16Little) : bitmap).rawValue)
        else { throw EngineError.hdrConversionUnsupported }
        canvas.translateBy(x: 0, y: geometry.output.height)
        canvas.scaleBy(x: 1, y: -1)
        canvas.concatenate(geometry.transform)
        canvas.translateBy(x: 0, y: geometry.source.height)
        canvas.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: geometry.source)
        if CGColorSpaceUsesITUR_2100TF(sourceSpace) {
            guard canvas.draw(decoded, in: bounds, by: .referenceWhiteBased, options: nil)
            else { throw EngineError.hdrConversionUnsupported }
        } else {
            canvas.draw(decoded, in: bounds)
        }
        guard let rendered = canvas.makeImage() else { throw EngineError.hdrConversionUnsupported }
        var actual = FrameMemoryBudget()
        try actual.reserve(decoded)
        try actual.reserve(rendered)
        return rendered
    }

    private static func toneMappingInput(_ source: CGImageSource, index: Int) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let native = CGImageSourceCreateImageAtIndex(source, index, options), let space = native.colorSpace
        else { throw EngineError.hdrConversionUnsupported }
        if CGColorSpaceUsesITUR_2100TF(space) {
            let headroom = native.calculatedContentHeadroom
            guard headroom.isFinite, headroom >= standardHeadroom,
                let calibrated = CGImageCreateCopyWithContentHeadroom(headroom, native)
            else { throw EngineError.hdrConversionUnsupported }
            return calibrated
        }
        let request = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(source, index, request),
            let decodedSpace = decoded.colorSpace, !CGColorSpaceUsesITUR_2100TF(decodedSpace),
            decoded.contentHeadroom <= standardHeadroom + headroomTolerance
        else { throw EngineError.hdrConversionUnsupported }
        return decoded
    }

    private static func hasHDRMetadata(_ metadata: CGImageMetadata?) -> Bool {
        guard let metadata else { return false }
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            if let namespace = CGImageMetadataTagCopyNamespace(tag) as String?, hdrNamespaces.contains(namespace) {
                found = true
            }
            return !found
        }
        return found
    }

    static func metadataForSDR(_ metadata: CGImageMetadata?, image: CGImage) throws -> CGImageMetadata? {
        guard let metadata else { return nil }
        guard let copy = CGImageMetadataCreateMutableCopy(metadata) else { throw EngineError.hdrConversionUnsupported }
        var obsolete: [CFString] = []
        var profiles: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String?
            let name = CGImageMetadataTagCopyName(tag) as String?
            let changesTransfer = namespace == "http://ns.adobe.com/tiff/1.0/" && name == "TransferFunction"
            if namespace.map(hdrNamespaces.contains) == true || changesTransfer {
                obsolete.append(path)
            }
            if namespace == "http://ns.adobe.com/photoshop/1.0/", name == "ICCProfile" { profiles.append(path) }
            return true
        }
        for path in obsolete {
            guard CGImageMetadataRemoveTagWithPath(copy, nil, path) else { throw EngineError.hdrConversionUnsupported }
        }
        let colorSpace = image.colorSpace?.name == CGColorSpace.sRGB ? 1 : exifUncalibratedColorSpace
        guard
            CGImageMetadataSetValueMatchingImageProperty(
                copy, kCGImagePropertyExifDictionary, kCGImagePropertyExifColorSpace, colorSpace as CFNumber)
        else { throw EngineError.hdrConversionUnsupported }
        for path in profiles {
            let profile = image.colorSpace?.name == CGColorSpace.sRGB ? "sRGB IEC61966-2.1" : "Display P3"
            guard CGImageMetadataSetValueWithPath(copy, nil, path, profile as CFString)
            else { throw EngineError.hdrConversionUnsupported }
        }
        return copy
    }
}
