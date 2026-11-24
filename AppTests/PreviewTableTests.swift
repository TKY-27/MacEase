import AppKit
import Engine
import SwiftUI
import XCTest

@testable import MacEase

@MainActor
final class PreviewTableTests: XCTestCase {
    private func parse(
        _ text: String, _ delimiter: PreviewTable.Delimiter = .comma, maximumDataRows: Int = 100,
        maximumColumns: Int = 100
    ) throws -> PreviewTable {
        try PreviewTable.parse(
            text, delimiter: delimiter, maximumDataRows: maximumDataRows, maximumColumns: maximumColumns)
    }

    func testParsesRFC4180QuotingLineBreaksAndRaggedRows() throws {
        let table = try parse(
            "name,note,score\r\n\"Smith, Jo\",\"said \"\"hi\"\"\",7\n\"multi\r\nline\",,\rshort\nlast,\"x\"y,9")
        XCTAssertEqual(
            table.rows,
            [
                ["name", "note", "score"],
                ["Smith, Jo", "said \"hi\"", "7"],
                ["multi\r\nline", "", ""],
                ["short"],
                ["last", "xy", "9"],
            ])
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.dataRowCount, 4)
        XCTAssertEqual(table.value(row: 3, column: 2), "", "ragged rows read as empty cells")
        XCTAssertFalse(table.rowsClipped)
        XCTAssertFalse(table.columnsClipped)
    }

    func testFinalLineBreakTrailingDelimiterAndUnterminatedQuote() throws {
        XCTAssertEqual(try parse("a,b\n").rows, [["a", "b"]])
        XCTAssertEqual(try parse("a,b\r\n").rows, [["a", "b"]])
        XCTAssertEqual(try parse("a,b,").rows, [["a", "b", ""]])
        XCTAssertEqual(try parse("a\n\nb").rows, [["a"], [""], ["b"]])
        XCTAssertEqual(try parse("a,\"open\nquote").rows, [["a", "open\nquote"]])
        XCTAssertEqual(try parse("").rows, [])
        XCTAssertEqual(try parse("only").rows, [["only"]])
        XCTAssertEqual(try parse("x\ty\n1\t2", .tab).rows, [["x", "y"], ["1", "2"]])
    }

    func testCommaSeparatedFilesUseTheMostFrequentSeparatorOfTheFirstRecord() throws {
        let csv = try XCTUnwrap(PreviewTable.Format(pathExtension: "CSV"))
        let tsv = try XCTUnwrap(PreviewTable.Format(pathExtension: "tsv"))
        XCTAssertNil(PreviewTable.Format(pathExtension: "txt"))
        XCTAssertEqual(csv.delimiter(for: "a,b,c\n1;2;3;4;5"), .comma, "only the first record counts")
        XCTAssertEqual(csv.delimiter(for: "Name;Price;Qty\nApple;1,5;3"), .semicolon)
        XCTAssertEqual(csv.delimiter(for: "Name\tPrice\nApple\t1,5"), .tab)
        XCTAssertEqual(csv.delimiter(for: "\"a;b;c\",d"), .comma, "quoted separators are ignored")
        XCTAssertEqual(csv.delimiter(for: "\"multi\nline;x\";y\n1,2,3,4"), .semicolon)
        XCTAssertEqual(csv.delimiter(for: "a,b;c"), .comma, "ties keep the comma")
        XCTAssertEqual(csv.delimiter(for: "a;b\tc"), .semicolon, "semicolon beats tab on ties")
        XCTAssertEqual(csv.delimiter(for: "single column"), .comma)
        XCTAssertEqual(tsv.delimiter(for: "a,b,c;d;e"), .tab, "tab files always use tabs")
    }

    func testRowAndColumnLimitsClipAndReportOnlyWhenContentRemains() throws {
        let clipped = try parse("h\n1\n2\n3\n", maximumDataRows: 2)
        XCTAssertEqual(clipped.rows, [["h"], ["1"], ["2"]])
        XCTAssertTrue(clipped.rowsClipped)
        let exact = try parse("h\n1\n2\n", maximumDataRows: 2)
        XCTAssertEqual(exact.dataRowCount, 2)
        XCTAssertFalse(exact.rowsClipped)
        let wide = try parse("a,b,c,d\n1,2", maximumColumns: 2)
        XCTAssertEqual(wide.rows, [["a", "b"], ["1", "2"]])
        XCTAssertEqual(wide.columnCount, 2)
        XCTAssertTrue(wide.columnsClipped)
    }

    func testParsingStopsWhenCancelled() async throws {
        let text = String(repeating: "a,b,c\n", count: 10_000)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewTable.parse(text, delimiter: .comma)
        }
        do {
            _ = try await cancelled.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testDecodesThroughTheViewerEncodingPathIncludingByteOrderMarks() throws {
        let directory = try PreviewFixtures.directory(self)
        let shiftJIS = directory.appendingPathComponent("sjis.csv")
        try XCTUnwrap("名前,値\n東京,1\n".data(using: .shiftJIS)).write(to: shiftJIS)
        let bomUTF8 = directory.appendingPathComponent("bom.csv")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("id;label\n1;one".utf8)).write(to: bomUTF8)
        let utf16 = directory.appendingPathComponent("utf16.tsv")
        try (Data([0xFF, 0xFE]) + XCTUnwrap("col\tother\nv\tw".data(using: .utf16LittleEndian))).write(to: utf16)

        func table(_ url: URL, _ encoding: PreviewEncoding) throws -> PreviewTable {
            let rendering = try PreviewTextRendering.make(
                source: try PreviewTextSource.read(url), encoding: encoding, rich: true, kind: .text, url: url,
                restricted: false)
            let format = try XCTUnwrap(PreviewTable.Format(pathExtension: url.pathExtension))
            return try PreviewTable.parse(rendering.text, delimiter: format.delimiter(for: rendering.text))
        }
        XCTAssertEqual(try table(shiftJIS, .shiftJIS).rows, [["名前", "値"], ["東京", "1"]])
        XCTAssertEqual(try table(shiftJIS, .automatic).rows, [["名前", "値"], ["東京", "1"]])
        XCTAssertEqual(try table(bomUTF8, .automatic).rows, [["id", "label"], ["1", "one"]])
        XCTAssertEqual(try table(utf16, .automatic).rows, [["col", "other"], ["v", "w"]])
        XCTAssertNotEqual(try table(shiftJIS, .latin1).rows.first?.first, "名前", "another encoding rebuilds")
    }

    func testSortsNumericColumnsByValueTextNaturallyAndKeepsTiesInFileOrder() throws {
        let table = try parse("file,size,kind\nb10,10,x\nb2,9.5,y\na,,x\nb1,-3,y\nb3,1e2,x")
        XCTAssertEqual(table.numericColumns, [1])
        XCTAssertEqual(try table.order(sortedBy: 1, ascending: true), [3, 4, 2, 1, 5])
        XCTAssertEqual(try table.order(sortedBy: 1, ascending: false), [5, 1, 2, 4, 3])
        XCTAssertEqual(try table.order(sortedBy: 0, ascending: true), [3, 4, 2, 5, 1])
        XCTAssertEqual(try table.order(sortedBy: 2, ascending: true), [1, 3, 5, 2, 4], "ties keep file order")
        XCTAssertEqual(try table.order(sortedBy: 2, ascending: false), [2, 4, 1, 3, 5])
        XCTAssertTrue(try parse("n\n1\nnan").numericColumns.isEmpty, "non-finite values are text")
        XCTAssertTrue(try parse("n\n\n").numericColumns.isEmpty, "empty columns are text")
    }

    func testFindsCellsAndCopiesRawRowsAsTabSeparatedText() throws {
        let table = try parse("a,b\nAlpha,beta\ngamma,ÁLPHA\n\"x\ny\",alp")
        XCTAssertEqual(
            try table.matches(of: "alpha", in: table.fileOrder),
            [PreviewTable.Cell(position: 0, column: 0), PreviewTable.Cell(position: 1, column: 1)])
        XCTAssertEqual(
            try table.matches(of: "alpha", in: [2, 1]),
            [PreviewTable.Cell(position: 0, column: 1), PreviewTable.Cell(position: 1, column: 0)])
        XCTAssertEqual(table.copiedText(rows: [3, 1]), "x\ny\talp\nAlpha\tbeta")
    }

    func testDisplayTextKeepsOneLineAndShowsControlAndDirectionCharacters() {
        XCTAssertEqual(PreviewTable.displayText("a\nb\r\tc\u{7F}"), "a\u{240A}b\u{240D}\u{2409}c\u{2421}")
        XCTAssertEqual(PreviewTable.displayText("abc\u{202E}gpj.exe"), "abc\u{FFFD}gpj.exe")
        XCTAssertEqual(
            PreviewTable.displayText("x\u{2028}\u{2066}\u{200F}\u{85}y"), "x\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}y")
        XCTAssertEqual(PreviewTable.displayText("שלום, 東京"), "שלום, 東京")
        let long = String(repeating: "z", count: PreviewTable.maximumCellDisplayLength + 10)
        XCTAssertEqual(PreviewTable.displayText(long), String(long.prefix(PreviewTable.maximumCellDisplayLength)) + "…")
    }

    func testTableViewShowsHeadersFindsRowsSortsInThreeStepsAndCopies() async throws {
        let view = PreviewTableView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))
        scroll.documentView = view
        view.show(try parse("city,population\nOsaka,2.7\nkyoto,1.4\nTOKYO,14\nNara,"))
        XCTAssertEqual(view.tableColumns.map(\.title), ["city", "population"])
        XCTAssertEqual(view.numberOfRows, 4)
        XCTAssertEqual(view.tableColumns[1].headerCell.alignment, .right, "numeric columns align right")
        XCTAssertEqual(view.accessibilityLabel(), String(localized: "Table"))
        XCTAssertTrue(view.needsPanelToBecomeKey)
        let cell = view.tableView(view, viewFor: view.tableColumns[0], row: 2) as? NSTableCellView
        XCTAssertEqual(cell?.textField?.stringValue, "TOKYO")

        let first = await view.find("o", direction: .forward, restart: true)
        XCTAssertEqual(first, PreviewFindOutcome(found: true, current: 1, total: 3))
        XCTAssertEqual(view.selectedRow, 0)
        let next = await view.find("o", direction: .forward, restart: false)
        XCTAssertEqual(next.current, 2)
        XCTAssertEqual(view.selectedRow, 1)
        let wrapped = await view.find("o", direction: .backward, restart: false)
        XCTAssertEqual(wrapped.current, 1)
        let missing = await view.find("zzz", direction: .forward, restart: true)
        XCTAssertEqual(missing, .notFound)

        let ascending = NSSortDescriptor(key: "1", ascending: true)
        view.sortDescriptors = [ascending]
        let sortedUp = try await PreviewFixtures.waitUntil { view.order == [4, 2, 1, 3] }
        XCTAssertTrue(sortedUp)
        view.sortDescriptors = [NSSortDescriptor(key: "1", ascending: false)]
        let sortedDown = try await PreviewFixtures.waitUntil { view.order == [3, 1, 2, 4] }
        XCTAssertTrue(sortedDown)
        view.sortDescriptors = [ascending]
        let restored = try await PreviewFixtures.waitUntil { view.order == [1, 2, 3, 4] }
        XCTAssertTrue(restored, "the third click returns to file order")
        XCTAssertTrue(view.sortDescriptors.isEmpty)

        view.selectRowIndexes([0, 2], byExtendingSelection: false)
        preservingPasteboard {
            view.copy(nil)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Osaka\t2.7\nTOKYO\t14")
        }
    }

    func testCSVOpensAsTableSwitchesToSourceAndTheNextFileOpensAsTableAgain() async throws {
        let directory = try PreviewFixtures.directory(self)
        let firstFile = directory.appendingPathComponent("first.csv")
        let secondFile = directory.appendingPathComponent("second.tsv")
        try Data("fruit;count\napple;3".utf8).write(to: firstFile)
        try Data("planet\tmoons\nmars\t2".utf8).write(to: secondFile)
        let suite = "PreviewTableTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = FinderPreviewState()
        state.urls = [firstFile]
        state.kind = .text
        state.trust = PreviewTrust(level: .standard, resolvedPath: firstFile.path)
        state.generation = 1
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: SettingsStore(defaults: defaults),
                staging: StagingArea(supportDirectory: directory), close: {}, retry: {}, select: { _ in },
                resize: { _ in }))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        func headers() -> [String]? {
            PreviewFindTests.first(PreviewTableView.self, in: content)?.tableColumns.map(\.title)
        }

        let firstShown = try await PreviewFixtures.waitUntil { headers() == ["fruit", "count"] }
        XCTAssertTrue(firstShown, "semicolon CSV opens as a table")
        let picker = try XCTUnwrap(PreviewFindTests.first(NSSegmentedControl.self, in: content))
        picker.selectedSegment = 1
        picker.sendAction(picker.action, to: picker.target)
        let sourceShown = try await PreviewFixtures.waitUntil {
            PreviewFindTests.first(PreviewTextView.self, in: content)?.string == "fruit;count\napple;3"
                && headers() == nil
        }
        XCTAssertTrue(sourceShown)

        state.urls = [secondFile]
        state.trust = PreviewTrust(level: .standard, resolvedPath: secondFile.path)
        state.generation += 1
        let secondShown = try await PreviewFixtures.waitUntil { headers() == ["planet", "moons"] }
        XCTAssertTrue(secondShown, "the next file opens in Table mode again")
    }

    func testANewRenderingNeverShowsThePreviousTable() async throws {
        let directory = try PreviewFixtures.directory(self)
        func rendering(_ name: String, _ text: String) throws -> PreviewTextRendering {
            let file = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: file)
            return try PreviewTextRendering.make(
                source: try PreviewTextSource.read(file), encoding: .automatic, rich: true, kind: .text, url: file,
                restricted: false)
        }
        let first = try rendering("first.csv", "old,header\n1,2")
        let second = try rendering("second.csv", "new,header\n3,4")
        let find = PreviewFind()
        let host = NSHostingView(rootView: PreviewTableViewer(rendering: first, format: .commaSeparated, find: find))
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func headers() -> [String]? {
            PreviewFindTests.first(PreviewTableView.self, in: host)?.tableColumns.map(\.title)
        }
        let firstShown = try await PreviewFixtures.waitUntil { headers() == ["old", "header"] }
        XCTAssertTrue(firstShown)

        host.rootView = PreviewTableViewer(rendering: second, format: .commaSeparated, find: find)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(headers(), ["old", "header"], "a stale table is hidden at once")
        let secondShown = try await PreviewFixtures.waitUntil { headers() == ["new", "header"] }
        XCTAssertTrue(secondShown)
    }

    func testLargeCSVStartsInSourceAndRefusesThePartialTable() async throws {
        let directory = try PreviewFixtures.directory(self)
        let file = directory.appendingPathComponent("large.csv")
        let line = "alpha,beta,gamma,delta\n"
        let repeats = PreviewTextSource.maximumBytes / line.utf8.count + 1
        try Data(String(repeating: line, count: repeats).utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: PreviewTextViewer(
                url: file, kind: .text, trust: PreviewTrust(level: .standard, resolvedPath: file.path),
                settings: FinderPreviewSettings(), scriptConsent: .constant([])))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        let sourceShown = try await PreviewFixtures.waitUntil {
            PreviewFindTests.first(PreviewTextView.self, in: content) != nil
        }
        XCTAssertTrue(sourceShown, "files over the read limit open in Source")
        let picker = try XCTUnwrap(PreviewFindTests.first(NSSegmentedControl.self, in: content))
        XCTAssertEqual(picker.selectedSegment, 1)
        picker.selectedSegment = 0
        picker.sendAction(picker.action, to: picker.target)
        let refused = try await PreviewFixtures.waitUntil {
            PreviewFindTests.first(PreviewTextView.self, in: content) == nil
        }
        XCTAssertTrue(refused, "Table mode replaces the source with the size reason")
        XCTAssertNil(PreviewFindTests.first(PreviewTableView.self, in: content), "no partial table is built")
    }

    // Copy writes the shared pasteboard.
    private func preservingPasteboard(_ body: () -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            let copy = NSPasteboardItem()
            for type in pasteboardItem.types {
                if let bytes = pasteboardItem.data(forType: type) { copy.setData(bytes, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        body()
    }
}
