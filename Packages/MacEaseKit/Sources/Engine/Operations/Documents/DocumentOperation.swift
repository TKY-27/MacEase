import Foundation
import MenuCatalog

public enum DocumentOutput: String, Codable, Hashable, Sendable {
    case pdf
    case txt
}

enum DocumentPlanner {
    static func batch(_ output: DocumentOutput, inputs: [URL]) -> Batch {
        let work = inputs.map { url in
            OperationPlanner.validated(url, kind: .document) { context in
                let bytes = try AttributedDocument.convert(url, toPDF: output == .pdf)
                try Task.checkCancellation()
                let name = url.deletingPathExtension().lastPathComponent + "." + output.rawValue
                let staged = try context.stagingURL(for: url, name: name)
                try bytes.write(to: staged)
                context.warn(.documentLayoutChanged)
                return .derived(
                    nextTo: url,
                    outputs: [StagedFile(url: staged, name: name, check: output == .pdf ? .pdf : .text(.utf8))])
            }
        }
        return Batch(operation: .documentConvert, items: work)
    }

    static func propertyLists(inputs: [URL]) -> Batch {
        let work = inputs.map { url in
            OperationPlanner.validated(url, kind: .plist) { context in
                let text = try PropertyListConversion.json(
                    from: ConversionInput.read(url), indent: context.settings.text.jsonIndent.unit)
                let name = url.deletingPathExtension().lastPathComponent + ".json"
                let staged = try context.stagingURL(for: url, name: name)
                try Data(text.utf8).write(to: staged)
                context.warn(.structuredTextFormattingLost)
                return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
            }
        }
        return Batch(operation: .plistConvert, items: work)
    }
}
