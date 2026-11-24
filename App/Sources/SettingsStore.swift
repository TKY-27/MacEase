import Engine
import Foundation
import MenuCatalog
import Observation
import os

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let legacyHiddenOperations = "hiddenOperations"
        static let hiddenEntries = "hiddenMenuEntries"
        static let notificationsEnabled = "notificationsEnabled"
        static let onboardingCompleted = "onboardingCompleted"
        static let language = "language"
        static let appleLanguages = "AppleLanguages"
        static let unreadableSettings = "settings.unreadable"
        static let showsActivity = "activity.shows"
        static let activityV22Migrated = "activity.v22Migrated"
        static let menuPlacements = "menuPlacements"
        static let activityClosesAfterSuccess = "activity.closesAfterSuccess"
        static let activityClosesAfterCancel = "activity.closesAfterCancel"
        static let activityClosesAfterFailure = "activity.closesAfterFailure"
        static let finderPreviewEnabled = "finderPreview.enabled"
    }

    enum Language: String, CaseIterable, Identifiable {
        case system
        case english = "en"
        case japanese = "ja"

        var id: String { rawValue }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(category: "settings")
    @ObservationIgnored var onChange: (() -> Void)?

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?()
        }
    }

    /// `op/preset` keys; `op/` for operations without presets.
    var hiddenEntries: Set<String> {
        didSet {
            guard hiddenEntries != oldValue else { return }
            defaults.set(hiddenEntries.sorted(), forKey: Key.hiddenEntries)
            onChange?()
        }
    }

    var menuPlacements: [String: MenuPlacement] {
        didSet {
            guard menuPlacements != oldValue else { return }
            defaults.set(menuPlacements.mapValues(\.rawValue), forKey: Key.menuPlacements)
            onChange?()
        }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    var showsActivity: Bool {
        didSet { defaults.set(showsActivity, forKey: Key.showsActivity) }
    }

    var activityClosesAfterSuccess: Bool {
        didSet { defaults.set(activityClosesAfterSuccess, forKey: Key.activityClosesAfterSuccess) }
    }

    var activityClosesAfterCancel: Bool {
        didSet { defaults.set(activityClosesAfterCancel, forKey: Key.activityClosesAfterCancel) }
    }

    var activityClosesAfterFailure: Bool {
        didSet { defaults.set(activityClosesAfterFailure, forKey: Key.activityClosesAfterFailure) }
    }

    var finderPreviewEnabled: Bool {
        didSet { defaults.set(finderPreviewEnabled, forKey: Key.finderPreviewEnabled) }
    }

    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    var language: Language {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            if language == .system {
                defaults.removeObject(forKey: Key.appleLanguages)
            } else {
                defaults.set([language.rawValue], forKey: Key.appleLanguages)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.notificationsEnabled: true, Key.showsActivity: true, Key.activityClosesAfterSuccess: true,
            Key.activityClosesAfterCancel: true, Key.activityClosesAfterFailure: false,
        ])
        settings = Self.decodeSettings(from: defaults)
        var hidden = Self.loadHiddenEntries(from: defaults)
        if hidden.remove("video.trim/") != nil {
            hidden.insert(OperationID.videoEdit.menuEntryKey(""))
        }
        let removed: Set<String> = [
            "video.trim", "text.edit", "image.copyBase64", "any.sourceInfo", "image.aiCustom", "video.aiCustom",
            "audio.aiCustom",
        ]
        hidden = hidden.filter { !removed.contains(String($0.prefix { $0 != "/" })) }
        defaults.set(hidden.sorted(), forKey: Key.hiddenEntries)
        defaults.removeObject(forKey: Key.legacyHiddenOperations)
        defaults.removeObject(forKey: "menu.sourceInspectorV3Migrated")
        hiddenEntries = hidden
        menuPlacements = (defaults.dictionary(forKey: Key.menuPlacements) as? [String: String] ?? [:])
            .compactMapValues(MenuPlacement.init(rawValue:))
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        if !defaults.bool(forKey: Key.activityV22Migrated) {
            defaults.set(true, forKey: Key.showsActivity)
            defaults.set(true, forKey: Key.activityV22Migrated)
        }
        showsActivity = defaults.bool(forKey: Key.showsActivity)
        activityClosesAfterSuccess = defaults.bool(forKey: Key.activityClosesAfterSuccess)
        activityClosesAfterCancel = defaults.bool(forKey: Key.activityClosesAfterCancel)
        activityClosesAfterFailure = defaults.bool(forKey: Key.activityClosesAfterFailure)
        finderPreviewEnabled = defaults.bool(forKey: Key.finderPreviewEnabled)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        language = Language(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
    }

    /// History and edited presets survive.
    func resetAll() {
        settings = Settings()
        hiddenEntries = Self.newInstallHiddenEntries
        menuPlacements = [:]
        notificationsEnabled = true
        showsActivity = true
        activityClosesAfterSuccess = true
        activityClosesAfterCancel = true
        activityClosesAfterFailure = false
        finderPreviewEnabled = false
    }

    /// SPEC 4.4 defaults for new installs.
    private static let newInstallHiddenEntries: Set<String> = [
        OperationID.imageResize.menuEntryKey("long-3840"), OperationID.imageResize.menuEntryKey("long-2560"),
        OperationID.imageConvert.menuEntryKey("bmp"), OperationID.imageConvert.menuEntryKey("ico"),
        OperationID.imageConvert.menuEntryKey("icns"),
        OperationID.videoResize.menuEntryKey("2160p"), OperationID.videoCompress.menuEntryKey("mb-100"),
        OperationID.videoConvert.menuEntryKey("m4v"), OperationID.videoConvert.menuEntryKey("avi"),
        OperationID.videoConvert.menuEntryKey("flv"), OperationID.videoToAPNG.menuEntryKey("settings"),
        OperationID.videoExtractAudio.menuEntryKey("aiff"), OperationID.videoExtractAudio.menuEntryKey("ogg"),
        OperationID.videoExtractAudio.menuEntryKey("opus"),
        OperationID.anyChecksum.menuEntryKey("sha1"), OperationID.anyChecksum.menuEntryKey("sha512"),
    ]

    /// Existing installs keep their visibility.
    private static func loadHiddenEntries(from defaults: UserDefaults) -> Set<String> {
        if let stored = defaults.stringArray(forKey: Key.hiddenEntries) { return Set(stored) }
        let legacy = defaults.stringArray(forKey: Key.legacyHiddenOperations)
        let isExistingInstall =
            legacy != nil || defaults.object(forKey: Settings.defaultsKey) != nil
            || defaults.bool(forKey: Key.onboardingCompleted)
            || FileManager.default.fileExists(atPath: HostConfiguration.current.menuFile.path)
        let entries =
            isExistingInstall
            ? Set((legacy ?? []).compactMap(OperationID.init).flatMap(\.menuEntryKeys)) : newInstallHiddenEntries
        var migrated = entries
        if legacy?.contains("video.trim") == true { migrated.insert("video.trim/") }
        defaults.set(migrated.sorted(), forKey: Key.hiddenEntries)
        return migrated
    }

    /// Settings with the user's edited presets.
    var planning: Settings {
        var resolved = settings
        do {
            resolved.platformPresets = try PresetLibrary(
                supportDirectory: HostConfiguration.current.supportDirectory
            ).presets()
        } catch {
            let failure = error as NSError
            logger.error(
                "Edited presets unreadable, using defaults (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
        }
        return resolved
    }

    /// Unreadable settings are kept aside, never overwritten.
    private static func decodeSettings(from defaults: UserDefaults) -> Settings {
        guard let stored = defaults.data(forKey: Settings.defaultsKey) else { return Settings() }
        do {
            return try Settings.decode(stored)
        } catch {
            let failure = error as NSError
            Logger(category: "settings")
                .error(
                    "Stored settings unreadable, using defaults (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                )
            defaults.set(stored, forKey: Key.unreadableSettings)
            return Settings()
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Settings.defaultsKey)
        } catch {
            let failure = error as NSError
            logger.error(
                "Settings encoding failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
        }
    }
}

extension OperationID {
    static let extraAnglePreset = "extra-angle"

    /// Includes Custom Size and the extra angle.
    var menuPresetIDs: [String] {
        let extra = self == .imageRotate || self == .videoRotate ? [Self.extraAnglePreset] : []
        return presetGroups.flatMap { $0 } + extra + (offersCustom ? [MenuEntry.customPreset] : [])
    }

    var menuEntryKeys: [String] {
        menuPresetIDs.isEmpty ? [menuEntryKey("")] : menuPresetIDs.map(menuEntryKey)
    }

    func menuEntryKey(_ preset: String) -> String {
        "\(rawValue)/\(preset)"
    }
}
