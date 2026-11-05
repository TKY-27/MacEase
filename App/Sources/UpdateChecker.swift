import Foundation
import Observation
import os

@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let pageURL: URL
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/TKY-27/MacEase/releases/latest")
    private static let lastCheckKey = "lastUpdateCheck"
    private static let availableVersionKey = "availableReleaseVersion"
    private static let availablePageURLKey = "availableReleasePageURL"
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let downloadURL = URL(string: "https://macease-site.pages.dev/#download")
    private static let japaneseDownloadURL = URL(string: "https://macease-site.pages.dev/ja/#download")

    private(set) var availableVersion: String?
    var availableRelease: Release? {
        guard let availableVersion else { return nil }
        return Release(version: availableVersion, pageURL: officialDownloadURL)
    }
    @ObservationIgnored var onNewRelease: ((Release) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let runningVersion: SemanticVersion
    @ObservationIgnored private let logger = Logger(category: "updates")

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        guard let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let local = SemanticVersion(running)
        else { preconditionFailure("The app version must be semantic") }
        self.defaults = defaults
        self.settings = settings
        runningVersion = local
        let storedVersion = defaults.string(forKey: Self.availableVersionKey)
        if let storedVersion, let remote = SemanticVersion(storedVersion), remote > local {
            availableVersion = remote.description
        } else if storedVersion != nil {
            defaults.removeObject(forKey: Self.availableVersionKey)
        }
        defaults.removeObject(forKey: Self.availablePageURLKey)
    }

    var officialDownloadURL: URL {
        let isJapanese =
            settings.language == .japanese
            || (settings.language == .system && Locale.preferredLanguages.first?.hasPrefix("ja") == true)
        guard let destination = isJapanese ? Self.japaneseDownloadURL : Self.downloadURL else {
            preconditionFailure("Official download URL is invalid")
        }
        return destination
    }

    func check(force: Bool = false) async {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Self.interval, let endpoint = Self.endpoint else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
            guard let remote = SemanticVersion(latest.tagName), remote > runningVersion
            else { return }
            if remote.description != availableVersion {
                availableVersion = remote.description
                defaults.set(remote.description, forKey: Self.availableVersionKey)
                onNewRelease?(Release(version: remote.description, pageURL: officialDownloadURL))
            }
        } catch {
            let failure = error as NSError
            logger.error(
                "Update check failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }
}

struct SemanticVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
