import AppKit
import ApplicationServices
import SwiftUI

struct FinderWindowsSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var accessibilityAllowed = AXIsProcessTrusted()
    @State private var automation: FinderPermissionStatus?
    @State private var finderShowsStatusBar = FinderStorageBarGeometry.finderShowsStatusBar()

    private static let sampleLines = 1...5

    var body: some View {
        Form {
            Section("Finder Preview") {
                Toggle("Show Finder Preview beside Finder windows", isOn: $store.finderPreviewEnabled)
            }
            Section {
                Toggle("Show storage bar in Finder windows", isOn: $store.finderStorageBarEnabled)
            } header: {
                Text("Storage Bar")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shows available space and the number of selected items at the bottom of Finder windows.")
                    if store.finderStorageBarEnabled && !finderShowsStatusBar {
                        Text("To see it, choose View > Show Status Bar in Finder.")
                    }
                }
            }
            Section("Permissions") {
                permissionRow(
                    title: Text("Accessibility"),
                    detail: Text("Places the preview and the storage bar on Finder windows."),
                    status: accessibilityAllowed ? .allowed : .denied,
                    open: SystemSettingsPane.accessibility, openLabel: Text("Open Accessibility Settings"))
                permissionRow(
                    title: Text("Automation"),
                    detail: Text("Lets the preview and the storage bar follow the selection in Finder."),
                    status: automation,
                    open: SystemSettingsPane.automation, openLabel: Text("Open Automation Settings"))
            }
            Section {
                ForEach(FinderPreviewFileType.allCases) { type in
                    Toggle(type.title, isOn: enabled(type))
                }
            } header: {
                Text("File Types")
            } footer: {
                Text("Types that are off use the macOS preview.")
            }
            Section("Text") {
                Picker("Code font", selection: $store.finderPreview.codeFontFamily) {
                    Text("System Monospaced").tag("")
                    if !PreviewCodeFont.families.contains(store.finderPreview.codeFontFamily),
                        !store.finderPreview.codeFontFamily.isEmpty
                    {
                        Text(verbatim: store.finderPreview.codeFontFamily).tag(store.finderPreview.codeFontFamily)
                    }
                    ForEach(PreviewCodeFont.families, id: \.self) { family in
                        Text(verbatim: family).tag(family)
                    }
                }
                NumberField(
                    title: Text("Code font size"), value: $store.finderPreview.codeFontSize,
                    range: FinderPreviewSettings.codeFontSizeRange)
                Toggle("Wrap long lines to the panel width", isOn: $store.finderPreview.wrapLines)
            }
            Section("Fonts") {
                TextField(
                    "Font sample text", text: $store.finderPreview.fontSampleText,
                    prompt: Text("Built-in sample"), axis: .vertical
                )
                .lineLimit(Self.sampleLines)
            }
            Section {
                if store.finderPreview.trustedFolders.isEmpty {
                    Text("No trusted folders").foregroundStyle(.secondary)
                }
                ForEach(store.finderPreview.trustedFolders, id: \.self) { path in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                            Text(verbatim: path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Remove") { store.finderPreview.removeTrustedFolder(path) }
                    }
                }
                Button("Add Folder…", action: addTrustedFolders)
            } header: {
                Text("Trusted Folders")
            } footer: {
                Text(
                    "HTML files in these folders open in Preview with scripts and network access enabled. Files from the internet stay restricted."
                )
            }
        }
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
    }

    private func permissionRow(
        title: Text, detail: Text, status: FinderPermissionStatus?, open: URL?, openLabel: Text
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let status {
                    Text(status.title).foregroundStyle(.secondary)
                }
                if status != .allowed {
                    Button("Open Settings…") { SystemSettingsPane.open(open) }
                        .accessibilityLabel(openLabel)
                }
            }
        } label: {
            title
            detail
        }
    }

    private func enabled(_ type: FinderPreviewFileType) -> Binding<Bool> {
        Binding {
            !store.finderPreview.disabledKinds.contains(type)
        } set: { on in
            if on {
                store.finderPreview.disabledKinds.remove(type)
            } else {
                store.finderPreview.disabledKinds.insert(type)
            }
        }
    }

    private func addTrustedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Trust")
        panel.message = String(
            localized: "HTML in the chosen folders opens with scripts and network access enabled.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.finderPreview.addTrustedFolder(url) }
    }

    private func refreshPermissions() async {
        accessibilityAllowed = AXIsProcessTrusted()
        finderShowsStatusBar = FinderStorageBarGeometry.finderShowsStatusBar()
        let status = await Task.detached(priority: .utility) {
            FinderSelectionReader.automationPermission(asking: false)
        }.value
        automation = FinderPermissionStatus(automation: status)
    }
}

enum FinderPermissionStatus: Equatable {
    case allowed, notAsked, denied, unknown

    init(automation status: OSStatus) {
        switch Int(status) {
        case Int(noErr): self = .allowed
        case Int(errAEEventWouldRequireUserConsent): self = .notAsked
        case Int(errAEEventNotPermitted): self = .denied
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .notAsked: String(localized: "Not Set Up", comment: "Permission status")
        case .denied: String(localized: "Not Allowed", comment: "Permission status")
        case .unknown: String(localized: "Unknown", comment: "Permission status")
        }
    }
}

extension FinderPreviewFileType {
    var title: String {
        switch self {
        case .text: String(localized: "Source code and text")
        case .html: "HTML"
        case .markdown: "Markdown"
        case .svg: "SVG"
        case .pdf: "PDF"
        case .font: String(localized: "Fonts")
        case .image: String(localized: "Images")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        }
    }
}
