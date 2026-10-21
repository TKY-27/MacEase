import Foundation
import MenuCatalog
import PDFKit

enum PDFEditing {
    private static let mergedSuffix = " (merged)"
    private static let extractedSuffix = " (extracted)"
    private static let pdfExtension = "pdf"

    static func merge(_ inputs: [URL], pages: [PDFPageReference]?, context: ItemContext) throws -> ItemResult {
        let minimum = OperationID.pdfMerge.minimumSelection
        guard inputs.count >= minimum, let first = inputs.first else {
            throw EngineError.invalidInput(.tooFewFiles(minimum: minimum))
        }
        let documents = try inputs.map { ($0, try openForCopying($0)) }
        let byFile = Dictionary(documents) { earlier, _ in earlier }
        let order =
            pages
            ?? documents.flatMap { url, document in
                (0..<document.pageCount).map { PDFPageReference(file: url, pageIndex: $0) }
            }
        guard !order.isEmpty else { throw EngineError.invalidInput(.noPages) }
        let merged = PDFDocument()
        for (position, reference) in order.enumerated() {
            try Task.checkCancellation()
            guard let document = byFile[reference.file] else {
                throw EngineError.unexpected("merge page from an unselected file")
            }
            merged.insert(try copy(of: reference.pageIndex, in: document), at: merged.pageCount)
            context.progress(Double(position + 1) / Double(order.count))
        }
        let name = "\(baseName(of: first))\(mergedSuffix).\(pdfExtension)"
        let staged = try context.stagingURL(for: first, name: name)
        try write(merged, to: staged)
        return .derived(nextTo: first, outputs: [StagedFile(url: staged, name: name, check: .pdf)])
    }

    static func compress(_ url: URL, context: ItemContext) throws -> ItemResult {
        let document = try openForReplacement(url)
        // PDFKit otherwise copies untouched documents verbatim.
        let first = try page(0, in: document)
        document.removePage(at: 0)
        document.insert(first, at: 0)
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        try write(document, to: staged, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        guard let originalSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            let outputSize = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { throw EngineError.unexpected("PDF size unreadable") }
        guard outputSize < originalSize else { return .skipped(.outputNotSmaller) }
        return .replace(original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .pdf))
    }

    static func rotate(_ url: URL, degrees: Int, context: ItemContext) throws -> ItemResult {
        let document = try openForReplacement(url)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try page(index, in: document).rotation += degrees
        }
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        try write(document, to: staged)
        return .replace(original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .pdf))
    }

    static func extract(_ pages: IndexSet, from url: URL, context: ItemContext) throws -> ItemResult {
        let document = try openForCopying(url)
        guard !pages.isEmpty else { throw EngineError.invalidInput(.noPages) }
        let extracted = PDFDocument()
        for index in pages {
            extracted.insert(try copy(of: index, in: document), at: extracted.pageCount)
        }
        let name = "\(baseName(of: url))\(extractedSuffix).\(pdfExtension)"
        let staged = try context.stagingURL(for: url, name: name)
        try write(extracted, to: staged)
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .pdf)])
    }

    static func split(_ url: URL, context: ItemContext) throws -> ItemResult {
        let document = try openForCopying(url)
        let folder = try stagingFolder(for: url, context: context)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let single = PDFDocument()
            single.insert(try copy(of: index, in: document), at: 0)
            let name = pageFileName(
                base: baseName(of: url), index: index, count: document.pageCount, extension: pdfExtension)
            try write(single, to: folder.appending(path: name))
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return .derived(nextTo: url, outputs: [StagedFile(url: folder, name: baseName(of: url), check: .folder)])
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw EngineError.decodeFailed("PDF does not open") }
        guard !document.isLocked else { throw EngineError.invalidInput(.encrypted) }
        guard document.pageCount > 0 else { throw EngineError.invalidInput(.emptyInput) }
        return document
    }

    private static func openForReplacement(_ url: URL) throws -> PDFDocument {
        let document = try open(url)
        guard !document.isEncrypted else { throw EngineError.invalidInput(.encrypted) }
        return document
    }

    static func openForCopying(_ url: URL) throws -> PDFDocument {
        let document = try open(url)
        guard document.allowsCopying else { throw EngineError.invalidInput(.pdfCopyingNotAllowed) }
        return document
    }

    static func page(_ index: Int, in document: PDFDocument) throws -> PDFPage {
        guard (0..<document.pageCount).contains(index), let page = document.page(at: index) else {
            throw EngineError.unexpected("page index out of range")
        }
        return page
    }

    static func baseName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func stagingFolder(for url: URL, context: ItemContext) throws -> URL {
        let folder = try context.stagingDirectory(for: url).appending(
            path: baseName(of: url), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Zero-padded so every app sorts them.
    static func pageFileName(base: String, index: Int, count: Int, extension pathExtension: String) -> String {
        let number = String(index + 1)
        let padding = String(repeating: "0", count: max(0, String(count).count - number.count))
        return "\(base) \(padding)\(number).\(pathExtension)"
    }

    private static func copy(of index: Int, in document: PDFDocument) throws -> PDFPage {
        guard let copy = try page(index, in: document).copy() as? PDFPage else {
            throw EngineError.unexpected("PDF page copy failed")
        }
        return copy
    }

    private static func write(
        _ document: PDFDocument,
        to url: URL,
        options: [PDFDocumentWriteOption: Any] = [:]
    ) throws {
        guard document.write(to: url, withOptions: options) else { throw EngineError.encodeFailed("PDF write failed") }
    }
}
