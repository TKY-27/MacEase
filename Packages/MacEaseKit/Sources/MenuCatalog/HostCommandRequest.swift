import Foundation

public struct HostCommandRequest: Equatable, Sendable {
    public let action: MenuCommandAction
    public let catalogVersion: String
    public let token: String
    public let paths: [String]

    public init(action: MenuCommandAction, catalogVersion: String, token: String, paths: [String]) {
        self.action = action
        self.catalogVersion = catalogVersion
        self.token = token
        self.paths = paths
    }

    public func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action.command.rawValue.lowercased()
        components.queryItems =
            [
                URLQueryItem(name: "t", value: token), URLQueryItem(name: "v", value: catalogVersion),
            ] + (action.preset.map { [URLQueryItem(name: "preset", value: $0)] } ?? [])
            + paths.map {
                URLQueryItem(name: "path", value: $0)
            }
        return components.url
    }

    public init?(url: URL, scheme: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme.lowercased(),
            let command = HostCommand.allCases.first(where: {
                $0.rawValue.lowercased() == components.host?.lowercased()
            })
        else { return nil }
        let queries = components.queryItems ?? []
        let tokens = queries.filter { $0.name == "t" }
        let versions = queries.filter { $0.name == "v" }
        let presets = queries.filter { $0.name == "preset" }
        let pathQueries = queries.filter { $0.name == "path" }
        let paths = pathQueries.compactMap(\.value)
        guard tokens.count == 1, let token = tokens.first?.value,
            versions.count == 1, let version = versions.first?.value,
            presets.count <= 1, presets.allSatisfy({ $0.value != nil }),
            !paths.isEmpty, paths.count == pathQueries.count,
            paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\u{0}") })
        else { return nil }
        self.init(
            action: MenuCommandAction(command: command, preset: presets.first?.value),
            catalogVersion: version, token: token, paths: paths)
    }
}
