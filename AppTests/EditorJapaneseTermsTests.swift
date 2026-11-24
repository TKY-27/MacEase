import XCTest

@testable import MacEase

extension MediaEditorModelTests {
    /// One Japanese term per editor concept.
    func testEditorJapaneseUsesTheGlossary() {
        let replaced = [
            "区間", "静止フレーム", "再生位置", "BGM", "ミュート", "解析", "切り抜き", "ビデオ", "原画", "表示倍率", "「",
        ]
        let keys = [
            "A freeze frame cannot be reversed. Select a moving segment.", "Add Videos…",
            "Add videos to the end of the timeline", "editor.silence.analyze", "Analyzing sound…",
            "Background Music", "Compare Original", "Crop", "Delete Segment", "Delete Segment (⌫)",
            "Duplicate Segment", "Enter valid markup text first.", "Freeze", "Freeze Duration",
            "More Segment Actions", "Move Segment Left", "Move Segment Right", "Mute", "Mute Preview",
            "No Segments", "Not shown in the edited video. Its range is outside every segment.", "Original",
            "Segment Actions", "Selected Segment", "Set In Point at Playhead", "Set Out Point at Playhead",
            "Source Videos", "Split at Playhead (⌘B)",
            "The selected video segment no longer exists. Select another segment.",
            "There’s no audible sound to analyze in this video.",
            "This segment is already reversed. Restore forward playback first.", "Timeline Zoom", "Unmute",
            "Unmute Preview", "Zoom", "Zoom is unavailable while cropping", "Preview Zoom (⌘+ ⌘− ⌘0, or pinch)",
            "“%@” at %@, %@",
            "Joined videos use the first video's canvas and frame rate. Other sizes fit with black borders. HDR becomes SDR; transparency is flattened. Originals are kept. Metadata may be removed.",
        ]
        let audioTrimKeys = [
            "Waveform", "Go to In Point", "Go to Out Point", "Play", "Pause", "Pause (Space)",
            "Play Selection (Space)", "Playback Rate", "Reverse %@×", "%@×", "Loop Selection", "Zoom Out",
            "Zoom Out (⌘−)", "Timeline Zoom", "Zoom In", "Zoom In (⌘+)", "Fit", "Fit Timeline (⇧Z)", "Start",
            "End", "Set In Point at Playhead (I)", "Set Out Point at Playhead (O)", "Length", "Fade In", "Fade Out",
            "None", "%@ sec", "Fades are longer than the selection.", "Undo", "Undo (⌘Z)", "Redo", "Redo (⇧⌘Z)",
            "Cancel", "Trim", "Playhead", "%@ of %@",
        ]
        for key in keys + audioTrimKeys {
            let value = japanese(key)
            XCTAssertNotEqual(value, "missing", key)
            for term in replaced { XCTAssertFalse(value.contains(term), "\(key) → \(value) uses \(term)") }
        }
        let hints = [
            "Previous Frame (←)", "Next Frame (→)", "Play (Space)", "Pause (Space)", "Play Selection (Space)",
            "Split at Playhead (⌘B)", "Delete Segment (⌫)", "Undo (⌘Z)", "Redo (⇧⌘Z)", "Show Original (M)",
            "Fit Timeline (⇧Z)", "Zoom In (⌘+)", "Zoom Out (⌘−)", "Set In Point at Playhead (I)",
            "Set Out Point at Playhead (O)", "Insert a Freeze Frame at the Playhead (⌥F)",
            "Save Frame at Playhead as an Image (⇧⌘S)",
        ]
        for key in hints {
            let value = japanese(key)
            XCTAssertTrue(value.hasSuffix("）") && !value.contains(" （") && !value.contains(" ("), "\(key) → \(value)")
        }
        XCTAssertEqual(japanese("Play (Space)"), "再生（スペースバー）")
        XCTAssertEqual(japanese("Play Selection (Space)"), "選択範囲を再生（スペースバー）")
        XCTAssertEqual(japanese("Set In Point at Playhead"), "再生ヘッドの位置を開始点に設定")
        XCTAssertEqual(japanese("Set In Point at Playhead (I)"), "再生ヘッドの位置を開始点に設定（I）")
        XCTAssertEqual(japanese("Set Out Point at Playhead (O)"), "再生ヘッドの位置を終了点に設定（O）")
        XCTAssertEqual(japanese("Background Music"), "音楽")
        XCTAssertEqual(japanese("Zoom"), "拡大/縮小")
        XCTAssertEqual(japanese("Zoom Level"), "拡大率")
        XCTAssertEqual(japanese("Mute"), "消音")
        XCTAssertEqual(japanese("Unmute"), "消音を解除")
        XCTAssertEqual(japanese("Mute Preview"), "プレビューを消音")
        XCTAssertEqual(japanese("Unmute Preview"), "プレビューの消音を解除")
        XCTAssertEqual(japanese("editor.silence.analyze"), "分析")
        XCTAssertEqual(japanese("Segment %lld of %lld, %@"), "セグメント %1$lld / %2$lld、%3$@")

        let downloadAnalysisKeys = [
            "Analyze", "Analyze Links (⌘R)", "Stop Analysis", "Analyzing…", "URLs that could not be analyzed",
        ]
        for key in downloadAnalysisKeys {
            let value = japanese(key)
            XCTAssertTrue(value.contains("解析"), "\(key) → \(value)")
            XCTAssertFalse(value.contains("分析"), "\(key) → \(value)")
        }
        XCTAssertEqual(japanese("Analyze"), "解析")
    }
}
