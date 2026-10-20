import Foundation
import MenuCatalog

/// Titles follow the app's language setting.
enum MenuStrings {
    static let titles = MenuTitles(operation: operation, preset: preset, kind: kind)

    static func operation(_ op: OperationID) -> String {
        lookup("menu.op.\(op.rawValue)")
    }

    static func preset(_ op: OperationID, _ preset: String) -> String {
        if preset == MenuEntry.customPreset, op != .videoThumbnail { return lookup("menu.custom") }
        return lookup("menu.preset.\(op.rawValue).\(preset)")
    }

    static func kind(_ kind: FileKind) -> String {
        lookup("menu.kind.\(kind.rawValue)")
    }

    private static func lookup(_ key: String) -> String {
        let value = String(localized: String.LocalizationValue(key))
        assert(value != key, "Missing localization for \(key)")
        return value
    }
}
