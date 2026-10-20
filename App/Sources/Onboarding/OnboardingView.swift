import AppKit
import FinderSync
import ServiceManagement
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    let notifier: BatchNotifier
    let finish: () -> Void

    @State private var index = 0
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @State private var launchesAtLogin: Bool
    @State private var failure: String?

    private let location = InstallLocation.current
    private let steps: [Step]

    private static let width: CGFloat = 540
    private static let height: CGFloat = 420
    private static let symbolSize: CGFloat = 52
    private static let dotSize: CGFloat = 7
    private static let dotSpacing: CGFloat = 8
    private static let rowSpacing: CGFloat = 14
    private static let accessoryTopPadding: CGFloat = 6
    private static let margin: CGFloat = 40
    private static let stepFade = Animation.easeOut(duration: 0.2)

    /// Later runs keep the user's login choice.
    init(notifier: BatchNotifier, isFirstRun: Bool, finish: @escaping () -> Void) {
        self.notifier = notifier
        self.finish = finish
        _launchesAtLogin = State(initialValue: isFirstRun || LoginItem.status != .notRegistered)
        let needsMove = location.isTranslocated || !location.isInApplications
        steps = (needsMove ? [.location] : []) + [.finderExtension, .notifications, .folderAccess, .launchAtLogin]
    }

    private var step: Step { steps[index] }
    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Self.rowSpacing) {
                Image(systemName: step.symbol)
                    .font(.system(size: Self.symbolSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory
                    .padding(.top, Self.accessoryTopPadding)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(.opacity)
            Divider()
            HStack {
                Button("Back") { move(by: -1) }
                    .disabled(index == 0)
                Spacer()
                Button(isLast ? "Done" : "Continue", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .location && location.isTranslocated)
            }
            .overlay { progress }
            .padding()
        }
        .frame(width: Self.width, height: Self.height)
        .task { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    private var progress: some View {
        HStack(spacing: Self.dotSpacing) {
            ForEach(steps.indices, id: \.self) { position in
                Circle()
                    .fill(position == index ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(index + 1) of \(steps.count)", comment: "Onboarding progress"))
    }

    private var message: String {
        switch step {
        case .location:
            location.isTranslocated
                ? String(
                    localized:
                        "macOS is running MacEase from a temporary copy, so the Finder menu cannot reach it. Quit MacEase, drag it into the Applications folder, then open it from there."
                )
                : String(
                    localized:
                        "MacEase works best from the Applications folder. Quit MacEase, drag it into Applications, then open it from there."
                )
        case .finderExtension:
            String(
                localized:
                    "The MacEase item in Finder's right-click menu comes from a Finder extension. Turn it on in System Settings."
            )
        case .notifications:
            String(
                localized:
                    "MacEase tells you when a batch finishes, with buttons to undo it or show the results. Without notifications, results appear only in the menu bar."
            )
        case .folderAccess:
            String(
                localized:
                    "The first time MacEase works on files in Desktop, Documents, Downloads, or on an external or network volume, macOS asks once for access. Allow it to continue. To skip these questions, give MacEase Full Disk Access."
            )
        case .launchAtLogin:
            String(
                localized:
                    "When MacEase is already running, the Finder menu responds instantly. MacEase stays in the menu bar and uses almost no resources while idle."
            )
        }
    }

    @ViewBuilder private var accessory: some View {
        switch step {
        case .location:
            Button("Quit MacEase") { NSApp.terminate(nil) }
                .controlSize(.large)
        case .finderExtension:
            StatusLabel(
                isOn: extensionEnabled,
                text: extensionEnabled
                    ? String(localized: "The Finder extension is on.")
                    : String(localized: "The Finder extension is off."))
            Button("Open Extension Settings") { FIFinderSyncController.showExtensionManagementInterface() }
                .controlSize(.large)
        case .notifications:
            switch notificationStatus {
            case .notDetermined:
                Button("Allow Notifications", action: requestNotifications)
                    .controlSize(.large)
            case .denied:
                StatusLabel(isOn: false, text: String(localized: "Notifications are off."))
                Button("Open Notification Settings") { SystemSettingsPane.open(SystemSettingsPane.notifications) }
            default:
                StatusLabel(isOn: true, text: String(localized: "Notifications are on."))
            }
        case .folderAccess:
            Button("Open Full Disk Access Settings") { SystemSettingsPane.open(SystemSettingsPane.fullDiskAccess) }
                .controlSize(.large)
        case .launchAtLogin:
            Toggle("Launch MacEase at login", isOn: $launchesAtLogin)
                .toggleStyle(.switch)
        }
    }

    private func move(by offset: Int) {
        failure = nil
        withAnimation(Self.stepFade) { index += offset }
    }

    private func advance() {
        guard isLast else {
            move(by: 1)
            return
        }
        do {
            if launchesAtLogin != (LoginItem.status == .enabled) {
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

    private enum Step {
        case location
        case finderExtension
        case notifications
        case folderAccess
        case launchAtLogin

        var symbol: String {
            switch self {
            case .location: "folder.badge.questionmark"
            case .finderExtension: "puzzlepiece.extension"
            case .notifications: "bell.badge"
            case .folderAccess: "lock.shield"
            case .launchAtLogin: "power"
            }
        }

        var title: String {
            switch self {
            case .location: String(localized: "Move MacEase to Applications", comment: "Onboarding step title")
            case .finderExtension: String(localized: "Turn On the Finder Extension", comment: "Onboarding step title")
            case .notifications:
                String(localized: "Get Notified When Files Are Ready", comment: "Onboarding step title")
            case .folderAccess: String(localized: "Folder Access", comment: "Onboarding step title")
            case .launchAtLogin: String(localized: "Launch at Login", comment: "Onboarding step title")
            }
        }
    }
}

private struct StatusLabel: View {
    let isOn: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: isOn ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isOn ? .green : .orange)
    }
}
