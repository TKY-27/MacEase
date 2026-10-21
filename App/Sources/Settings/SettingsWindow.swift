import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    private static let minimumSize = NSSize(width: 720, height: 520)
    private static let initialSize = NSSize(width: 820, height: 600)
    private static let frameName = "Settings"

    static func make(
        store: SettingsStore, notifier: BatchNotifier, jobs: JobCenter, supportDirectory: URL,
        showWelcome: @escaping () -> Void, rotateToken: @escaping () throws -> Void
    ) -> NSWindow {
        let view = SettingsView(
            store: store, notifier: notifier, jobs: jobs, supportDirectory: supportDirectory,
            showWelcome: showWelcome, rotateToken: rotateToken)
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.contentMinSize = minimumSize
        window.setContentSize(initialSize)
        window.setFrameAutosaveName(frameName)
        return window
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case finderMenu
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
        case .finderMenu: String(localized: "Finder Menu", comment: "Settings page")
        case .images: String(localized: "Images", comment: "Settings page")
        case .video: String(localized: "Video", comment: "Settings page")
        case .audio: String(localized: "Audio", comment: "Settings page")
        case .folders: String(localized: "Folders", comment: "Settings page")
        case .text: String(localized: "Text", comment: "Settings page")
        case .intelligence: String(localized: "Text Recognition & Intelligence", comment: "Settings page")
        case .advanced: String(localized: "Advanced", comment: "Settings page")
        case .about: String(localized: "About", comment: "Settings page")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .finderMenu: "contextualmenu.and.cursorarrow"
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

private struct SettingsView: View {
    let store: SettingsStore
    let notifier: BatchNotifier
    let jobs: JobCenter
    let supportDirectory: URL
    let showWelcome: () -> Void
    let rotateToken: () throws -> Void

    @State private var page: SettingsPage? = .general

    private static let sidebarWidth: CGFloat = 200

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol)
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(page ?? .general)
                .formStyle(.grouped)
                .navigationTitle((page ?? .general).title)
        }
    }

    @ViewBuilder private func detail(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsView(store: store, notifier: notifier, showWelcome: showWelcome)
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
