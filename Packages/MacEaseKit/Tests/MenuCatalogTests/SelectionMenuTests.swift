import Foundation
import Testing

@testable import MenuCatalog

@Suite struct SelectionMenuTests {
    private func catalog(speechAvailable: Bool = true, hidden: Set<String> = []) -> MenuFile {
        MenuFile(
            token: String(repeating: "a", count: 64), hostAvailable: true,
            visibleOperations: OperationID.allCases,
            titles: MenuTitles(
                operation: { $0.rawValue }, preset: { _, preset in preset }, kind: { $0.rawValue },
                speechAvailable: speechAvailable), hiddenEntries: hidden)
    }

    @Test(arguments: ["image", "video"])
    func editingMenusPrioritizeEditConvertCompressAndResolution(kind: String) {
        let suffix = kind == "image" ? "png" : "mov"
        let nodes = MenuLayout.nodes(for: catalog(), selection: [URL(filePath: "/source.\(suffix)")])
        let titles = nodes.compactMap { node -> String? in
            switch node {
            case .action(let title, _), .submenu(let title, _): title
            case .separator: nil
            }
        }
        #expect(Array(titles.prefix(4)) == ["\(kind).edit", "\(kind).convert", "\(kind).compress", "\(kind).resize"])
        #expect(titles.filter { $0 == "\(kind).convert" }.count == 1)
        #expect(titles.filter { $0 == "\(kind).rotate" }.count == 1)
    }

    @Test(arguments: ["zip", "7z", "tar", "tar.gz", "tgz", "zip.001", "7z.002", "tar.gz.010"])
    func hatchExtractionReplacesOrdinaryExtractionForSupportedNames(suffix: String) throws {
        let source = URL(filePath: "/absent/source.\(suffix.uppercased())")
        #expect(FileKind(fileURL: source) == .archive)
        let entries = catalog().entries.filter { MenuLayout.isApplicable($0, selection: [source]) }
        #expect(entries.contains { $0.op == .archiveHatchExtract })
        #expect(!entries.contains { $0.op == .archiveExtract })
        #expect(entries.contains { $0.op == .archiveBrowse } == (suffix == "zip"))
    }

    @Test(arguments: ["rar", "gz", "bz2", "xz", "tar.xz", "tar.bz2", "001", "zip.000", "zip.abc", "txt.001"])
    func unsupportedHatchNamesNeverEnableDestructiveExtraction(suffix: String) {
        let source = URL(filePath: "/absent/source.\(suffix)")
        let entries = catalog().entries.filter { MenuLayout.isApplicable($0, selection: [source]) }
        #expect(!entries.contains { $0.op == .archiveHatchExtract })
        #expect(entries.contains { $0.op == .archiveExtract } == (suffix == "rar"))
    }

    @Test func mixedArchiveSelectionCannotBypassFormatRestrictions() throws {
        let file = catalog()
        let hatch = try #require(file.entries.first { $0.op == .archiveHatchExtract })
        let rar = try #require(file.entries.first { $0.op == .archiveExtract })
        let selection = [URL(filePath: "/first.zip"), URL(filePath: "/second.rar")]
        #expect(!MenuLayout.isApplicable(hatch, selection: selection))
        #expect(!MenuLayout.isApplicable(rar, selection: selection))
        #expect(MenuLayout.isApplicable(hatch, selection: [URL(filePath: "/first.zip"), URL(filePath: "/set.7z.002")]))
        #expect(!catalog(hidden: ["archive.hatchExtract/"]).entries.contains { $0.op == .archiveHatchExtract })
        #expect(file.catalogVersion != catalog(hidden: ["archive.hatchExtract/"]).catalogVersion)
    }

    @Test(arguments: [(OperationID.imageTraceSVG, "png"), (.archiveBrowse, "zip")])
    func previewMenusRequireOneMatchingInputAndRespectVisibility(op: OperationID, suffix: String) throws {
        let file = catalog()
        let entry = try #require(file.entries.first { $0.op == op })
        let source = URL(fileURLWithPath: "/absent/source.\(suffix.uppercased())")
        #expect(entry.preset == nil)
        #expect(entry.path == [op.rawValue])
        #expect(MenuLayout.isApplicable(entry, selection: [source]))
        #expect(!MenuLayout.isApplicable(entry, selection: [source, source]))
        for excluded in ["jpg", "apng", "svg", "7z", "tar", "txt"] {
            #expect(!MenuLayout.isApplicable(entry, selection: [URL(fileURLWithPath: "/absent/source.\(excluded)")]))
        }
        let hidden = catalog(hidden: ["\(op.rawValue)/"])
        #expect(!hidden.entries.contains { $0.op == op })
        #expect(file.catalogVersion != hidden.catalogVersion)
        let decoded = try JSONDecoder().decode(MenuFile.self, from: JSONEncoder().encode(file))
        #expect(decoded.entries.first { $0.op == op } == entry)
    }

    @Test(arguments: [
        (OperationID.imageHDRToSDR, ["heic", "heif", "hif", "jpg", "jpeg", "jpe", "avif", "jxl", "png"]),
        (.videoHDRToSDR, ["mov", "mp4", "m4v"]),
    ])
    func sdrUsesConvertAndOnlyCandidateFormats(op: OperationID, extensions: [String]) throws {
        let file = catalog()
        let entry = try #require(file.entries.first { $0.op == op })
        let parent = op == .imageHDRToSDR ? "image.convert" : "video.convert"
        #expect(entry.path == [parent, op.rawValue])
        #expect(entry.preset == nil)
        #expect(entry.separatorBefore)
        for suffix in extensions {
            #expect(MenuLayout.isApplicable(entry, selection: [URL(fileURLWithPath: "/absent/source.\(suffix)")]))
        }
        let excluded = op == .imageHDRToSDR ? ["webp", "gif", "tiff", "svg", "dng"] : ["mkv", "webm", "avi", "flv"]
        for suffix in excluded {
            #expect(!MenuLayout.isApplicable(entry, selection: [URL(fileURLWithPath: "/absent/source.\(suffix)")]))
        }
        #expect(!catalog(hidden: ["\(op.rawValue)/"]).entries.contains { $0.op == op })
    }

    @Test func unavailableSpeechRemovesBothMenus() {
        let available = catalog()
        let unavailable = catalog(speechAvailable: false)
        for op in [OperationID.audioSubtitles, .videoSubtitles] {
            #expect(available.entries.filter { $0.op == op }.map(\.preset) == ["srt", "vtt", "txt", "translated-srt"])
            #expect(!unavailable.entries.contains { $0.op == op })
        }
        #expect(available.catalogVersion != unavailable.catalogVersion)
        #expect(unavailable.entries.contains { $0.op == .audioConvert })
    }

    @Test func sdrSharesOneConvertSubmenuAfterAnimationExports() throws {
        let file = catalog()
        let nodes = MenuLayout.nodes(for: file, selection: [URL(fileURLWithPath: "/absent/clip.mov")])
        let converts = nodes.compactMap { node -> [MenuNode]? in
            if case .submenu("video.convert", let children) = node { return children }
            return nil
        }
        #expect(converts.count == 1)
        let children = try #require(converts.first)
        guard case .action(_, let index) = children.last else {
            Issue.record("Expected SDR as final Convert action")
            return
        }
        #expect(file.entries[index].op == .videoHDRToSDR)
        #expect(children.dropLast().last == .separator)
    }

    @Test(arguments: [
        "txt", "text", "md", "markdown", "log", "csv", "tsv", "ini", "cfg", "conf", "json", "xml", "yaml", "yml",
        "toml", "html", "htm", "css", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "cc", "hh",
        "cs", "java", "kt", "py", "rb", "go", "rs", "php", "pl", "lua", "sh", "bash", "bat", "cmd", "ps1", "psm1",
        "sql", "srt", "vtt", "asc", "tex", "rst", "env", "props", "properties", "gradle", "cmake", "m", "mm",
        "swift", "vb", "r", "jl",
    ])
    func everyTextExtensionReceivesEncodingAndEndings(suffix: String) {
        let selection = [URL(fileURLWithPath: "/absent/source.\(suffix.uppercased())")]
        #expect(FileKind(fileURL: selection[0]) == .text)
        let entries = catalog().entries
        #expect(
            entries.filter { $0.op == .textEncoding && MenuLayout.isApplicable($0, selection: selection) }.count == 4)
        #expect(
            entries.filter { $0.op == .textLineEndings && MenuLayout.isApplicable($0, selection: selection) }.count == 2
        )
    }
}
