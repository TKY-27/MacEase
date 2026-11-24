import XCTest

@testable import MacEase

final class FinderPreviewGeometryTests: XCTestCase {
    func testAXCoordinatesUsePrimaryScreenTopOnEveryDisplay() {
        let rectangles = [
            (CGRect(x: 100, y: 80, width: 900, height: 600), CGRect(x: 100, y: 400, width: 900, height: 600)),
            (CGRect(x: -1600, y: 180, width: 800, height: 700), CGRect(x: -1600, y: 200, width: 800, height: 700)),
            (CGRect(x: 100, y: -900, width: 800, height: 700), CGRect(x: 100, y: 1280, width: 800, height: 700)),
            (CGRect(x: 1920, y: 1200, width: 800, height: 700), CGRect(x: 1920, y: -820, width: 800, height: 700)),
        ]
        for (axFrame, expected) in rectangles {
            XCTAssertEqual(FinderPreviewGeometry.appKitFrame(axFrame: axFrame, primaryScreenTop: 1080), expected)
        }
    }

    func testRightDockPreservesWindowTopAndHeight() {
        let placement = FinderPreviewGeometry.placement(
            window: CGRect(x: 100, y: 200, width: 900, height: 700),
            screen: CGRect(x: 0, y: 30, width: 1600, height: 950), width: 360)
        XCTAssertEqual(placement.dock, .right)
        XCTAssertEqual(placement.frame, CGRect(x: 1000, y: 200, width: 360, height: 700))
    }

    func testRightEdgeFallsBackToLeftOnSecondaryDisplay() {
        let placement = FinderPreviewGeometry.placement(
            window: CGRect(x: -1200, y: -200, width: 1100, height: 800),
            screen: CGRect(x: -1600, y: -300, width: 1600, height: 1000), width: 360)
        XCTAssertEqual(placement.dock, .left)
        XCTAssertEqual(placement.frame, CGRect(x: -1560, y: -200, width: 360, height: 800))
    }

    func testFullWidthWindowUsesInsetInsteadOfLeavingScreen() {
        let placement = FinderPreviewGeometry.placement(
            window: CGRect(x: 0, y: 30, width: 1600, height: 950),
            screen: CGRect(x: 0, y: 30, width: 1600, height: 950), width: 360)
        XCTAssertEqual(placement.dock, .inset)
        XCTAssertEqual(placement.frame, CGRect(x: 1240, y: 30, width: 360, height: 950))
    }

    func testWidthIsClampedBeforeChoosingDock() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let window = CGRect(x: 100, y: 100, width: 600, height: 700)
        let narrow = FinderPreviewGeometry.placement(window: window, screen: screen, width: 100)
        let wide = FinderPreviewGeometry.placement(window: window, screen: screen, width: 2000)
        XCTAssertEqual(narrow.frame.width, 280)
        XCTAssertEqual(wide.frame.width, 800)
        XCTAssertEqual(wide.frame.minX, 700)
    }

    func testExactRightFitDoesNotFallBackToLeft() {
        let placement = FinderPreviewGeometry.placement(
            window: CGRect(x: 300, y: 20, width: 940, height: 800),
            screen: CGRect(x: 0, y: 20, width: 1600, height: 950), width: 360)
        XCTAssertEqual(placement.dock, .right)
        XCTAssertEqual(placement.frame.maxX, 1600)
    }

    func testDraggingTheFreeEdgeFollowsThePointer() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let window = CGRect(x: 100, y: 100, width: 800, height: 700)
        let right = FinderPreviewGeometry.placement(window: window, screen: screen, width: 360)
        XCTAssertEqual(right.dock, .right)
        XCTAssertEqual(
            FinderPreviewGeometry.resizedWidth(right, pointerDelta: 40, window: window, screen: screen), 400)
        let leftWindow = CGRect(x: 700, y: 100, width: 900, height: 700)
        let left = FinderPreviewGeometry.placement(window: leftWindow, screen: screen, width: 360)
        XCTAssertEqual(left.dock, .left)
        XCTAssertEqual(
            FinderPreviewGeometry.resizedWidth(left, pointerDelta: -40, window: leftWindow, screen: screen), 400)
        let fullWindow = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let inset = FinderPreviewGeometry.placement(window: fullWindow, screen: screen, width: 360)
        XCTAssertEqual(inset.dock, .inset)
        XCTAssertEqual(
            FinderPreviewGeometry.resizedWidth(inset, pointerDelta: -40, window: fullWindow, screen: screen), 400)
    }

    func testResizingKeepsTheCurrentDockSide() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let window = CGRect(x: 100, y: 100, width: 1050, height: 700)
        let right = FinderPreviewGeometry.placement(window: window, screen: screen, width: 360)
        XCTAssertEqual(right.dock, .right)
        XCTAssertEqual(
            FinderPreviewGeometry.resizedWidth(right, pointerDelta: 300, window: window, screen: screen), 450)
        XCTAssertEqual(
            FinderPreviewGeometry.resizedWidth(right, pointerDelta: -300, window: window, screen: screen), 280)
        let fullWindow = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let inset = FinderPreviewGeometry.placement(window: fullWindow, screen: screen, width: 360)
        XCTAssertEqual(
            FinderPreviewGeometry.resizedWidth(inset, pointerDelta: -2000, window: fullWindow, screen: screen), 800)
    }
}
