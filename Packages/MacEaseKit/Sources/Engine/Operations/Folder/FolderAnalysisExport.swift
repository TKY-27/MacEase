import Foundation

public enum AnalysisExportFormat: String, Codable, CaseIterable, Sendable {
    case csv
    case json
    case html
    case txt
    case markdown

    // CSV includes a BOM for spreadsheet detection.
    public var includesUTF8BOM: Bool { self == .csv }

    public var pathExtension: String { self == .markdown ? "md" : rawValue }
}

extension FolderAnalysis {
    public func serialized(as format: AnalysisExportFormat) throws -> String {
        switch format {
        case .csv: return csv
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
        case .html: return html
        case .txt: return plainText
        case .markdown: return markdown
        }
    }

    private var reclaimableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private var csv: String {
        var rows: [[String]] = [
            ["Section", "Name", "Count", "Bytes", "Detail"],
            ["Summary", "Files", String(fileCount), String(totalBytes), ""],
            ["Summary", "Duplicate groups", String(duplicateGroups.count), String(reclaimableBytes), ""],
            ["Summary", "Empty folders", String(emptyFolders.count), "", ""],
        ]
        rows += roots.map { ["Root", $0.requested.path, "", "", $0.relationship] }
        rows += largestFiles.map { ["Largest file", relativePath($0.url), "", String($0.bytes), ""] }
        rows += sizeByType.map { ["Type", $0.pathExtension, String($0.fileCount), String($0.bytes), ""] }
        for (index, group) in duplicateGroups.enumerated() {
            rows += group.files.map {
                ["Duplicate", relativePath($0), String(index + 1), String(group.bytesPerFile), ""]
            }
        }
        rows += emptyFolders.map { ["Empty folder", relativePath($0), "", "", ""] }
        return "\u{FEFF}" + rows.map { $0.map(Self.csvCell).joined(separator: ",") }.joined(separator: "\r\n")
            + "\r\n"
    }

    private var plainText: String {
        var lines = [
            folder.lastPathComponent,
            "Total bytes: \(totalBytes)", "Files: \(fileCount)",
            "Duplicate groups: \(duplicateGroups.count) (\(reclaimableBytes) reclaimable bytes)",
            "Empty folders: \(emptyFolders.count)", "", "Roots:",
        ]
        lines += roots.map { Self.singleLine($0.requested.path) + " (\(Self.singleLine($0.relationship)))" }
        lines += ["", "Largest files:"]
        lines += largestFiles.map { "\(Self.singleLine(relativePath($0.url)))\t\($0.bytes)" }
        lines += ["", "Size by type:"]
        lines += sizeByType.map { "\(Self.singleLine($0.pathExtension))\t\($0.fileCount)\t\($0.bytes)" }
        lines += ["", "Duplicates:"]
        for group in duplicateGroups {
            lines.append("\(group.bytesPerFile) bytes each")
            lines += group.files.map { Self.singleLine(relativePath($0)) }
        }
        lines += ["", "Empty folders:"]
        lines += emptyFolders.map { Self.singleLine(relativePath($0)) }
        return lines.joined(separator: "\n") + "\n"
    }

    private var html: String {
        var lines = [
            "<!doctype html>",
            "<html lang=\"en\"><head><meta charset=\"utf-8\"><title>Folder analysis</title></head><body>",
            "<h1>\(Self.htmlCell(folder.lastPathComponent))</h1>",
            "<p>Files: \(fileCount); bytes: \(totalBytes); duplicate groups: \(duplicateGroups.count); reclaimable bytes: \(reclaimableBytes); empty folders: \(emptyFolders.count)</p>",
            "<h2>Roots</h2><ul>",
        ]
        lines += roots.map { "<li>\(Self.htmlCell($0.requested.path)) (\(Self.htmlCell($0.relationship)))</li>" }
        lines += ["</ul>", "<h2>Largest files</h2><table><tr><th>File</th><th>Bytes</th></tr>"]
        lines += largestFiles.map {
            "<tr><td>\(Self.htmlCell(relativePath($0.url)))</td><td>\($0.bytes)</td></tr>"
        }
        lines += ["</table>", "<h2>Size by type</h2><table><tr><th>Type</th><th>Files</th><th>Bytes</th></tr>"]
        lines += sizeByType.map {
            "<tr><td>\(Self.htmlCell($0.pathExtension))</td><td>\($0.fileCount)</td><td>\($0.bytes)</td></tr>"
        }
        lines += ["</table>", "<h2>Duplicates</h2><ul>"]
        for group in duplicateGroups {
            lines.append("<li>\(group.bytesPerFile) bytes each<ul>")
            lines += group.files.map { "<li>\(Self.htmlCell(relativePath($0)))</li>" }
            lines.append("</ul></li>")
        }
        lines += ["</ul>", "<h2>Empty folders</h2><ul>"]
        lines += emptyFolders.map { "<li>\(Self.htmlCell(relativePath($0)))</li>" }
        lines += ["</ul></body></html>"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvCell(_ value: String) -> String {
        let leading = value.drop(while: \.isWhitespace)
        let protected = leading.first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func htmlCell(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }
}
