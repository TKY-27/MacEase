import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import MacEase

final class FinderPreviewSettingsTests: XCTestCase {
    func testDefaultsMatchSpecification() {
        let settings = FinderPreviewSettings()
        XCTAssertTrue(settings.disabledKinds.isEmpty)
        XCTAssertEqual(settings.codeFontFamily, "")
        XCTAssertEqual(settings.codeFontSize, 12)
        XCTAssertTrue(settings.wrapLines)
        XCTAssertEqual(settings.fontSampleText, "")
        XCTAssertEqual(settings.effectiveFontSampleText, FinderPreviewSettings.defaultFontSampleText)
        XCTAssertTrue(settings.trustedFolders.isEmpty)
    }

    func testCodeFontSizeIsClampedToValidRange() {
        XCTAssertEqual(FinderPreviewSettings(codeFontSize: 4).codeFontSize, 9)
        XCTAssertEqual(FinderPreviewSettings(codeFontSize: 9).codeFontSize, 9)
        XCTAssertEqual(FinderPreviewSettings(codeFontSize: 24).codeFontSize, 24)
        XCTAssertEqual(FinderPreviewSettings(codeFontSize: 40).codeFontSize, 24)

        var settings = FinderPreviewSettings()
        settings.codeFontSize = 2
        XCTAssertEqual(settings.codeFontSize, 9)
        settings.codeFontSize = 99
        XCTAssertEqual(settings.codeFontSize, 24)
    }

    func testTrustedFoldersAreStandardizedAndDeduplicated() {
        var settings = FinderPreviewSettings(trustedFolders: [
            "/tmp/alpha/../beta/",
            "/tmp/beta",
            "   ",
            "/tmp/gamma/./sub/",
        ])
        XCTAssertEqual(settings.trustedFolders, ["/tmp/beta", "/tmp/gamma/sub"])

        settings.addTrustedFolder(URL(fileURLWithPath: "/tmp/beta/"))
        XCTAssertEqual(settings.trustedFolders, ["/tmp/beta", "/tmp/gamma/sub"])

        settings.addTrustedFolder(URL(fileURLWithPath: "/tmp/delta/nested/.."))
        XCTAssertEqual(settings.trustedFolders, ["/tmp/beta", "/tmp/gamma/sub", "/tmp/delta"])

        settings.removeTrustedFolder("/tmp/gamma/sub/")
        XCTAssertEqual(settings.trustedFolders, ["/tmp/beta", "/tmp/delta"])
    }

    func testEffectiveFontSampleTextUsesCustomNonBlankText() {
        var settings = FinderPreviewSettings(fontSampleText: "   \n\t ")
        XCTAssertEqual(settings.effectiveFontSampleText, FinderPreviewSettings.defaultFontSampleText)
        settings.fontSampleText = "Pack my box"
        XCTAssertEqual(settings.effectiveFontSampleText, "Pack my box")
    }

    func testMigrationSafeDecodingHandlesMissingUnknownAndOutOfRangeValues() throws {
        let emptyDecoded = try FinderPreviewSettings.decode(Data("{}".utf8))
        XCTAssertEqual(emptyDecoded, FinderPreviewSettings())

        let partial = Data(
            """
            {
              "disabledKinds": ["svg", "futureKind", "font"],
              "codeFontSize": 72,
              "wrapLines": false,
              "trustedFolders": ["/tmp/a/../b/", "/tmp/b"],
              "unknownFutureKey": 123
            }
            """.utf8)
        let migrated = try FinderPreviewSettings.decode(partial)
        XCTAssertEqual(migrated.disabledKinds, [.svg, .font])
        XCTAssertEqual(migrated.codeFontFamily, "")
        XCTAssertEqual(migrated.codeFontSize, 24)
        XCTAssertFalse(migrated.wrapLines)
        XCTAssertEqual(migrated.fontSampleText, "")
        XCTAssertEqual(migrated.trustedFolders, ["/tmp/b"])

        XCTAssertThrowsError(try FinderPreviewSettings.decode(Data(#"{"wrapLines":"yes"}"#.utf8)))
    }

    @MainActor
    func testSettingsStorePersistsResetsAndPreservesUnreadableFinderPreviewSettings() throws {
        let suite = "FinderPreviewSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.finderPreview, FinderPreviewSettings())

        store.finderPreview.disabledKinds = [.svg, .audio]
        store.finderPreview.codeFontFamily = "Menlo"
        store.finderPreview.codeFontSize = 15
        store.finderPreview.wrapLines = false
        store.finderPreview.fontSampleText = "Hello 123"
        store.finderPreview.addTrustedFolder(URL(fileURLWithPath: "/tmp/docs/"))

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.finderPreview, store.finderPreview)

        reloaded.resetAll()
        XCTAssertEqual(SettingsStore(defaults: defaults).finderPreview, FinderPreviewSettings())

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: FinderPreviewSettings.defaultsKey)
        let recovered = SettingsStore(defaults: defaults)
        XCTAssertEqual(recovered.finderPreview, FinderPreviewSettings())
        XCTAssertEqual(defaults.data(forKey: "finderPreview.settings.unreadable"), corrupt)
    }

    func testDisabledKindsResolveToQuickLookIncludingSVGAndFonts() throws {
        let cases: [(UTType?, String, PreviewKind, FinderPreviewFileType)] = [
            (.plainText, "txt", .text, .text),
            (.json, "json", .json, .text),
            (.propertyList, "plist", .propertyList, .text),
            (.html, "html", .html, .html),
            (.plainText, "md", .markdown, .markdown),
            (.svg, "svg", .svg, .svg),
            (.pdf, "pdf", .pdf, .pdf),
            (.font, "ttf", .font, .font),
            (nil, "otf", .font, .font),
            (nil, "ttc", .font, .font),
            (nil, "otc", .font, .font),
            (nil, "woff", .font, .font),
            (nil, "woff2", .font, .font),
            (.png, "png", .image, .image),
            (.movie, "mov", .media, .video),
            (.audio, "wav", .audio, .audio),
        ]
        for (type, suffix, expected, toggle) in cases {
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix), expected, suffix)
            XCTAssertEqual(PreviewKind.resolve(type: type, extension: suffix, disabled: [toggle]), .quickLook, suffix)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        try Data("# hi".utf8).write(to: note)
        XCTAssertEqual(try PreviewKind.inspect(note), .markdown)
        XCTAssertEqual(try PreviewKind.inspect(note, disabled: [.markdown]), .quickLook)
    }
}
