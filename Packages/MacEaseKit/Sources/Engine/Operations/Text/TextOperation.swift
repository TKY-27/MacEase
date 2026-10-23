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
    case htmlToPDF = "html-pdf"
    case htmlToText = "html-txt"
    case jsonToXMLPlist = "json-plist-xml"
    case jsonToBinaryPlist = "json-plist-binary"
    case srtToVTT = "srt-vtt"
    case vttToSRT = "vtt-srt"
    case markdownToHTML = "md-html"
    case markdownToPDF = "md-pdf"
    case yamlToJSON = "yaml-json"
    case jsonToYAML = "json-yaml"
    case tomlToJSON = "toml-json"
    case jsonToTOML = "json-toml"

    var outputExtension: String {
        switch self {
        case .toTXT, .htmlToText: "txt"
        case .htmlToPDF, .markdownToPDF: "pdf"
        case .jsonToXMLPlist, .jsonToBinaryPlist: "plist"
        case .srtToVTT: "vtt"
        case .vttToSRT: "srt"
        case .csvToJSON, .xmlToJSON, .iniToJSON, .yamlToJSON, .tomlToJSON: "json"
        case .csvToXML, .jsonToXML, .iniToXML: "xml"
        case .csvToHTML, .markdownToHTML: "html"
        case .csvToMarkdown: "md"
        case .jsonToCSV: "csv"
        case .jsonToYAML: "yaml"
        case .jsonToTOML: "toml"
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
                return try await run(operation, on: url, settings: context.settings.text, context: context)
            }
        }
        return Batch(operation: op, items: items)
    }

    private static func run(
        _ operation: TextOperation,
        on url: URL,
        settings: TextSettings,
        context: ItemContext
    ) async throws -> ItemResult {
        switch operation {
        case .encoding(let target, let source):
            let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
            let result = try StreamingText.transcode(
                url, to: staged, target: target, source: source, settings: settings)
            if result.replaced { context.warn(.unmappableCharactersReplaced) }
            return try replacement(url, staged: staged, encoding: result.encoding)
        case .lineEndings(let ending):
            let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
            let encoding = try StreamingText.normalize(url, to: staged, ending: ending)
            return try replacement(url, staged: staged, encoding: encoding)
        case .json(let formatting):
            let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
            try JSONFormatter.write(url, formatting, settings: settings, to: staged)
            return try replacement(url, staged: staged, encoding: .utf8)
        case .convert(let conversion, let source):
            return try await convert(conversion, source: source, on: url, settings: settings, context: context)
        }
    }

    private static func convert(
        _ conversion: TextConversion, source: SourceTextEncoding?, on url: URL, settings: TextSettings,
        context: ItemContext
    ) async throws -> ItemResult {
        let input: Data
        switch conversion {
        case .htmlToPDF, .htmlToText,
            .jsonToXMLPlist, .jsonToBinaryPlist,
            .srtToVTT, .vttToSRT, .yamlToJSON, .jsonToYAML:
            input = try ConversionInput.read(url)
        case .markdownToHTML, .markdownToPDF:
            input = try ConversionInput.read(url, limit: Int64(MarkdownConversion.maximumBytes))
        case .tomlToJSON, .jsonToTOML:
            input = try ConversionInput.read(url, limit: Int64(TOMLConversion.maximumBytes))
        default:
            input = try Data(contentsOf: url)
        }
        let title = url.deletingPathExtension().lastPathComponent
        let bytes: Data
        let check: OutputCheck
        switch conversion {
        case .htmlToPDF, .htmlToText:
            let html = try TextEncoding.decode(input, assuming: source).text
            bytes = try await HTMLDocument.convert(html, source: url, toPDF: conversion == .htmlToPDF)
            check = conversion == .htmlToPDF ? .pdf : .text(.utf8)
            context.warn(.htmlOfflineContent)
        case .jsonToXMLPlist, .jsonToBinaryPlist:
            bytes = try PropertyListConversion.plist(
                from: TextEncoding.decode(input, assuming: source).text,
                format: conversion == .jsonToXMLPlist ? .xml : .binary)
            check = .plist
            context.warn(.structuredTextFormattingLost)
        case .markdownToHTML, .markdownToPDF:
            let html = try MarkdownConversion.html(TextEncoding.decode(input, assuming: source).text, title: title)
            context.warn(.markdownUnsafeContentOmitted)
            if conversion == .markdownToPDF {
                bytes = try await HTMLDocument.convert(html, source: url, toPDF: true)
                check = .pdf
                context.warn(.htmlOfflineContent)
            } else {
                bytes = Data(html.utf8)
                check = .text(.utf8)
            }
        case .yamlToJSON, .jsonToYAML, .tomlToJSON, .jsonToTOML:
            let output = try TextConverter.convert(
                input, conversion, settings: settings, title: title, source: source)
            bytes = Data(output.utf8)
            check = .text(.utf8)
            context.warn(.structuredTextFormattingLost)
        default:
            let output = try TextConverter.convert(
                input, conversion, settings: settings, title: title, source: source)
            bytes = Data(output.utf8)
            check = .text(.utf8)
        }
        try Task.checkCancellation()
        let name = "\(title).\(conversion.outputExtension)"
        let staged = try context.stagingURL(for: url, name: name)
        try bytes.write(to: staged)
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: check)])
    }

    private static func replacement(
        _ url: URL, staged: URL, encoding: String.Encoding
    ) throws -> ItemResult {
        if try StreamingText.equalContents(url, staged) { return .skipped(.alreadyDone) }
        return .replace(
            original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .text(encoding)))
    }
}
