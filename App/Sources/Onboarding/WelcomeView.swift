import AppKit
import FinderSync
import SwiftUI
import UserNotifications

struct WelcomeView: View {
    let notifier: BatchNotifier
    let finish: () -> Void

    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @State private var launchesAtLogin: Bool
    @State private var failure: String?

    private let location = InstallLocation.current

    private static let width: CGFloat = 480
    private static let iconSize: CGFloat = 64
    private static let headerSpacing: CGFloat = 8
    private static let headerTopPadding: CGFloat = 28
    private static let margin: CGFloat = 32

    /// Later runs keep the user's login choice.
    init(notifier: BatchNotifier, isFirstRun: Bool, finish: @escaping () -> Void) {
        self.notifier = notifier
        self.finish = finish
        _launchesAtLogin = State(initialValue: isFirstRun || LoginItem.isOn)
    }

    private var needsMove: Bool { location.isTranslocated || !location.isInApplications }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                if needsMove { moveSection } else { checklist }
                if let failure {
                    ProblemLabel(text: failure)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsMove)
            }
            .padding()
        }
        .frame(width: Self.width)
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    private var header: some View {
        VStack(spacing: Self.headerSpacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            Text("Right-click and done.", comment: "Welcome headline")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text(
                "Select files in Finder, right-click, and choose MacEase to convert, compress, resize and more.",
                comment: "Welcome description"
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, Self.headerTopPadding)
    }

    private var moveSection: some View {
        Section {
            LabeledContent {
                Button("Quit MacEase") { NSApp.terminate(nil) }
            } label: {
                Label("Move MacEase to Applications", systemImage: "folder.badge.questionmark")
                Text(moveMessage)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Move MacEase to Applications"))
            .accessibilityHint(Text(moveMessage))
        }
    }

    private var moveMessage: String {
        location.isTranslocated
            ? String(
                localized:
                    "macOS is running MacEase from a temporary copy, so the Finder menu cannot reach it. Quit MacEase, drag it into the Applications folder, then open it from there."
            )
            : String(
                localized:
                    "MacEase works best from the Applications folder. Quit MacEase, drag it into Applications, then open it from there."
            )
    }

    private var checklist: some View {
        Section {
            LabeledContent {
                if extensionEnabled {
                    OnLabel()
                } else {
                    Button("Turn On…") { FIFinderSyncController.showExtensionManagementInterface() }
                }
            } label: {
                Text("Finder extension")
                Text("Adds MacEase to Finder's right-click menu.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Finder extension"))
            .accessibilityHint(Text("Adds MacEase to Finder's right-click menu."))
            LabeledContent {
                notificationControl
            } label: {
                Text("Notifications")
                Text("Results with Undo when a batch finishes.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Notifications"))
            .accessibilityHint(Text("Results with Undo when a batch finishes."))
            Toggle(isOn: $launchesAtLogin) {
                Text("Launch at login")
                Text("Keeps the Finder menu instant.")
            }
            .toggleStyle(.switch)
            .accessibilityLabel(Text("Launch at login"))
            .accessibilityHint(Text("Keeps the Finder menu instant."))
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "macOS asks once per protected folder, like Desktop or Downloads, the first time MacEase works there.",
                    comment: "Welcome folder access note"
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Full Disk Access…") { SystemSettingsPane.open(SystemSettingsPane.fullDiskAccess) }
            }
        }
    }

    @ViewBuilder private var notificationControl: some View {
        switch notificationStatus {
        case .notDetermined:
            Button("Allow", action: requestNotifications)
        case .denied:
            Button("Open Settings…") { SystemSettingsPane.open(SystemSettingsPane.notifications) }
        default:
            OnLabel()
        }
    }

    private func done() {
        guard !needsMove else { return }
        do {
            if launchesAtLogin != LoginItem.isOn {
                try LoginItem.setEnabled(launchesAtLogin)
            }
        } catch {
            failure = String(localized: "Launch at login could not be changed: \(error.localizedDescription)")
            return
        }
        finish()
    }

    private func requestNotifications() {
        Task {
            _ = await notifier.requestAuthorization()
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        notificationStatus = await UNUserNotificationCenter.authorizationStatus()
    }
}

private struct OnLabel: View {
    var body: some View {
        Label {
            Text("On", comment: "Welcome checklist state")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
