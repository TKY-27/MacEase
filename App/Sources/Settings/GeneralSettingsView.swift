import AppKit
import Engine
import ServiceManagement
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    let notifier: BatchNotifier
    let showWelcome: () -> Void

    @State private var pendingLanguage: SettingsStore.Language?
    @State private var confirmsPermanentDelete = false
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
            Section("When Converting or Editing") {
                Picker("When converting or editing", selection: $store.settings.outputMode) {
                    outputModeChoice(
                        String(localized: "Save as new file", comment: "Output mode"),
                        detail: String(
                            localized: "The result appears next to the original, which stays untouched.",
                            comment: "Output mode detail")
                    )
                    .tag(Engine.Settings.OutputMode.newFile)
                    outputModeChoice(
                        String(localized: "Replace original", comment: "Output mode"),
                        detail: String(
                            localized: "The original moves to the Trash. Undo puts it back.",
                            comment: "Output mode detail")
                    )
                    .tag(Engine.Settings.OutputMode.replace)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section {
                Toggle(isOn: $store.showsActivity) {
                    Text("Show progress window")
                    Text("Appears when a batch takes more than a moment. Finder keeps focus.")
                }
                .accessibilityLabel(Text("Show progress window"))
                .accessibilityHint(Text("Appears when a batch takes more than a moment. Finder keeps focus."))
                LabeledContent("Close automatically") {
                    VStack(alignment: .leading) {
                        Toggle("After success", isOn: $store.activityClosesAfterSuccess)
                        Toggle("After cancel", isOn: $store.activityClosesAfterCancel)
                        Toggle("After failure", isOn: $store.activityClosesAfterFailure)
                    }
                    .toggleStyle(.checkbox)
                }
                .disabled(!store.showsActivity)
            }
            Section {
                Toggle(isOn: permanentDeleteSelection) {
                    Text("Allow permanent delete")
                    Text("Removal operations can skip the Trash. Deleted files cannot be restored or undone.")
                }
                .accessibilityLabel(Text("Allow permanent delete"))
                .accessibilityHint(
                    Text("Removal operations can skip the Trash. Deleted files cannot be restored or undone."))
            }
            Section {
                LabeledContent("Setup") {
                    Button("Show Welcome Window…", action: showWelcome)
                }
            }
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
        .accessibilityLabel(Text("Launch at login"))
        .accessibilityHint(Text("Keeps the Finder menu instant."))
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
            Text("Results with Undo when a batch finishes.")
        }
        .accessibilityLabel(Text("Notifications"))
        .accessibilityHint(Text("Results with Undo when a batch finishes."))
        if store.notificationsEnabled, notificationStatus == .denied {
            LabeledContent {
                Button("Open Notification Settings") { SystemSettingsPane.open(SystemSettingsPane.notifications) }
            } label: {
                Label("Notifications are off in System Settings", systemImage: "bell.slash")
            }
        }
    }

    private func outputModeChoice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
