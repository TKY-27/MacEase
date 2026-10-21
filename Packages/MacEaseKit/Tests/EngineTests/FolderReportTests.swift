import Foundation
import Testing

@testable import Engine

private func makeReportFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseU4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite(.serialized) struct FolderReportTests {
    @Test func rootContainmentUsesPathComponents() {
        let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)
        let users = URL(fileURLWithPath: "/Users", isDirectory: true)
        let unrelated = URL(fileURLWithPath: "/Users-old", isDirectory: true)

        #expect(FolderAnalysis.isDescendant(users, of: filesystemRoot))
        #expect(FolderAnalysis.isDescendant(unrelated, of: filesystemRoot))
        #expect(!FolderAnalysis.isDescendant(unrelated, of: users))
        #expect(!FolderAnalysis.isDescendant(users, of: users))
    }

    @Test func analysisRejectsNonFolderRoots() throws {
        let root = try makeReportFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try makeTree(["source.txt": "content"], in: root)
        let file = root.appending(path: "source.txt")
        let web = try #require(URL(string: "https://example.invalid/report"))

        #expect(throws: FolderAnalysis.ScanError.self) {
            try FolderAnalysis.scan([web], settings: FolderSettings()) { _ in }
        }
        #expect(throws: FolderAnalysis.ScanError.self) {
            try FolderAnalysis.scan([file], settings: FolderSettings()) { _ in }
        }
    }

    @Test func overlappingRootsAndHardLinksCountOnce() throws {
        let root = try makeReportFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try makeTree(["a/one.txt": "same", "b/two.txt": "same", "b/empty/": ""], in: root)
        let original = root.appending(path: "a/one.txt")
        try FileManager.default.linkItem(at: original, to: root.appending(path: "b/hardlink.txt"))
        let nested = root.appending(path: "a")
        let alias = root.deletingLastPathComponent().appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: alias) } }

        let analysis = try FolderAnalysis.scan([nested, root, root, alias], settings: FolderSettings()) { _ in }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        #expect(analysis.roots.map(\.requested) == [nested, root, root, alias])
        #expect(analysis.roots[0].coveredBy?.path == canonicalRoot.path)
        #expect(analysis.roots[1].coveredBy == nil)
        #expect(analysis.roots[2].coveredBy?.path == canonicalRoot.path)
        #expect(analysis.roots[3].coveredBy?.path == canonicalRoot.path)
        #expect(analysis.fileCount == 2)
        #expect(analysis.totalBytes == 8)
        #expect(analysis.duplicateGroups.count == 1)
        #expect(analysis.duplicateGroups[0].reclaimableBytes == 4)
        #expect(analysis.emptyFolders.map(\.lastPathComponent) == ["empty"])
    }

    @Test func exportsEscapeNamesAndDeclareBOM() throws {
        let root = try makeReportFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let malicious = "=2,\"<&'.txt"
        try makeTree([malicious: "x", "line\nbreak.md": "y"], in: root)
        let analysis = try FolderAnalysis.scan(root, settings: FolderSettings()) { _ in }

        let csv = try analysis.serialized(as: .csv)
        let json = try analysis.serialized(as: .json)
        let html = try analysis.serialized(as: .html)
        let txt = try analysis.serialized(as: .txt)
        let markdown = try analysis.serialized(as: .markdown)

        #expect(AnalysisExportFormat.csv.includesUTF8BOM)
        #expect(AnalysisExportFormat.allCases.filter(\.includesUTF8BOM) == [.csv])
        #expect(csv.hasPrefix("\u{FEFF}\"Section\""))
        #expect(csv.contains("\"'=2,\"\"<&'.txt\""))
        #expect(csv.contains("\r\n"))
        #expect(!json.hasPrefix("\u{FEFF}"))
        #expect(json.contains("\"fileCount\" : 2"))
        #expect(!html.hasPrefix("\u{FEFF}"))
        #expect(html.contains("=2,&quot;&lt;&amp;&#39;.txt"))
        #expect(!html.contains("<&'"))
        #expect(!html.contains("<script"))
        #expect(txt.contains("line\\nbreak.md"))
        #expect(markdown.contains("line\\nbreak.md"))
        #expect(try analysis.serialized(as: .markdown) == analysis.markdown)
    }

    @Test func sameNamedRootsKeepDistinctReportPaths() throws {
        let workspace = try makeReportFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: workspace) } }
        let first = workspace.appending(path: "A/report")
        let second = workspace.appending(path: "B/report")
        try makeTree(["x.txt": "one"], in: first)
        try makeTree(["x.txt": "two"], in: second)

        let analysis = try FolderAnalysis.scan([first, second], settings: FolderSettings()) { _ in }
        let csv = try analysis.serialized(as: .csv)
        let markdown = analysis.markdown

        #expect(analysis.fileCount == 2)
        #expect(csv.contains(first.path + "/x.txt"))
        #expect(csv.contains(second.path + "/x.txt"))
        #expect(markdown.contains(first.path + "/x.txt"))
        #expect(markdown.contains(second.path + "/x.txt"))
    }

    @Test func foldersOnlyTreeRetainsBranchLayout() throws {
        let root = try makeReportFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try makeTree(["A/B/": "", "A/file.txt": "x", "C/": "", "top.txt": "x"], in: root)

        let tree = try FolderTree.text(of: root, excluding: [], foldersOnly: true)

        #expect(tree == "\(root.lastPathComponent)\n├── A\n│   └── B\n└── C")
    }

}
