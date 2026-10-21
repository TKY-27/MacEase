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
    private let logger = Logger(category: "requests")
    /// The extension's Open MacEase fallback.
    private static let openHost = "open"

    init(
        configuration: HostConfiguration, jobs: JobCenter, notifier: BatchNotifier,
        menuFile: @escaping () -> MenuFile?, openApp: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.jobs = jobs
        self.notifier = notifier
        self.menuFile = menuFile
        self.openApp = openApp
    }

    func route(_ url: URL) {
        let request: RunRequest
        do {
            request = try RunRequest(url: url, scheme: configuration.urlScheme)
        } catch .notARunRequest {
            if url.scheme?.lowercased() == configuration.urlScheme.lowercased(), url.host() == Self.openHost {
                openApp()
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
}
