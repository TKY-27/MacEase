import XCTest

@testable import MacEase

@MainActor
final class SettingsSidebarTests: XCTestCase {
    func testSidebarGroupsIntegrationFileKindsAutomationAndMaintenance() {
        XCTAssertEqual(
            SettingsPage.sidebarSections,
            [
                [.general, .finderMenu, .finderWindows, .folderAccess],
                [.images, .video, .audio, .text, .folders, .intelligence],
                [.organization, .recipes],
                [.advanced, .about],
            ])
    }

    func testEveryPageIsReachableExactlyOnceInEnumOrder() {
        XCTAssertEqual(SettingsPage.sidebarSections.flatMap(\.self), SettingsPage.allCases)
        XCTAssertEqual(Set(SettingsPage.allCases.map(\.title)).count, SettingsPage.allCases.count)
        XCTAssertEqual(SettingsPage.text.title, String(localized: "Text & PDF", comment: "Settings page"))
    }
}
