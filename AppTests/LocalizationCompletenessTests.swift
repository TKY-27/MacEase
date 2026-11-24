import Foundation
import XCTest

final class LocalizationCompletenessTests: XCTestCase {
    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let shouldTranslate: Bool?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let value: String
    }

    private static let catalogURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/Resources/Localizable.xcstrings")

    func testEveryCatalogKeyHasJapaneseWithTheSamePlaceholders() throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Self.catalogURL))
        XCTAssertFalse(catalog.strings.isEmpty)
        for (key, entry) in catalog.strings where entry.shouldTranslate != false && !key.isEmpty {
            let english = entry.localizations?["en"]?.stringUnit?.value ?? key
            let japanese = entry.localizations?["ja"]?.stringUnit?.value ?? ""
            XCTAssertFalse(japanese.isEmpty, "no Japanese for \(key)")
            XCTAssertEqual(placeholders(japanese), placeholders(english), "\(key) → \(japanese)")
        }
    }

    func testEveryUsageDescriptionHasEnglishAndJapanese() {
        let plugIns =
            (try? FileManager.default.contentsOfDirectory(
                at: Bundle.main.builtInPlugInsURL ?? Bundle.main.bundleURL, includingPropertiesForKeys: nil)) ?? []
        var checked = 0
        for bundle in [Bundle.main] + plugIns.compactMap(Bundle.init(url:)) {
            let japanese =
                bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "ja")
                .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
            let name = bundle.bundleURL.lastPathComponent
            for (key, english) in bundle.infoDictionary ?? [:]
            where key.hasPrefix("NS") && key.hasSuffix("UsageDescription") {
                checked += 1
                XCTAssertFalse((english as? String ?? "").isEmpty, "\(name) \(key)")
                XCTAssertFalse(japanese[key, default: ""].isEmpty, "\(name) \(key) has no Japanese")
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// Positions may be reordered; kinds and counts must match.
    private func placeholders(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(@|lld|ld|d|lf|f|llu|u)/).map { String($0.output.1) }.sorted()
    }
}
