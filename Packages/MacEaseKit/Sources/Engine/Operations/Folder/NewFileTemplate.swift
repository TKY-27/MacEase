import AppKit
import Formats
import Foundation

public struct NewFileTemplate: Codable, Hashable, Sendable {
    public enum BuiltIn: String, CaseIterable, Codable, Hashable, Sendable {
        case plainText = "txt"
        case markdown = "md"
        case richText = "rtf"
        case wordDocument = "docx"
    }

    private static let maximumNameBytes = 255

    public let pathExtension: String
    public let defaultBaseName: String
    public let initialBytes: Data

    public init(pathExtension: String, defaultBaseName: String, initialBytes: Data = Data()) {
        self.pathExtension = pathExtension
        self.defaultBaseName = defaultBaseName
        self.initialBytes = initialBytes
    }

    public static func builtIn(_ kind: BuiltIn, defaultBaseName: String) throws -> NewFileTemplate {
        let initialBytes: Data
        switch kind {
        case .plainText, .markdown:
            initialBytes = Data()
        case .richText:
            initialBytes = try emptyDocument(type: .rtf)
        case .wordDocument:
            initialBytes = try emptyDocument(type: .officeOpenXML)
        }
        return NewFileTemplate(
            pathExtension: kind.rawValue, defaultBaseName: defaultBaseName, initialBytes: initialBytes)
    }

    var normalizedExtension: String {
        pathExtension.hasPrefix(".") ? String(pathExtension.dropFirst()) : pathExtension
    }

    func outputCheck(for name: String) -> OutputCheck {
        switch (name as NSString).pathExtension.lowercased() {
        case "rtf": return .newFile(.richText)
        case "docx": return .newFile(.wordDocument)
        default:
            return initialBytes.isEmpty ? .newFile(.empty) : .newFile(.templateBytes(expectedCount: initialBytes.count))
        }
    }

    func candidateName() throws -> String {
        let suffix = normalizedExtension
        guard !defaultBaseName.isEmpty,
            AvailableName.checkedName(defaultBaseName),
            !suffix.contains("/"),
            !suffix.contains("\u{0}"),
            suffix != ".",
            suffix != "..",
            !suffix.hasPrefix("."),
            !suffix.hasSuffix(".")
        else {
            throw EngineError.invalidInput(.malformed("Invalid new file template name"))
        }
        let name = suffix.isEmpty ? defaultBaseName : "\(defaultBaseName).\(suffix)"
        guard AvailableName.checkedName(name), name.utf8.count <= Self.maximumNameBytes else {
            throw EngineError.invalidInput(.malformed("Invalid new file template name"))
        }
        return name
    }

    static func verifyDocument(_ url: URL, type: NSAttributedString.DocumentType) throws {
        let contents = try Data(contentsOf: url)
        guard !contents.isEmpty else { throw EngineError.encodeFailed("empty output") }
        if type == .officeOpenXML {
            do {
                try ArchiveListing.verify(url)
            } catch {
                throw EngineError.encodeFailed("output document archive does not list: \(error)")
            }
        }
        var attributes: NSDictionary?
        do {
            _ = try NSAttributedString(data: contents, options: [.documentType: type], documentAttributes: &attributes)
        } catch {
            throw EngineError.encodeFailed("output document does not open: \(error)")
        }
    }

    private static func emptyDocument(type: NSAttributedString.DocumentType) throws -> Data {
        try NSAttributedString(string: "").data(
            from: NSRange(location: 0, length: 0),
            documentAttributes: [.documentType: type])
    }
}
