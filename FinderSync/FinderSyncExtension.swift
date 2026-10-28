import AppKit
import FinderSync
import MenuCatalog
import Synchronization

// Not @MainActor: Finder calls actions off-main.
final class FinderSyncExtension: FIFinderSync {
    private struct Cache {
        var file: MenuFile?
        var modified: Date?
        var lastMenuKind = FIMenuKind.contextualMenuForItems
    }

    private static let rootImageName = "FinderRoot"
    private let cache = Mutex(Cache())
    private let directoryRegistration = Mutex(())
    private let scheme: String
    private let menuFileURL: URL

    override init() {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "MacEaseURLScheme") as? String,
            let supportFolder = Bundle.main.object(forInfoDictionaryKey: "MacEaseSupportFolder") as? String
        else { preconditionFailure("Info.plist lacks the MacEase keys") }
        self.scheme = scheme
        menuFileURL = Self.realHomeDirectory
            .appending(path: "Library/Application Support/\(supportFolder)/menu.json")
        super.init()
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            notifications.addObserver(self, selector: #selector(volumesDidChange(_:)), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(locationsDidChange(_:)),
            name: FinderLocations.notificationName(supportFolder: supportFolder), object: nil,
            suspensionBehavior: .deliverImmediately)
        updateMonitoredDirectories()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        updateMonitoredDirectories()
    }

    @objc private func locationsDidChange(_ notification: Notification) {
        cache.withLock { $0.modified = nil }
        updateMonitoredDirectories()
    }

    private func updateMonitoredDirectories() {
        directoryRegistration.withLock { _ in
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [], options: []) ?? []
            FIFinderSyncController.default().directoryURLs = FinderLocations.directories(
                home: Self.realHomeDirectory, volumes: volumes,
                additionalPaths: currentMenuFile()?.monitoredDirectoryPaths ?? [])
        }
    }

    // The sandbox redirects NSHomeDirectory into the container.
    private static var realHomeDirectory: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            preconditionFailure("The account home directory is unavailable")
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let file = currentMenuFile()
        let selection = selection(for: menuKind)
        cache.withLock { $0.lastMenuKind = menuKind }
        let submenu = NSMenu(title: "MacEase")
        if let file, file.hostAvailable {
            let nodes = MenuLayout.nodes(for: file, selection: selection)
            guard !nodes.isEmpty else { return nil }
            add(nodes, to: submenu)
        } else {
            let open = NSMenuItem(title: openTitle, action: #selector(openHost(_:)), keyEquivalent: "")
            open.target = self
            submenu.addItem(open)
        }
        let root = NSMenuItem(title: "MacEase", action: nil, keyEquivalent: "")
        root.image = NSImage(named: Self.rootImageName)
        root.submenu = submenu
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return menu
    }

    private func add(_ nodes: [MenuNode], to menu: NSMenu) {
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())
            case .action(let title, let entryIndex):
                let menuItem = NSMenuItem(title: title, action: #selector(runEntry(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = entryIndex
                menu.addItem(menuItem)
            case .submenu(let title, let children):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                add(children, to: submenu)
                menuItem.submenu = submenu
                menu.addItem(menuItem)
            }
        }
    }

    private var openTitle: String {
        String(localized: "Open MacEase", comment: "Only Finder menu item when the app is unavailable")
    }

    @objc func runEntry(_ sender: NSMenuItem) {
        let tag = sender.tag
        let (file, menuKind) = cache.withLock { ($0.file, $0.lastMenuKind) }
        guard let file else { return }
        let paths = selection(for: menuKind).map(\.path)
        let request = RunRequest(catalogVersion: file.catalogVersion, entryIndex: tag, token: file.token, paths: paths)
        guard !paths.isEmpty, let url = request.url(scheme: scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openHost(_ sender: NSMenuItem) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func selection(for menuKind: FIMenuKind) -> [URL] {
        let controller = FIFinderSyncController.default()
        if menuKind == .contextualMenuForContainer {
            return controller.targetedURL().map { [$0] } ?? []
        }
        return controller.selectedItemURLs() ?? []
    }

    private func currentMenuFile() -> MenuFile? {
        let fresh = URL(fileURLWithPath: menuFileURL.path)
        let modified = try? fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = cache.withLock({ $0.modified == modified && modified != nil ? $0.file : nil }) {
            return cached
        }
        let file = (try? Data(contentsOf: menuFileURL)).flatMap { try? MenuFile(json: $0) }
        let usable = file?.schema == MenuFile.currentSchema ? file : nil
        cache.withLock { cache in
            cache.file = usable
            cache.modified = modified
        }
        return usable
    }
}
