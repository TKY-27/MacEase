import AppKit
import Observation

@MainActor
@Observable
final class FolderAccessStore {
    struct Location: Identifiable {
        let id: String
        var url: URL
        let removable: Bool
        var status = Status.unchecked
        var registrationAvailable = true
    }

    enum Status {
        case unchecked, readable, denied, unavailable, checking

        var title: String {
            switch self {
            case .unchecked: String(localized: "Not checked")
            case .readable: String(localized: "Readable")
            case .denied: String(localized: "Access denied")
            case .unavailable: String(localized: "Unavailable")
            case .checking: String(localized: "Checking…")
            }
        }
    }

    private struct SavedLocation: Codable {
        let id: String
        var bookmark: Data
        var path: String
    }

    private static let defaultsKey = "finder.additionalFolders"
    private var saved: [SavedLocation] = []
    private(set) var canSave = true
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var locations: [Location] = []
    var failure: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.data(forKey: Self.defaultsKey) {
            do {
                saved = try JSONDecoder().decode([SavedLocation].self, from: stored)
            } catch {
                canSave = false
                failure = String(localized: "Saved folders could not be read: \(error.localizedDescription)")
            }
        }
        refreshLocations()
    }

    var monitoredPaths: [String] {
        locations.filter(\.registrationAvailable).map { $0.url.path }
    }

    func addFolder() {
        guard canSave else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder")
        panel.message = String(localized: "Choose folders to register with MacEase.")
        guard panel.runModal() == .OK else { return }
        do {
            var updated = saved
            var known = Set(locations.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
            for url in panel.urls {
                let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
                guard known.insert(normalized).inserted else { continue }
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                updated.append(SavedLocation(id: UUID().uuidString, bookmark: bookmark, path: url.path))
            }
            try save(updated)
            refreshLocations()
        } catch {
            failure = String(localized: "The folder could not be saved: \(error.localizedDescription)")
        }
    }

    func remove(_ location: Location) {
        guard location.removable, canSave else { return }
        do {
            try save(saved.filter { $0.id != location.id })
            refreshLocations()
        } catch {
            failure = String(localized: "The folder could not be saved: \(error.localizedDescription)")
        }
    }

    func refreshLocations() {
        let folders: [(String, FileManager.SearchPathDirectory)] = [
            ("desktop", .desktopDirectory), ("documents", .documentDirectory), ("downloads", .downloadsDirectory),
        ]
        var refreshed = folders.compactMap { id, directory -> Location? in
            guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return nil }
            return Location(id: id, url: url, removable: false)
        }
        var updated = saved
        var changed = false
        for index in updated.indices {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: updated[index].bookmark, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale {
                    updated[index].bookmark = try url.bookmarkData(
                        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    changed = true
                }
                if updated[index].path != url.path {
                    updated[index].path = url.path
                    changed = true
                }
                refreshed.append(Location(id: updated[index].id, url: url, removable: true))
            } catch {
                refreshed.append(
                    Location(
                        id: updated[index].id, url: URL(fileURLWithPath: updated[index].path), removable: true,
                        status: .unavailable, registrationAvailable: false))
            }
        }
        if changed, canSave {
            do {
                try save(updated)
            } catch {
                failure = String(localized: "The folder could not be saved: \(error.localizedDescription)")
            }
        }
        for index in refreshed.indices {
            if let previous = locations.first(where: {
                $0.id == refreshed[index].id && $0.url == refreshed[index].url
                    && $0.registrationAvailable == refreshed[index].registrationAvailable
            }) {
                refreshed[index].status = previous.status
            }
        }
        locations = refreshed
        onChange?()
    }

    func check(_ location: Location) async {
        guard let index = locations.firstIndex(where: { $0.id == location.id }) else { return }
        locations[index].status = .checking
        let url = location.url
        let status = await Task.detached {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
                return Status.readable
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoPermissionError {
                    return Status.denied
                }
                return Status.unavailable
            }
        }.value
        guard let current = locations.firstIndex(where: { $0.id == location.id && $0.url == url }) else { return }
        locations[current].status = status
    }

    private func save(_ updated: [SavedLocation]) throws {
        let encoded = try JSONEncoder().encode(updated)
        defaults.set(encoded, forKey: Self.defaultsKey)
        saved = updated
    }
}
