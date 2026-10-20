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
    private let logger = Logger(category: "requests")

    init(
        configuration: HostConfiguration, jobs: JobCenter, notifier: BatchNotifier, menuFile: @escaping () -> MenuFile?
    ) {
        self.configuration = configuration
        self.jobs = jobs
        self.notifier = notifier
        self.menuFile = menuFile
    }

    func route(_ url: URL) {
        let request: RunRequest
        do {
            request = try RunRequest(url: url, scheme: configuration.urlScheme)
        } catch .notARunRequest {
            return
        } catch {
            logger.error("Malformed request rejected: \(String(describing: error), privacy: .public)")
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
