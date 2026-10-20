import Engine
import Foundation
import MenuCatalog
import Observation
import os

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let hiddenOperations = "hiddenOperations"
        static let notificationsEnabled = "notificationsEnabled"
        static let onboardingCompleted = "onboardingCompleted"
        static let language = "language"
        static let appleLanguages = "AppleLanguages"
        static let unreadableSettings = "settings.unreadable"
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

    var hiddenOperations: Set<OperationID> {
        didSet {
            defaults.set(hiddenOperations.map(\.rawValue).sorted(), forKey: Key.hiddenOperations)
            onChange?()
        }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
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
        defaults.register(defaults: [Key.notificationsEnabled: true])
        settings = Self.decodeSettings(from: defaults)
        hiddenOperations = Set((defaults.stringArray(forKey: Key.hiddenOperations) ?? []).compactMap(OperationID.init))
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        language = Language(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
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
