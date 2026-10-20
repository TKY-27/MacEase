import AppKit
import MenuCatalog
import ServiceManagement
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    let notifier: BatchNotifier
    let showOnboarding: () -> Void

    @State private var pendingLanguage: SettingsStore.Language?
    @State private var confirmsPermanentDelete = false
    @State private var showsMenuItems = false
    @State private var loginStatus = LoginItem.status
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @State private var failure: String?

    private static let exitPollSeconds = 0.2

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: languageSelection) {
                    Text("System", comment: "Language option that follows macOS").tag(SettingsStore.Language.system)
                    Text(verbatim: "English").tag(SettingsStore.Language.english)
                    Text(verbatim: "日本語").tag(SettingsStore.Language.japanese)
                }
                launchAtLogin
                notifications
            }
            Section {
                LabeledContent {
                    Button("Customize…") { showsMenuItems = true }
                } label: {
                    Text("Finder menu items")
                    Text("\(visibleOperationCount) of \(OperationID.allCases.count) shown")
                }
            }
            Section {
                Toggle(isOn: permanentDeleteSelection) {
                    Text("Allow permanent delete")
                    Text("Removal operations can skip the Trash. Deleted files cannot be restored or undone.")
                }
            }
            Section {
                LabeledContent("Setup") {
                    Button("Show Onboarding Again", action: showOnboarding)
                }
            }
        }
        .sheet(isPresented: $showsMenuItems) {
            MenuItemsSheet(hiddenOperations: $store.hiddenOperations)
        }
        .alert(
            "Relaunch MacEase?", isPresented: isPresent($pendingLanguage), presenting: pendingLanguage
        ) { language in
            Button("Relaunch") { relaunch(in: language) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("MacEase relaunches to switch its language. Running jobs stop.")
        }
        .alert("Allow permanent delete?", isPresented: $confirmsPermanentDelete) {
            Button("Allow", role: .destructive) { store.settings.permanentDelete = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files removed this way skip the Trash and cannot be restored.")
        }
        .alert("Something went wrong", isPresented: isPresent($failure), presenting: failure) { _ in
            Button("OK") {}
        } message: { text in
            Text(text)
        }
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    @ViewBuilder private var launchAtLogin: some View {
        Toggle(isOn: loginSelection) {
            Text("Launch at login")
            Text("Keeps the Finder menu instant.")
        }
        if loginStatus == .requiresApproval {
            LabeledContent {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            } label: {
                Label("Approval needed in System Settings", systemImage: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        Toggle(isOn: notificationSelection) {
            Text("Notifications")
            Text("Show a summary when a batch finishes.")
        }
        if store.notificationsEnabled, notificationStatus == .denied {
            LabeledContent {
                Button("Open Notification Settings") { SystemSettingsPane.open(SystemSettingsPane.notifications) }
            } label: {
                Label("Notifications are off in System Settings", systemImage: "bell.slash")
            }
        }
    }

    private var visibleOperationCount: Int {
        OperationID.allCases.count - store.hiddenOperations.count
    }

    private var languageSelection: Binding<SettingsStore.Language> {
        Binding {
            store.language
        } set: { language in
            if language != store.language { pendingLanguage = language }
        }
    }

    private var permanentDeleteSelection: Binding<Bool> {
        Binding {
            store.settings.permanentDelete
        } set: { allowed in
            if allowed {
                confirmsPermanentDelete = true
            } else {
                store.settings.permanentDelete = false
            }
        }
    }

    private var loginSelection: Binding<Bool> {
        Binding {
            loginStatus == .enabled || loginStatus == .requiresApproval
        } set: { enabled in
            do {
                try LoginItem.setEnabled(enabled)
            } catch {
                failure = error.localizedDescription
            }
            loginStatus = LoginItem.status
        }
    }

    private var notificationSelection: Binding<Bool> {
        Binding {
            store.notificationsEnabled
        } set: { enabled in
            store.notificationsEnabled = enabled
            guard enabled else { return }
            Task {
                _ = await notifier.requestAuthorization()
                await refreshStatus()
            }
        }
    }

    private func refreshStatus() async {
        loginStatus = LoginItem.status
        notificationStatus = await UNUserNotificationCenter.authorizationStatus()
    }

    /// Waits for exit so one host runs.
    private func relaunch(in language: SettingsStore.Language) {
        store.language = language
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep \(Self.exitPollSeconds); done; /usr/bin/open \"$2\"",
            "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
        ]
        do {
            try relauncher.run()
        } catch {
            failure = error.localizedDescription
            return
        }
        NSApp.terminate(nil)
    }
}

private struct MenuItemsSheet: View {
    @Binding var hiddenOperations: Set<OperationID>

    private static let kinds: [FileKind] = [.image, .video, .audio, .pdf, .text, .archive, .jar, .folder, .any]

    var body: some View {
        ChecklistSheet(resetTitle: "Show All", canReset: !hiddenOperations.isEmpty) {
            hiddenOperations = []
        } content: {
            ForEach(Self.kinds, id: \.self) { kind in
                Section(MenuStrings.kind(kind)) {
                    ForEach(OperationID.allCases.filter { $0.kind == kind }, id: \.self) { op in
                        Toggle(isOn: visibility(of: op)) {
                            Text(MenuStrings.operation(op))
                            if let note = requirementNote(op) { Text(note) }
                        }
                    }
                }
            }
        }
    }

    private func visibility(of op: OperationID) -> Binding<Bool> {
        Binding {
            !hiddenOperations.contains(op)
        } set: { visible in
            if visible {
                hiddenOperations.remove(op)
            } else {
                hiddenOperations.insert(op)
            }
        }
    }

    private func requirementNote(_ op: OperationID) -> String? {
        switch op.requirement {
        case .appleIntelligence:
            String(localized: "Requires Apple Intelligence", comment: "Menu item visibility note")
        case .java:
            String(localized: "Requires a Java runtime", comment: "Menu item visibility note")
        case nil: nil
        }
    }
}
