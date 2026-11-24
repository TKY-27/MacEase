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
    private static let unpreservedStreamsCaption: LocalizedStringKey =
        "Applies to subtitles, chapters and similar content in new files. Replacing an original always asks."

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
                Toggle(isOn: $store.checksForUpdatesAutomatically) {
                    Text("Check for updates automatically")
                    Text("Checks GitHub for a newer version once a day.")
                }
                .accessibilityLabel(Text("Check for updates automatically"))
                .accessibilityHint(Text("Checks GitHub for a newer version once a day."))
            }
            Section("Saving Results") {
                Picker("Save results", selection: $store.settings.outputMode) {
                    outputModeChoice(
                        String(localized: "Save as new file", comment: "Output mode"),
                        detail: String(
                            localized: "The result is saved next to the original.",
                            comment: "Output mode detail")
                    )
                    .tag(Engine.Settings.OutputMode.newFile)
                    outputModeChoice(
                        String(localized: "Replace original", comment: "Output mode"),
                        detail: String(
                            localized: "The original is moved to the Trash. Undo restores it.",
                            comment: "Output mode detail")
                    )
                    .tag(Engine.Settings.OutputMode.replace)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Picker(selection: $store.settings.unpreservedStreams) {
                    Text("Ask", comment: "Unpreserved content choice").tag(Engine.Settings.UnpreservedStreamsChoice.ask)
                    Text("Save without it", comment: "Unpreserved content choice")
                        .tag(Engine.Settings.UnpreservedStreamsChoice.omitFromNewFiles)
                } label: {
                    Text("If some content can’t be kept")
                    Text(Self.unpreservedStreamsCaption)
                }
                .accessibilityLabel(Text("If some content can’t be kept"))
                .accessibilityHint(Text(Self.unpreservedStreamsCaption))
            }
            Section {
                Toggle(isOn: $store.showsActivity) {
                    Text("Show Activity automatically")
                    Text("Opens when an operation takes longer than 2 seconds.")
                }
                .accessibilityLabel(Text("Show Activity automatically"))
                .accessibilityHint(Text("Opens when an operation takes longer than 2 seconds."))
                LabeledContent("Close automatically") {
                    VStack(alignment: .leading) {
                        Toggle("After success", isOn: $store.activityClosesAfterSuccess)
                        Toggle("After cancellation", isOn: $store.activityClosesAfterCancel)
                        Toggle("After failure", isOn: $store.activityClosesAfterFailure)
                    }
                    .toggleStyle(.checkbox)
                }
                .disabled(!store.showsActivity)
            }
            Section("Menu Bar") {
                Toggle(isOn: $store.showsStatusItem) {
                    Text("Show in menu bar")
                    Text("When the icon is hidden, open MacEase again to show Settings.")
                }
                .accessibilityLabel(Text("Show in menu bar"))
                .accessibilityHint(Text("When the icon is hidden, open MacEase again to show Settings."))
                Toggle("Show recent operations", isOn: $store.showsRecentOperations)
                    .disabled(!store.showsStatusItem)
            }
            Section {
                Toggle(isOn: permanentDeleteSelection) {
                    Text("Allow permanent deletion")
                    Text(
                        "Remove Duplicates and Remove Empty Folders can delete items without using the Trash. This can’t be undone."
                    )
                }
                .accessibilityLabel(Text("Allow permanent deletion"))
                .accessibilityHint(
                    Text(
                        "Remove Duplicates and Remove Empty Folders can delete items without using the Trash. This can’t be undone."
                    ))
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
            Text("MacEase must relaunch to change its language. Running operations will stop.")
        }
        .alert("Allow permanent deletion?", isPresented: $confirmsPermanentDelete) {
            Button("Allow", role: .destructive) { store.settings.permanentDelete = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files removed this way skip the Trash and cannot be restored.")
        }
        .alert("The setting couldn’t be changed.", isPresented: isPresent($failure), presenting: failure) { _ in
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
            Text("Open at login")
            Text("Finder menu actions start without delay.")
        }
        .accessibilityLabel(Text("Open at login"))
        .accessibilityHint(Text("Finder menu actions start without delay."))
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
            Text("Shows results with Undo when an operation finishes.")
        }
        .accessibilityLabel(Text("Notifications"))
        .accessibilityHint(Text("Shows results with Undo when an operation finishes."))
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
