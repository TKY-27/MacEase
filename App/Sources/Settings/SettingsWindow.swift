import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    private static let contentWidth: CGFloat = 640
    /// Fits small displays; longer tabs scroll.
    private static let maxContentHeight: CGFloat = 600

    static func make(
        store: SettingsStore, notifier: BatchNotifier, jobs: JobCenter, supportDirectory: URL,
        showOnboarding: @escaping () -> Void, rotateToken: @escaping () throws -> Void
    ) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let general = GeneralSettingsView(store: store, notifier: notifier, showOnboarding: showOnboarding)
        tabs.addTabViewItem(tab(String(localized: "General", comment: "Settings tab"), "gearshape", general))
        tabs.addTabViewItem(
            tab(String(localized: "Images", comment: "Settings tab"), "photo", ImageSettingsView(store: store)))
        tabs.addTabViewItem(
            tab(String(localized: "Video", comment: "Settings tab"), "film", VideoSettingsView(store: store)))
        tabs.addTabViewItem(
            tab(String(localized: "Audio", comment: "Settings tab"), "waveform", AudioSettingsView(store: store)))
        tabs.addTabViewItem(
            tab(String(localized: "Folders", comment: "Settings tab"), "folder", FolderSettingsView(store: store)))
        tabs.addTabViewItem(
            tab(String(localized: "Text", comment: "Settings tab"), "doc.plaintext", TextSettingsView(store: store)))
        let intelligence = IntelligenceSettingsView(store: store)
        tabs.addTabViewItem(
            tab(String(localized: "OCR & AI", comment: "Settings tab"), "text.viewfinder", intelligence))
        let presets = PresetSettingsView(store: store, supportDirectory: supportDirectory)
        tabs.addTabViewItem(tab(String(localized: "Presets", comment: "Settings tab"), "square.stack.3d.up", presets))
        let advanced = AdvancedSettingsView(store: store, jobs: jobs, rotateToken: rotateToken)
        tabs.addTabViewItem(tab(String(localized: "Advanced", comment: "Settings tab"), "gearshape.2", advanced))
        tabs.addTabViewItem(tab(String(localized: "About", comment: "Settings tab"), "info.circle", AboutView()))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        return window
    }

    private static func tab(_ label: String, _ symbol: String, _ content: some View) -> NSTabViewItem {
        let controller = NSHostingController(
            rootView: content.formStyle(.grouped).frame(width: contentWidth).frame(maxHeight: maxContentHeight))
        controller.sizingOptions = [.preferredContentSize]
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}
