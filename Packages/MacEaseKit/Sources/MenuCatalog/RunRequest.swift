import Foundation

public enum RequestPath {
    public static func isValid(_ path: String) -> Bool {
        normalized(path) != nil
    }

    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\u{0}") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else { return nil }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public static func fileURL(for path: String) -> URL? {
        normalized(path).map { URL(fileURLWithPath: $0) }
    }
}

public struct RunRequest: Equatable, Sendable {
    public static let host = "run"

    public let catalogVersion: String
    public let entryIndex: Int
    public let token: String
    public let paths: [String]

    public init(catalogVersion: String, entryIndex: Int, token: String, paths: [String]) {
        self.catalogVersion = catalogVersion
        self.entryIndex = entryIndex
        self.token = token
        self.paths = paths
    }

    public func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.host
        components.queryItems =
            [
                URLQueryItem(name: "v", value: catalogVersion),
                URLQueryItem(name: "e", value: String(entryIndex)),
                URLQueryItem(name: "t", value: token),
            ] + paths.map { URLQueryItem(name: "path", value: $0) }
        return components.url
    }

    public init(url: URL, scheme: String) throws(RunRequestError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme.lowercased(),
            components.host?.lowercased() == Self.host
        else { throw .notARunRequest }
        let items = components.queryItems ?? []
        func single(_ name: String) throws(RunRequestError) -> String {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            guard values.count == 1, let value = values.first else { throw .missingField(name) }
            return value
        }
        let version = try single("v")
        let token = try single("t")
        guard let index = Int(try single("e")), index >= 0 else { throw .missingField("e") }
        let pathQueries = items.filter { $0.name == "path" }
        let paths = pathQueries.compactMap(\.value)
        guard !paths.isEmpty, paths.count == pathQueries.count, paths.allSatisfy(RequestPath.isValid) else {
            throw .invalidPaths
        }
        self.init(catalogVersion: version, entryIndex: index, token: token, paths: paths)
    }
}

/// Ties item tags to their menu's file.
public struct MenuBuilds: Sendable {
    /// Finder round-trips tags; stay within 31 bits.
    public static let tagLimit = Int(Int32.max)
    static let retainedCount = 8

    private struct Build {
        let tags: Range<Int>
        let file: MenuFile
    }

    private var builds: [Build] = []
    private var nextTag: Int

    /// Random starts separate restarted extensions' tags.
    public init(firstTag: Int = Int.random(in: 1...tagLimit / 2)) {
        nextTag = firstTag
    }

    /// Entry zero's tag, or nil when exhausted.
    public mutating func record(_ file: MenuFile) -> Int? {
        let count = file.entries.count + file.commandActions.count
        guard count <= Self.tagLimit - nextTag else { return nil }
        guard count > 0 else { return nextTag }
        let tags = nextTag..<nextTag + count
        nextTag = tags.upperBound
        builds.append(Build(tags: tags, file: file))
        if builds.count > Self.retainedCount { builds.removeFirst() }
        return tags.lowerBound
    }

    /// Nil once newer menus replaced the build.
    public func request(tag: Int, paths: [String]) -> RunRequest? {
        guard let build = builds.first(where: { $0.tags.contains(tag) }),
            tag - build.tags.lowerBound < build.file.entries.count
        else { return nil }
        return RunRequest(
            catalogVersion: build.file.catalogVersion, entryIndex: tag - build.tags.lowerBound,
            token: build.file.token, paths: paths)
    }

    public func commandTag(_ action: MenuCommandAction, firstTag: Int) -> Int? {
        guard let build = builds.first(where: { $0.tags.lowerBound == firstTag }),
            let index = build.file.commandActions.firstIndex(of: action)
        else { return nil }
        return firstTag + build.file.entries.count + index
    }

    public func commandRequest(tag: Int, paths: @autoclosure () -> [String]) -> HostCommandRequest? {
        guard let build = builds.first(where: { $0.tags.contains(tag) }) else { return nil }
        let index = tag - build.tags.lowerBound - build.file.entries.count
        guard build.file.commandActions.indices.contains(index) else { return nil }
        let action = build.file.commandActions[index]
        return HostCommandRequest(
            action: action,
            catalogVersion: build.file.catalogVersion, token: build.file.token,
            paths: action.command.requiresSelection ? paths() : [])
    }
}

public enum RunRequestError: Error, Equatable, Sendable {
    case notARunRequest
    case missingField(String)
    case invalidPaths
}
