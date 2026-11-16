import Engine
import XCTest

@testable import MacEase

@MainActor
final class PreviewTextEditorTests: XCTestCase {
    private func loadedEditor() throws -> (PreviewTextEditor, URL, FileStamp) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.txt")
        try Data("original\r\n".utf8).write(to: url)
        let source = try PreviewTextSource.read(url)
        let editor = PreviewTextEditor()
        try editor.begin(url: url, source: source, encoding: .automatic)
        return (editor, url, try XCTUnwrap(source.stamp))
    }

    func testBinaryTruncatedAndUndecodableSourcesCannotEnterEditing() throws {
        let (_, url, stamp) = try loadedEditor()
        for source in [
            PreviewTextSource(bytes: Data("bplist00".utf8), truncated: false, stamp: stamp),
            PreviewTextSource(bytes: Data("excerpt".utf8), truncated: true, stamp: stamp),
        ] {
            let editor = PreviewTextEditor()
            try editor.begin(url: url, source: source, encoding: .automatic)
            XCTAssertFalse(editor.editing)
        }
        let editor = PreviewTextEditor()
        XCTAssertThrowsError(
            try editor.begin(
                url: url,
                source: PreviewTextSource(bytes: Data([0xFF]), truncated: false, stamp: stamp), encoding: .utf8))
        XCTAssertFalse(editor.editing)
    }

    func testDirtyBufferPinsSelectionAndDiscardRestoresLoadedText() throws {
        let (editor, url, stamp) = try loadedEditor()
        XCTAssertFalse(editor.dirty)
        editor.buffer = "edited\r\n"
        XCTAssertTrue(editor.pinsSelection)
        editor.reset()
        XCTAssertEqual(editor.buffer, "edited\r\n")
        XCTAssertEqual(editor.url, url)
        editor.discard()
        XCTAssertEqual(editor.buffer, "original\r\n")
        XCTAssertEqual(editor.stamp, stamp)
        XCTAssertFalse(editor.dirty)
        XCTAssertFalse(editor.pinsSelection)
    }

    func testSavingPreventsDiscardAndFailureRetainsBufferAndStamp() throws {
        let (editor, _, stamp) = try loadedEditor()
        editor.buffer = "edited"
        XCTAssertNotNil(editor.prepareSave())
        XCTAssertNil(editor.prepareSave())
        editor.discard()
        XCTAssertEqual(editor.buffer, "edited")
        XCTAssertFalse(editor.finishSave(.skipped(.changedSinceScan), stamp: nil, historyFailed: false, asUTF8: false))
        XCTAssertTrue(editor.dirty)
        XCTAssertFalse(editor.saving)
        XCTAssertEqual(editor.stamp, stamp)
        XCTAssertNotNil(editor.message)
    }

    func testSuccessfulSaveChangesBaselineAndRevertKeepsSavedText() throws {
        let (editor, url, _) = try loadedEditor()
        editor.buffer = "saved"
        try Data("saved".utf8).write(to: url)
        let committedStamp = try FileStamp(of: url)
        try Data("changed after commit".utf8).write(to: url)
        XCTAssertNotNil(editor.prepareSave())
        XCTAssertTrue(
            editor.finishSave(
                .succeeded(outputs: [url], warnings: []), stamp: committedStamp, historyFailed: false, asUTF8: false))
        XCTAssertEqual(editor.stamp, committedStamp)
        XCTAssertFalse(editor.dirty)
        editor.buffer = "later"
        editor.discard()
        XCTAssertEqual(editor.buffer, "saved")
    }

    func testEncodingFailureOffersExplicitUTF8WithoutDiscardingText() throws {
        let (editor, _, stamp) = try loadedEditor()
        editor.buffer = "😀"
        XCTAssertNotNil(editor.prepareSave())
        XCTAssertFalse(
            editor.finishSave(
                .failed(.invalidInput(.textEditUnrepresentable)), stamp: nil, historyFailed: false, asUTF8: false))
        XCTAssertTrue(editor.offersUTF8)
        XCTAssertEqual(editor.buffer, "😀")
        XCTAssertEqual(editor.stamp, stamp)
        XCTAssertNotNil(editor.prepareSave(asUTF8: true))
    }

    func testDerivedFallbackAndHistoryFailureKeepUnsavedState() throws {
        let (editor, url, stamp) = try loadedEditor()
        editor.buffer = "edited"
        XCTAssertNotNil(editor.prepareSave())
        XCTAssertFalse(
            editor.finishSave(
                .succeeded(outputs: [url.appendingPathExtension("copy")], warnings: [.keptAsDerived]), stamp: nil,
                historyFailed: false, asUTF8: false))
        XCTAssertTrue(editor.dirty)
        XCTAssertNotNil(editor.prepareSave())
        XCTAssertFalse(
            editor.finishSave(
                .succeeded(outputs: [url], warnings: []), stamp: stamp, historyFailed: true, asUTF8: false))
        XCTAssertTrue(editor.dirty)
        editor.confirming = true
        editor.discard()
        XCTAssertTrue(editor.pinsSelection)
        editor.confirming = false
        XCTAssertFalse(editor.pinsSelection)
    }
}
