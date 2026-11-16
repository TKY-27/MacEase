import CoreGraphics
import Foundation

enum ImageExports {
    static let smallestIconEdge = 16
    static let appIconEdge = 1024
    static let appIconFile = "AppIcon.png"

    static func recognizeText(_ url: URL, output: TextOutput, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let text = try await TextRecognition.text(
            in: document.first, languages: context.settings.intelligence.ocrLanguages)
        guard !text.isEmpty else { return .skipped(.noTextFound) }
        switch output {
        case .clipboard: return .text(text, .clipboard)
        case .panel: return .text(text, .report)
        case .file:
            let name = (url.lastPathComponent as NSString).deletingPathExtension + "_ocr.txt"
            let staged = try context.stagingURL(for: url, name: name)
            let encoded = try TextEncoding.encode(
                text, as: context.settings.intelligence.ocrFileEncoding,
                unmappable: context.settings.text.unmappable,
                substitute: context.settings.text.shiftJISSubstitute)
            try encoded.data.write(to: staged)
            if encoded.replaced { context.warn(.unmappableCharactersReplaced) }
            return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(encoded.encoding))])
        }
    }

    /// One page per input, in order.
    static func pdf(from inputs: [URL], context: ItemContext) async throws -> ItemResult {
        guard let first = inputs.first else { return .skipped(.nothingToRemove) }
        let name = (first.lastPathComponent as NSString).deletingPathExtension + ".pdf"
        let staged = try context.stagingURL(for: first, name: name)
        // Streams pages, decoding one input at once.
        let pdf = try ImageEncoder.pdfContext(writingTo: staged)
        for (index, url) in inputs.enumerated() {
            try Task.checkCancellation()
            guard try ContentSniffer.matches(url, kind: .image) else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
            let loaded = try await ImageDocument.load(url)
            let document = try ImageOutput.prepared(loaded, as: .pdf, context: context, derived: true)
            guard !document.isAnimated else { throw EngineError.imageSequenceUnsupported }
            let images = document.isMultiPage ? document.frames.map(\.image) : [document.first]
            for image in images { ImageEncoder.addPDFPage(image, pixelsPerInch: document.pixelsPerInch, to: pdf) }
            context.progress(Double(index + 1) / Double(inputs.count))
        }
        pdf.closePDF()
        return .derived(nextTo: first, outputs: [StagedFile(url: staged, name: name, check: .pdf)])
    }

    static func iconSet(_ url: URL, kind: IconSetKind, context: ItemContext) async throws -> ItemResult {
        let loaded = try await ImageDocument.load(url)
        let document = try ImageOutput.prepared(loaded, as: .ico, context: context, derived: true)
        guard !document.isAnimated, !document.isMultiPage else { throw EngineError.imageSequenceUnsupported }
        let square = try ImageEncoder.square(document.first)
        guard square.width >= smallestIconEdge else { throw EngineError.invalidInput(.notSquareEnough) }
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let frame = [ImageFrame(image: square, duration: 0)]
        let options = EncodeOptions(quality: ImageEncoder.maximumQuality)
        let file: StagedFile
        switch kind {
        case .icns, .ico:
            let format: ImageFormat = kind == .icns ? .icns : .ico
            let name = base + "." + format.fileExtension
            let staged = try context.stagingURL(for: url, name: name)
            try ImageEncoder.encode(frame, as: format, options: options).write(to: staged)
            file = StagedFile(url: staged, name: name, check: document.toneMapsHDR ? .sdrImage : .image)
        case .appIconSet:
            let name = base + ".appiconset"
            let folder = try context.stagingURL(for: url, name: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let icon = try ImagePixels.scaled(square, width: appIconEdge, height: appIconEdge)
            let iconURL = folder.appending(path: appIconFile)
            try ImageEncoder.png(icon).write(to: iconURL)
            if document.toneMapsHDR { try ImageSDR.verify(iconURL) }
            try appIconContents().write(to: folder.appending(path: "Contents.json"))
            file = StagedFile(url: folder, name: name, check: .folder)
        }
        return .derived(nextTo: url, outputs: [file])
    }

    /// Single size; Xcode derives the rest.
    static func appIconContents() throws -> Data {
        let contents: [String: Any] = [
            "images": [
                [
                    "filename": appIconFile, "idiom": "universal", "platform": "ios",
                    "size": "\(appIconEdge)x\(appIconEdge)",
                ]
            ],
            "info": ["author": "xcode", "version": 1],
        ]
        return try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    }

}
