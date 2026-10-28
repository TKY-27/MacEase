import AppKit
import FinderSync
import SwiftUI

struct FolderAccessSettingsView: View {
    @Bindable var folders: FolderAccessStore
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Finder extension")
                    Spacer()
                    Text(extensionEnabled ? String(localized: "On") : String(localized: "Off"))
                    Button("Extension Settings…") { FIFinderSyncController.showExtensionManagementInterface() }
                }
                Text("MacEase registers all local and mounted locations. Access still depends on macOS permissions.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(folders.locations) { location in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(location.url.lastPathComponent, systemImage: "folder")
                            Spacer()
                            Text(location.status.title).foregroundStyle(.secondary)
                        }
                        Text(
                            location.registrationAvailable
                                ? String(localized: "Registration requested")
                                : String(localized: "Location unavailable")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(location.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .id(location.url.path)
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.open(location.url) }
                            Button("Check Access") { Task { await folders.check(location) } }
                                .disabled(location.status == .checking)
                            Spacer()
                            if location.removable {
                                Button("Remove from List") { folders.remove(location) }
                                    .disabled(!folders.canSave)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Add Folder…", action: folders.addFolder)
                    .disabled(!folders.canSave)
            } header: {
                Text("Registered Folders")
            } footer: {
                Text(
                    "Removing a folder only removes its explicit registration. It does not revoke macOS permissions or block MacEase there."
                )
            }
            Section("Access and Availability") {
                Text("Readable confirms folder listing only. Write access is checked when saving a result.")
                Text(
                    "If macOS keeps an access request waiting, select that folder with Add Folder, then restart MacEase and retry."
                )
                Text("For cloud folders without a MacEase menu, use Services → Process with MacEase… in Finder.")
                HStack {
                    Button("Files and Folders…") { SystemSettingsPane.open(SystemSettingsPane.filesAndFolders) }
                    Button("Full Disk Access…") { SystemSettingsPane.open(SystemSettingsPane.fullDiskAccess) }
                    Button("Refresh", action: refresh)
                }
            }
            if let failure = folders.failure { ProblemLabel(text: failure) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        folders.refreshLocations()
    }
}
