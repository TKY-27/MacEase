import XCTest

@testable import MacEase

extension MediaEditorModelTests {
    /// One Japanese term per editor concept.
    func testEditorJapaneseUsesTheGlossary() {
        let replaced = ["区間", "静止フレーム", "再生位置", "BGM", "消音", "解析", "切り抜き", "ビデオ", "原画", "表示倍率", "「"]
        let keys = [
            "A freeze frame cannot be reversed. Select a moving segment.", "Add Videos…",
            "Add videos to the end of the timeline", "Analyze", "Background Music", "Compare Original", "Crop",
            "Delete Segment", "Delete Segment (⌫)", "Duplicate Segment", "Freeze", "Freeze Duration",
            "More Segment Actions", "Move Segment Left", "Move Segment Right", "Mute Preview", "No Segments",
            "Not shown in the edited video. Its range is outside every segment.", "Original", "Segment Actions",
            "Selected Segment", "Set In Point at Playhead", "Set Out Point at Playhead", "Source Videos",
            "Split at Playhead (⌘B)", "The selected video segment no longer exists. Select another segment.",
            "This segment is already reversed. Restore forward playback first.", "Timeline Zoom", "Unmute",
            "Unmute Preview", "Zoom", "Zoom is unavailable while cropping", "Preview Zoom (⌘+ ⌘− ⌘0, or pinch)",
            "“%@” at %@, %@",
            "Joined videos use the first video's canvas and frame rate. Other sizes fit with black borders. HDR becomes SDR; transparency is flattened. Originals are kept. Metadata may be removed.",
        ]
        for key in keys {
            let value = japanese(key)
            XCTAssertNotEqual(value, "missing", key)
            for term in replaced { XCTAssertFalse(value.contains(term), "\(key) → \(value) uses \(term)") }
        }
        let hints = [
            "Previous Frame (←)", "Next Frame (→)", "Play (Space)", "Pause (Space)", "Split at Playhead (⌘B)",
            "Delete Segment (⌫)", "Undo (⌘Z)", "Redo (⇧⌘Z)", "Show Original (M)", "Fit Timeline (⇧Z)",
            "Insert a Freeze Frame at the Playhead (⌥F)", "Save Frame at Playhead as an Image (⇧⌘S)",
        ]
        for key in hints {
            let value = japanese(key)
            XCTAssertTrue(value.hasSuffix("）") && !value.contains(" （"), "\(key) → \(value)")
        }
        XCTAssertEqual(japanese("Play (Space)"), "再生（スペースバー）")
        XCTAssertEqual(japanese("Set In Point at Playhead"), "再生ヘッドの位置を開始点に設定")
        XCTAssertEqual(japanese("Background Music"), "音楽")
        XCTAssertEqual(japanese("Zoom"), "拡大/縮小")
        XCTAssertEqual(japanese("Zoom Level"), "拡大率")
        XCTAssertEqual(japanese("Segment %lld of %lld, %@"), "セグメント %1$lld / %2$lld、%3$@")
    }
}
