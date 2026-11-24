import AppKit
import XCTest

@testable import MacEase

@MainActor
final class FinderWindowsSettingsTests: XCTestCase {
    func testCodeFontUsesTheChosenMonospacedFamilyAndSize() {
        XCTAssertTrue(PreviewCodeFont.families.contains("Menlo"))
        XCTAssertFalse(PreviewCodeFont.families.contains("Helvetica"))
        let menlo = PreviewCodeFont.font(family: "Menlo", size: 16)
        XCTAssertEqual(menlo.familyName, "Menlo")
        XCTAssertEqual(menlo.pointSize, 16)
    }

    func testSystemOrMissingFamilyUsesTheSystemMonospacedFont() {
        let system = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        XCTAssertEqual(PreviewCodeFont.font(family: "", size: 14), system)
        XCTAssertEqual(PreviewCodeFont.font(family: "No Such Family 12345", size: 14), system)
    }

    func testAutomationStatusMapsAppleEventPermissionCodes() {
        XCTAssertEqual(FinderPermissionStatus(automation: OSStatus(noErr)), .allowed)
        XCTAssertEqual(FinderPermissionStatus(automation: OSStatus(errAEEventWouldRequireUserConsent)), .notAsked)
        XCTAssertEqual(FinderPermissionStatus(automation: OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(FinderPermissionStatus(automation: OSStatus(procNotFound)), .unknown)
    }

}
