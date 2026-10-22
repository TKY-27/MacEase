import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFExport {
    static let pointsPerInch = 72.0
    private static let ocrDPI = 300
    private static let pageSeparator = "\u{0C}"
    private static let textExtension = "txt"
    private static let percent = 100.0
    private static let lzwCompression = 5

    static func tiff(of url: URL, dpi: Int, context: ItemContext) throws -> ItemResult {
        let document = try PDFEditing.open(url)
        guard document.allowsPrinting else { throw EngineError.invalidInput(.pdfPrintingNotAllowed) }
        var retained = FrameMemoryBudget.retainedImages
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let dimensions = try pixelSize(try PDFEditing.page(index, in: document), dpi: dpi)
            try retained.reserve(width: dimensions.width, height: dimensions.height)
        }
        let name = PDFEditing.baseName(of: url) + ".tiff"
        let staged = try context.stagingURL(for: url, name: name)
        guard
            let destination = CGImageDestinationCreateWithURL(
                staged as CFURL, UTType.tiff.identifier as CFString, document.pageCount, nil)
        else { throw EngineError.unsupportedCodec("TIFF") }
        let properties =
            [
                kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: lzwCompression],
            ] as CFDictionary
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try render(try PDFEditing.page(index, in: document), dpi: dpi)
                CGImageDestinationAddImage(destination, image, properties)
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        guard CGImageDestinationFinalize(destination),
            let verified = CGImageSourceCreateWithURL(staged as CFURL, nil),
            CGImageSourceGetCount(verified) == document.pageCount
        else { throw EngineError.encodeFailed("TIFF page verification failed") }
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .image)])
    }

    static func images(of url: URL, format: StillFormat, dpi: Int, context: ItemContext) throws -> ItemResult {
        let document = try PDFEditing.open(url)
        guard document.allowsPrinting else { throw EngineError.invalidInput(.pdfPrintingNotAllowed) }
        let layout = context.settings.text.pdfImageLayout
        let folder = try PDFEditing.stagingFolder(for: url, context: context)
        let (type, pathExtension) = format == .png ? (UTType.png, "png") : (UTType.jpeg, "jpg")
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] =
                Double(context.settings.image.jpegQuality) / percent
        }
        let base = PDFEditing.baseName(of: url)
        var looseFiles: [StagedFile] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try render(try PDFEditing.page(index, in: document), dpi: dpi)
                let name: String
                if layout == .looseFiles {
                    let number = String(index + 1)
                    let padding = String(repeating: "0", count: String(document.pageCount).count - number.count)
                    name =
                        document.pageCount == 1
                        ? "\(base).\(pathExtension)" : "\(base)_p\(padding)\(number).\(pathExtension)"
                } else {
                    name = PDFEditing.pageFileName(
                        base: base, index: index, count: document.pageCount, extension: pathExtension)
                }
                let target = folder.appending(path: name)
                guard
                    let destination = CGImageDestinationCreateWithURL(
                        target as CFURL, type.identifier as CFString, 1, nil)
                else { throw EngineError.encodeFailed("image destination unavailable") }
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw EngineError.encodeFailed("page image write failed")
                }
                if layout == .looseFiles {
                    looseFiles.append(StagedFile(url: target, name: name, check: .image))
                }
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        let outputs = layout == .looseFiles ? looseFiles : [StagedFile(url: folder, name: base, check: .folder)]
        return .derived(nextTo: url, outputs: outputs)
    }

    static func text(of url: URL, context: ItemContext) async throws -> ItemResult {
        let document = try PDFEditing.openForCopying(url)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let page = try PDFEditing.page(index, in: document)
            let embedded = page.string ?? ""
            if embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let image = try render(page, dpi: ocrDPI)
                pages.append(
                    try await TextRecognition.text(in: image, languages: context.settings.intelligence.ocrLanguages))
            } else {
                pages.append(embedded)
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw EngineError.invalidInput(.emptyInput) }
        let name = "\(PDFEditing.baseName(of: url)).\(textExtension)"
        let staged = try context.stagingURL(for: url, name: name)
        try Data(pages.joined(separator: pageSeparator).utf8).write(to: staged)
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
    }

    /// On white, as PDF pages assume paper.
    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        var budget = FrameMemoryBudget.renderedPage
        let (width, height) = try pixelSize(page, dpi: dpi)
        try budget.reserve(width: width, height: height)
        let scale = Double(dpi) / pointsPerInch
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let canvas = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EngineError.encodeFailed("page canvas unavailable") }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: canvas)
        guard let image = canvas.makeImage() else { throw EngineError.encodeFailed("page render failed") }
        return image
    }

    private static func pixelSize(_ page: PDFPage, dpi: Int) throws -> (width: Int, height: Int) {
        let bounds = page.bounds(for: .cropBox)
        let isQuarterTurned = page.rotation % 180 != 0
        let scale = Double(dpi) / pointsPerInch
        let scaledWidth = ((isQuarterTurned ? bounds.height : bounds.width) * scale).rounded()
        let scaledHeight = ((isQuarterTurned ? bounds.width : bounds.height) * scale).rounded()
        guard scaledWidth.isFinite, scaledHeight.isFinite,
            scaledWidth > 0, scaledHeight > 0,
            let width = Int(exactly: scaledWidth), let height = Int(exactly: scaledHeight)
        else {
            throw EngineError.invalidInput(.malformed("page is too large to render at \(dpi) dpi"))
        }
        return (width, height)
    }

}
