import XCTest

@testable import MacEase

final class PreviewTextDecorationTests: XCTestCase {
    func testTableHidesTheSameCharactersTheSourceViewMarks() {
        XCTAssertEqual(PreviewTable.displayText("a\u{3164}b\u{180E}c"), "a\u{FFFD}b\u{FFFD}c")
        XCTAssertEqual(PreviewTable.displayText("id\u{200D}x"), "id\u{FFFD}x")
        let hebrew = "שלום \u{200F}עולם"
        XCTAssertEqual(PreviewTable.displayText(hebrew), hebrew, "marks in right-to-left text stay")
        let persian = "کتاب\u{200C}ها"
        XCTAssertEqual(PreviewTable.displayText(persian), persian)
    }
}
