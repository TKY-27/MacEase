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
    private static let interval: TimeInterval = 24 * 60 * 60

    private(set) var availableRelease: Release?
    @ObservationIgnored var onNewRelease: ((Release) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(category: "updates")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func check(force: Bool = false) async {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Self.interval, let endpoint = Self.endpoint else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
            let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard let pageURL = URL(string: latest.htmlURL),
                let remote = SemanticVersion(latest.tagName), let local = SemanticVersion(running), remote > local
            else { return }
            let release = Release(version: remote.description, pageURL: pageURL)
            if release != availableRelease {
                availableRelease = release
                onNewRelease?(release)
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
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
