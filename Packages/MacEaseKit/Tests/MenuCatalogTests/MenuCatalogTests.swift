import Foundation
import Testing

@testable import MenuCatalog

private let titles = MenuTitles(
    operation: { $0.rawValue },
    preset: { op, preset in "\(op.rawValue)/\(preset)" },
    kind: { $0.rawValue.capitalized }
)

private func menuFile(_ operations: [OperationID] = OperationID.allCases) -> MenuFile {
    MenuFile(
        token: String(repeating: "a", count: 64), hostAvailable: true, visibleOperations: operations, titles: titles)
}

@Suite struct ClassificationTests {
    @Test(arguments: [
        ("photo.HEIC", FileKind.image), ("clip.mkv", .video), ("song.opus", .audio), ("doc.pdf", .pdf),
        ("data.yml", .text), ("backup.tgz", .archive), ("lib.jar", .jar), ("raw.CR3", .image),
    ])
    func classifiesFilesByExtension(name: String, kind: FileKind) {
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: false)) == kind)
    }

    @Test func unknownExtensionHasNoKind() {
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/notes.pages", isDirectory: false)) == nil)
    }

    @Test func directoriesAreFoldersButPackagesAreFiles() {
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/tmp/Photos 2024.v2", isDirectory: true)) == .folder)
        #expect(FileKind(fileURL: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)) == nil)
    }
}

@Suite struct MenuFileTests {
    @Test func everyOperationWithPresetsEndsWithCustom() {
        let file = menuFile()
        for op in OperationID.allCases where op.offersCustom {
            let entries = file.entries.filter { $0.op == op }
            #expect(entries.map(\.preset) == op.presets + [MenuEntry.customPreset])
        }
    }

    @Test func versionChangesWithEntriesAndRoundTripsThroughJSON() throws {
        let full = menuFile()
        let reduced = menuFile(OperationID.allCases.filter { $0 != .imageResize })
        #expect(full.catalogVersion != reduced.catalogVersion)
        #expect(full.catalogVersion.count == 64)
        let decoded = try MenuFile(json: try full.encoded())
        #expect(decoded == full)
        #expect(MenuFile.version(of: decoded.entries) == full.catalogVersion)
    }
}

@Suite struct MenuLayoutTests {
    private func url(_ name: String, directory: Bool = false) -> URL {
        URL(fileURLWithPath: "/Users/me/\(name)", isDirectory: directory)
    }

    @Test func singleKindListsOperationsThenAllFiles() throws {
        let file = menuFile()
        let nodes = MenuLayout.nodes(for: file, selection: [url("a.png"), url("b.jpg")])
        guard case .submenu(let title, let children) = try #require(nodes.first) else {
            Issue.record("expected submenu")
            return
        }
        #expect(title == "image.resize")
        #expect(children.suffix(2).first == .separator)
        #expect(nodes.contains(.separator))
        #expect(nodes.last.map { if case .submenu(let title, _) = $0 { title } else { "" } } == "any.checksum")
        #expect(!nodes.contains { if case .submenu(let title, _) = $0 { title.hasPrefix("video") } else { false } })
    }

    @Test func mixedSelectionGroupsByKindWithCounts() {
        let nodes = MenuLayout.nodes(for: menuFile(), selection: [url("a.png"), url("b.mov"), url("c.mp4")])
        let titles = nodes.compactMap { if case .submenu(let title, _) = $0 { title } else { nil } }
        #expect(titles == ["Image (1)", "Video (2)", "Any (3)"])
    }

    @Test func pdfMergeNeedsTwoPDFs() {
        let file = menuFile([.pdfMerge, .pdfSplit])
        let one = MenuLayout.nodes(for: file, selection: [url("a.pdf")])
        let two = MenuLayout.nodes(for: file, selection: [url("a.pdf"), url("b.pdf")])
        #expect(one.count == 1)
        #expect(two.count == 2)
    }

    @Test func foldersGetNoAllFilesSection() {
        let nodes = MenuLayout.nodes(for: menuFile(), selection: [url("Docs", directory: true)])
        #expect(!nodes.contains(.separator))
        #expect(!nodes.isEmpty)
    }

    @Test func entryIndicesPointAtTheirEntries() {
        let file = menuFile()
        func leaves(_ nodes: [MenuNode]) -> [(String, Int)] {
            nodes.flatMap { node -> [(String, Int)] in
                switch node {
                case .submenu(_, let children): leaves(children)
                case .action(let title, let index): [(title, index)]
                case .separator: []
                }
            }
        }
        for (title, index) in leaves(MenuLayout.nodes(for: file, selection: [url("a.wav"), url("b.txt")])) {
            #expect(file.entries[index].path.last == title)
        }
    }

    @Test func buildsWithinBudgetForOneThousandItems() {
        let file = menuFile()
        let selection = (0..<1000).map { url("file \($0).\(["png", "mov", "mp3", "pdf"][$0 % 4])") }
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MenuLayout.nodes(for: file, selection: selection) }
        #expect(elapsed < .milliseconds(30))
    }
}

@Suite struct RunRequestTests {
    @Test func roundTripsAwkwardPaths() throws {
        let paths = ["/tmp/a & b #1 100%.png", "/Users/me/写真/テスト+1=2?.heic", "/tmp/semi;colon,comma.txt"]
        let request = RunRequest(catalogVersion: "abc", entryIndex: 42, token: "tok", paths: paths)
        let url = try #require(request.url(scheme: "macease"))
        #expect(try RunRequest(url: url, scheme: "macease") == request)
    }

    @Test func carriesFiveThousandPaths() throws {
        let paths = (0..<5000).map { "/Users/me/Pictures/フォルダ & more/image #\($0) 50%.jpg" }
        let request = RunRequest(catalogVersion: "v", entryIndex: 1, token: "t", paths: paths)
        let url = try #require(request.url(scheme: "macease"))
        #expect(try RunRequest(url: url, scheme: "macease").paths == paths)
    }

    @Test func rejectsMalformedRequests() throws {
        let wrongScheme = try #require(URL(string: "other://run?v=a&e=1&t=b&path=/x"))
        #expect(throws: RunRequestError.notARunRequest) { try RunRequest(url: wrongScheme, scheme: "macease") }
        let noToken = try #require(URL(string: "macease://run?v=a&e=1&path=/x"))
        #expect(throws: RunRequestError.missingField("t")) { try RunRequest(url: noToken, scheme: "macease") }
        let relative = try #require(URL(string: "macease://run?v=a&e=1&t=b&path=x"))
        #expect(throws: RunRequestError.invalidPaths) { try RunRequest(url: relative, scheme: "macease") }
    }
}

@Suite struct RequestTokenTests {
    @Test func generatesDistinctWellFormedTokens() throws {
        let first = try RequestToken.generate()
        let second = try RequestToken.generate()
        #expect(RequestToken.isWellFormed(first))
        #expect(first != second)
        #expect(!RequestToken.isWellFormed("abc"))
        #expect(!RequestToken.isWellFormed(String(repeating: "g", count: 64)))
    }

    @Test func matchesOnlyIdenticalTokens() throws {
        let token = try RequestToken.generate()
        #expect(RequestToken.matches(token, token))
        #expect(!RequestToken.matches(String(token.dropLast()) + "0", token) || token.hasSuffix("0"))
        #expect(!RequestToken.matches("", token))
    }
}
