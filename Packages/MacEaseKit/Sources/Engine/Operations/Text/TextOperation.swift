import Foundation
import MenuCatalog

public enum TextOperation: Codable, Hashable, Sendable {
    /// `source` is the panel's choice when ambiguous.
    case encoding(TextEncodingTarget, source: SourceTextEncoding?)
    case lineEndings(LineEnding)
    case convert(TextConversion, source: SourceTextEncoding? = nil)
    case json(JSONFormatting)
}

public enum TextEncodingTarget: String, Codable, CaseIterable, Sendable {
    case utf8 = "utf-8"
    case utf8BOM = "utf-8-bom"
    case utf16 = "utf-16"
    /// Written as CP932, the Windows superset.
    case shiftJIS = "shift-jis"
}

public enum SourceTextEncoding: String, Codable, CaseIterable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case cp932
    case eucJP
}

public enum LineEnding: String, Codable, CaseIterable, Sendable {
    case lf
    case crlf
}

public enum TextConversion: String, Codable, CaseIterable, Sendable {
    case toTXT = "txt"
    case csvToJSON = "csv-json"
    case csvToXML = "csv-xml"
    case csvToHTML = "csv-html"
    case csvToMarkdown = "csv-md"
    case jsonToCSV = "json-csv"
    case jsonToXML = "json-xml"
    case xmlToJSON = "xml-json"
    case iniToJSON = "ini-json"
    case iniToXML = "ini-xml"

    var outputExtension: String {
        switch self {
        case .toTXT: "txt"
        case .csvToJSON, .xmlToJSON, .iniToJSON: "json"
        case .csvToXML, .jsonToXML, .iniToXML: "xml"
        case .csvToHTML: "html"
        case .csvToMarkdown: "md"
        case .jsonToCSV: "csv"
        }
    }
}

public enum JSONFormatting: String, Codable, CaseIterable, Sendable {
    case pretty
    case minify
    case sortKeys = "sort"
}

public enum JSONKeyComparison: String, Codable, CaseIterable, Sendable {
    case ordinal
    case caseInsensitive
    case natural
}

enum TextPlanner {
    static func operation(for op: OperationID, preset: String?) -> TextOperation? {
        guard let preset else { return nil }
        return switch op {
        case .textEncoding: TextEncodingTarget(rawValue: preset).map { .encoding($0, source: nil) }
        case .textLineEndings: LineEnding(rawValue: preset).map(TextOperation.lineEndings)
        case .textConvert: TextConversion(rawValue: preset).map { .convert($0) }
        case .textJSON: JSONFormatting(rawValue: preset).map(TextOperation.json)
        default: nil
        }
    }

    static func batch(_ operation: TextOperation, op: OperationID, inputs: [URL]) -> Batch {
        let items = inputs.map { url in
            OperationPlanner.validated(url, kind: .text) { context in
                if case .convert(let conversion, _) = operation {
                    let entry = MenuEntry(op: .textConvert, preset: conversion.rawValue, path: [])
                    guard MenuLayout.isApplicable(entry, selection: inputs) else {
                        throw EngineError.invalidInput(.unsupportedFileType)
                    }
                }
                return try run(operation, on: url, settings: context.settings.text, context: context)
            }
        }
        return Batch(operation: op, items: items)
    }

    private static func run(
        _ operation: TextOperation,
        on url: URL,
        settings: TextSettings,
        context: ItemContext
    ) throws -> ItemResult {
        let input = try Data(contentsOf: url)
        switch operation {
        case .encoding(let target, let source):
            let decoded = try TextEncoding.decode(input, assuming: source)
            let output = try TextEncoding.encode(
                decoded.text, as: target, unmappable: settings.unmappable, substitute: settings.shiftJISSubstitute)
            if output.replaced { context.warn(.unmappableCharactersReplaced) }
            return try replace(url, input: input, output: output.data, encoding: output.encoding, context: context)
        case .lineEndings(let ending):
            let output = try TextEncoding.normalizingLineEndings(input, to: ending)
            return try replace(url, input: input, output: output.data, encoding: output.encoding, context: context)
        case .json(let formatting):
            let output = try JSONFormatter.format(TextEncoding.decode(input).text, formatting, settings: settings)
            return try replace(url, input: input, output: Data(output.utf8), encoding: .utf8, context: context)
        case .convert(let conversion, let source):
            let title = url.deletingPathExtension().lastPathComponent
            let output = try TextConverter.convert(input, conversion, settings: settings, title: title, source: source)
            let name = "\(title).\(conversion.outputExtension)"
            let staged = try context.stagingURL(for: url, name: name)
            try Data(output.utf8).write(to: staged)
            return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
        }
    }

    private static func replace(
        _ url: URL,
        input: Data,
        output: Data,
        encoding: String.Encoding,
        context: ItemContext
    ) throws -> ItemResult {
        guard output != input else { return .skipped(.alreadyDone) }
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        try output.write(to: staged)
        return .replace(
            original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .text(encoding)))
    }
}
