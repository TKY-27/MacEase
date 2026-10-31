import AppKit
import Engine
import SwiftUI

@MainActor
enum SettingsWindow {
    private static let minimumSize = NSSize(width: 720, height: 520)
    private static let initialSize = NSSize(width: 820, height: 600)
    private static let frameName = "Settings"

    static func make(
        store: SettingsStore, folders: FolderAccessStore, notifier: BatchNotifier, jobs: JobCenter,
        organization: OrganizationController?,
        recipes: RecipeStore,
        supportDirectory: URL,
        showWelcome: @escaping () -> Void, rotateToken: @escaping () throws -> Void
    ) -> NSWindow {
        // The window title follows the controller's title.
        var controller: NSHostingController<SettingsView>?
        let view = SettingsView(
            store: store, folders: folders, notifier: notifier, jobs: jobs, supportDirectory: supportDirectory,
            organization: organization, recipes: recipes, showWelcome: showWelcome, rotateToken: rotateToken
        ) { controller?.title = $0 }
        let hosting = NSHostingController(rootView: view)
        hosting.sceneBridgingOptions = [.toolbars]
        controller = hosting
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.contentMinSize = minimumSize
        window.setContentSize(initialSize)
        window.setFrameAutosaveName(frameName)
        return window
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case finderMenu
    case folderAccess
    case organization
    case recipes
    case images
    case video
    case audio
    case folders
    case text
    case intelligence
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "Settings page")
        case .folderAccess: String(localized: "Folder Access", comment: "Settings page")
        case .organization: String(localized: "Organization", comment: "Settings page")
        case .recipes: String(localized: "Finishing Recipes", comment: "Settings page")
        case .finderMenu: String(localized: "Finder Menu", comment: "Settings page")
        case .images: String(localized: "Images", comment: "Settings page")
        case .video: String(localized: "Video", comment: "Settings page")
        case .audio: String(localized: "Audio", comment: "Settings page")
        case .folders: String(localized: "Folders", comment: "Settings page")
        case .text: String(localized: "Text", comment: "Settings page")
        case .intelligence: String(localized: "Text Recognition & AI", comment: "Settings page")
        case .advanced: String(localized: "Advanced", comment: "Settings page")
        case .about: String(localized: "About", comment: "Settings page")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .finderMenu: "contextualmenu.and.cursorarrow"
        case .folderAccess: "folder.badge.gearshape"
        case .organization: "tray.and.arrow.down"
        case .recipes: "square.stack.3d.up"
        case .images: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .folders: "folder"
        case .text: "doc.plaintext"
        case .intelligence: "text.viewfinder"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    let store: SettingsStore
    let folders: FolderAccessStore
    let notifier: BatchNotifier
    let jobs: JobCenter
    let supportDirectory: URL
    let organization: OrganizationController?
    let recipes: RecipeStore
    let showWelcome: () -> Void
    let rotateToken: () throws -> Void
    let showTitle: (String) -> Void

    @State private var page: SettingsPage? = .general

    private static let sidebarWidth: CGFloat = 240

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol)
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .frame(minWidth: Self.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(page ?? .general)
                .formStyle(.grouped)
        }
        .onChange(of: page, initial: true) { showTitle((page ?? .general).title) }
    }

    @ViewBuilder private func detail(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsView(store: store, notifier: notifier, showWelcome: showWelcome)
        case .folderAccess: FolderAccessSettingsView(folders: folders)
        case .organization:
            if let organization { OrganizationSettingsView(controller: organization) }
        case .recipes: RecipeLibraryView(recipeStore: recipes)
        case .finderMenu: FinderMenuSettingsView(store: store, supportDirectory: supportDirectory)
        case .images: ImageSettingsView(store: store)
        case .video: VideoSettingsView(store: store)
        case .audio: AudioSettingsView(store: store)
        case .folders: FolderSettingsView(store: store)
        case .text: TextSettingsView(store: store)
        case .intelligence: IntelligenceSettingsView(store: store)
        case .advanced: AdvancedSettingsView(store: store, jobs: jobs, rotateToken: rotateToken)
        case .about: AboutView()
        }
    }
}
