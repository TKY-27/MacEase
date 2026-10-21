import Foundation
import MenuCatalog

/// Zero-based page of one selected file.
public struct PDFPageReference: Codable, Hashable, Sendable {
    public let file: URL
    public let pageIndex: Int

    public init(file: URL, pageIndex: Int) {
        self.file = file
        self.pageIndex = pageIndex
    }
}

public enum PDFOperation: Codable, Hashable, Sendable {
    /// `nil` takes every page in Finder order.
    case merge(pages: [PDFPageReference]?)
    case toImages(StillFormat, dpi: Int)
    case toText
    case compress
    /// Clockwise; multiples of 90.
    case rotate(degrees: Int)
    /// Zero-based indices from the Page select panel.
    case extractPages(IndexSet)
    case split

    public static let defaultDPI = 144
}

enum PDFPlanner {
    static func operation(for op: OperationID, preset: String?, settings: Settings) -> PDFOperation? {
        switch (op, preset) {
        case (.pdfMerge, nil): .merge(pages: nil)
        case (.pdfToImages, let preset?):
            StillFormat(rawValue: preset).map { .toImages($0, dpi: settings.text.pdfImageDPI) }
        case (.pdfToText, nil): .toText
        case (.pdfCompress, nil): .compress
        case (.pdfRotate, "right-90"): .rotate(degrees: 90)
        case (.pdfRotate, "left-90"): .rotate(degrees: 270)
        case (.pdfRotate, "180"): .rotate(degrees: 180)
        case (.pdfSplit, nil): .split
        default: nil
        }
    }

    static func batch(_ operation: PDFOperation, op: OperationID, inputs: [URL]) -> Batch {
        let perFile: @Sendable (URL, ItemContext) async throws -> ItemResult
        switch operation {
        case .merge(let pages):
            guard !inputs.isEmpty else { return Batch(operation: op, items: []) }
            let item = OperationPlanner.validated(inputs, kind: .pdf) { context in
                try PDFEditing.merge(inputs, pages: pages, context: context)
            }
            return Batch(operation: op, items: [item])
        case .toImages(let format, let dpi):
            perFile = { try PDFExport.images(of: $0, format: format, dpi: dpi, context: $1) }
        case .toText:
            perFile = { try await PDFExport.text(of: $0, context: $1) }
        case .compress:
            perFile = { try PDFEditing.compress($0, context: $1) }
        case .rotate(let degrees):
            perFile = { try PDFEditing.rotate($0, degrees: degrees, context: $1) }
        case .extractPages(let pages):
            perFile = { try PDFEditing.extract(pages, from: $0, context: $1) }
        case .split:
            perFile = { try PDFEditing.split($0, context: $1) }
        }
        let items = inputs.map { url in
            OperationPlanner.validated(url, kind: .pdf) { context in try await perFile(url, context) }
        }
        return Batch(operation: op, items: items)
    }
}
