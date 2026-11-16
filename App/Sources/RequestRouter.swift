import AppKit
import Engine
import MenuCatalog
import os

@MainActor
final class RequestRouter {
    private let configuration: HostConfiguration
    private let jobs: JobCenter
    private let menuFile: () -> MenuFile?
    private let notifier: BatchNotifier
    private let openApp: () -> Void
    private let openUpdate: () -> Void
    private let logger = Logger(category: "requests")
    /// The extension's Open MacEase fallback.
    private static let openHost = "open"

    init(
        configuration: HostConfiguration, jobs: JobCenter, notifier: BatchNotifier,
        menuFile: @escaping () -> MenuFile?, openApp: @escaping () -> Void, openUpdate: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.jobs = jobs
        self.notifier = notifier
        self.menuFile = menuFile
        self.openApp = openApp
        self.openUpdate = openUpdate
    }

    func route(_ url: URL) {
        let request: RunRequest
        do {
            request = try RunRequest(url: url, scheme: configuration.urlScheme)
        } catch .notARunRequest {
            guard url.scheme?.lowercased() == configuration.urlScheme.lowercased() else { return }
            if url.host() == Self.openHost {
                openApp()
            } else if url.host() == "update" {
                routeUpdate(url)
            }
            return
        } catch {
            let failure = error as NSError
            logger.error(
                "Malformed request rejected (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
            return
        }
        guard let file = menuFile(), RequestToken.matches(request.token, file.token) else {
            logger.error("Request with an invalid token rejected")
            return
        }
        guard request.catalogVersion == file.catalogVersion, file.entries.indices.contains(request.entryIndex) else {
            notifier.notifyStaleMenu()
            return
        }
        let entry = file.entries[request.entryIndex]
        let inputs = request.paths.map { URL(fileURLWithPath: $0) }
        jobs.start(entry: entry, inputs: inputs)
    }

    private func routeUpdate(_ url: URL) {
        let tokens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "t" }
        guard let tokens, tokens.count == 1, let token = tokens.first?.value,
            let file = menuFile(), file.hostAvailable, RequestToken.matches(token, file.token)
        else {
            logger.error("Update request with an invalid token or unavailable host rejected")
            return
        }
        openUpdate()
    }
}
