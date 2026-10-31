import Foundation

public struct OrganizationCorrection: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let evidence: String
    public let category: String

    public init(fingerprint: String, evidence: String, category: String) {
        self.fingerprint = fingerprint
        self.evidence = String(evidence.prefix(1_000))
        self.category = category
    }
}

public struct OrganizationSuppression: Codable, Equatable, Sendable {
    public let path: String
    public let stamp: FileStamp

    public init(url: URL) throws {
        path = url.path
        stamp = try FileStamp(of: url, includingIdentity: true)
    }

    public init(path: String, stamp: FileStamp) {
        self.path = path
        self.stamp = stamp
    }

    public func matches(_ url: URL) -> Bool { url.path == path && stamp.matchesIdentity(path) }
}

public struct OrganizationRegistration: Codable, Identifiable, Sendable {
    public let id: UUID
    public var rootIdentity: OrganizationIdentity?
    public var bookmark: Data
    public var path: String
    public var policy: OrganizationPolicy
    public var automatic: Bool
    public var paused: Bool
    public var corrections: [OrganizationCorrection]
    public var suppressions: [OrganizationSuppression]

    public init(root: URL, policy: OrganizationPolicy) throws {
        let root = try OrganizationSafety.normalizedRoot(root)
        try policy.validate()
        id = UUID()
        rootIdentity = try OrganizationIdentity(of: root, directory: true)
        bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        path = root.path
        self.policy = policy
        automatic = false
        paused = false
        corrections = []
        suppressions = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, rootIdentity, bookmark, path, policy, automatic, paused, corrections, suppressions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        rootIdentity = try values.decodeIfPresent(OrganizationIdentity.self, forKey: .rootIdentity)
        bookmark = try values.decode(Data.self, forKey: .bookmark)
        path = try values.decode(String.self, forKey: .path)
        policy = try values.decode(OrganizationPolicy.self, forKey: .policy)
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        corrections = try values.decodeIfPresent([OrganizationCorrection].self, forKey: .corrections) ?? []
        suppressions = try values.decodeIfPresent([OrganizationSuppression].self, forKey: .suppressions) ?? []
        if rootIdentity == nil { automatic = false; paused = true }
    }

    public mutating func resolve() throws -> URL {
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).standardizedFileURL
        let root = try OrganizationSafety.normalizedRoot(resolved)
        guard rootIdentity?.matches(root, directory: true) == true else {
            throw EngineError.invalidInput(.malformed("The watched folder was replaced"))
        }
        if stale { bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        path = root.path
        return root
    }
}

public actor OrganizationStore {
    private let url: URL
    public init(supportDirectory: URL) { url = supportDirectory.appending(path: "organization.json") }

    public func load() throws -> [OrganizationRegistration] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let registrations = try JSONDecoder().decode([OrganizationRegistration].self, from: Data(contentsOf: url))
        for registration in registrations { try registration.policy.validate() }
        return registrations
    }

    public func save(_ registrations: [OrganizationRegistration]) throws {
        for registration in registrations { try registration.policy.validate() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.write(JSONEncoder().encode(registrations), to: url)
    }
}
