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
        static let legacyMenuPlacements = "menuPlacements"
        static let menuArrangement = "menu.arrangement"
        static let unreadableMenuArrangement = "menu.arrangement.unreadable"
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
            if settings.extraRotationEnabled != oldValue.extraRotationEnabled { hideEmptiedGroups() }
            onChange?()
        }
    }

    /// `op/preset` keys; `op/` for operations without presets.
    var hiddenEntries: Set<String> {
        didSet {
            guard hiddenEntries != oldValue else { return }
            defaults.set(hiddenEntries.sorted(), forKey: Key.hiddenEntries)
            hideEmptiedGroups()
            onChange?()
        }
    }

    private(set) var menuArrangement: MenuArrangement {
        didSet {
            guard menuArrangement != oldValue else { return }
            Self.save(menuArrangement, to: defaults)
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
        let settings = Self.decodeSettings(from: defaults)
        self.settings = settings
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
        if defaults.object(forKey: Key.menuArrangement) != nil {
            menuArrangement = Self.decodeMenuArrangement(from: defaults)
        } else {
            let placements = (defaults.dictionary(forKey: Key.legacyMenuPlacements) as? [String: String] ?? [:])
                .compactMapValues(MenuPlacement.init(rawValue:))
            let migrated = MenuArrangement.migrating(
                placements: placements, hiddenEntries: hidden, newInstallHidden: Self.newInstallHiddenEntries,
                extraAngleEnabled: settings.extraRotationEnabled)
            // Saved first; re-migrating reduced entries loses groups.
            Self.save(migrated.arrangement, to: defaults)
            hidden = migrated.hiddenEntries
            defaults.set(hidden.sorted(), forKey: Key.hiddenEntries)
            menuArrangement = migrated.arrangement
        }
        defaults.removeObject(forKey: Key.legacyMenuPlacements)
        hiddenEntries = hidden
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
        hideEmptiedGroups()
    }

    func menuScope(_ scope: MenuScope) -> ScopeArrangement {
        menuArrangement.resolved(scope)
    }

    /// Shown groups never come back empty.
    func rearrangeMenu(_ scope: MenuScope, _ change: (inout ScopeArrangement) -> Void) {
        let previous = menuScope(scope)
        var arranged = previous
        change(&arranged)
        let shown = previous[.hidden].filter { arranged.section(of: $0) != .hidden }
        restoreLeaves(of: shown.filter(isEmptied))
        menuArrangement.set(arranged)
    }

    /// Emptied shown groups fold into Hidden.
    private func hideEmptiedGroups() {
        var emptied: [MenuGroupID] = []
        for scope in MenuScope.allCases {
            var arranged = menuScope(scope)
            let groups = arranged.groups.filter { arranged.section(of: $0) != .hidden && isEmptied($0) }
            guard !groups.isEmpty else { continue }
            arranged.hide(groups)
            menuArrangement.set(arranged)
            emptied += groups
        }
        restoreLeaves(of: emptied)
    }

    private func isEmptied(_ group: MenuGroupID) -> Bool {
        group.isEmptied(by: hiddenEntries, extraAngleEnabled: settings.extraRotationEnabled)
    }

    private func restoreLeaves(of groups: [MenuGroupID]) {
        let keys = groups.flatMap(\.entryKeys).filter { !Self.newInstallHiddenEntries.contains($0) }
        guard !keys.isEmpty else { return }
        hiddenEntries.subtract(keys)
    }

    /// Resets order and leaves, not menu values.
    func restoreMenuDefaults(_ scope: MenuScope) {
        let keys = MenuGroupCatalog.current.groups(in: scope).flatMap(\.entryKeys)
        hiddenEntries = hiddenEntries.subtracting(keys).union(keys.filter(Self.newInstallHiddenEntries.contains))
        menuArrangement.restoreDefaults(scope)
    }

    func isMenuDefault(_ scope: MenuScope) -> Bool {
        let keys = MenuGroupCatalog.current.groups(in: scope).flatMap(\.entryKeys)
        return !menuArrangement.isCustomized(scope)
            && keys.allSatisfy { hiddenEntries.contains($0) == Self.newInstallHiddenEntries.contains($0) }
    }

    /// History and edited presets survive.
    func resetAll() {
        settings = Settings()
        hiddenEntries = Self.newInstallHiddenEntries
        menuArrangement = MenuArrangement()
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

    /// Unreadable arrangements are kept aside.
    private static func decodeMenuArrangement(from defaults: UserDefaults) -> MenuArrangement {
        let stored = defaults.object(forKey: Key.menuArrangement)
        do {
            guard let encoded = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
            return try JSONDecoder().decode(MenuArrangement.self, from: encoded)
        } catch {
            let failure = error as NSError
            Logger(category: "settings")
                .error(
                    "Stored menu arrangement unreadable, using defaults (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                )
            defaults.set(stored, forKey: Key.unreadableMenuArrangement)
            return MenuArrangement()
        }
    }

    private static func save(_ arrangement: MenuArrangement, to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(arrangement), forKey: Key.menuArrangement)
        } catch {
            let failure = error as NSError
            Logger(category: "settings").error(
                "Menu arrangement encoding failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
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
