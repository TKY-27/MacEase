import AppKit
import Engine
import FinderSync
import OSLog
import SwiftUI

struct AdvancedSettingsView: View {
    @Bindable var store: SettingsStore
    let jobs: JobCenter
    let rotateToken: () throws -> Void

    @State private var confirmsClearHistory = false
    @State private var confirmsReset = false
    @State private var status: String?
    @State private var failure: String?

    private static let consoleBundleID = "com.apple.Console"
    private static let statusDuration: Duration = .seconds(3)

    var body: some View {
        Form {
            Section {
                Picker(selection: $store.settings.concurrencyLimit) {
                    Text("Automatic (\(Settings().effectiveConcurrency))", comment: "Default number of parallel jobs")
                        .tag(0)
                    ForEach(1...ProcessInfo.processInfo.activeProcessorCount, id: \.self) { count in
                        Text(count, format: .number).tag(count)
                    }
                } label: {
                    Text("Files processed at once")
                    Text("Lower numbers leave more of your Mac free for other work.")
                }
            }
            Section("Security") {
                LabeledContent {
                    Button("Create New Token", action: rotate)
                } label: {
                    Text("Finder menu token")
                    Text("Replaces the secret that the Finder extension uses to talk to MacEase.")
                }
            }
            Section("History") {
                LabeledContent {
                    Button("Clear History…", role: .destructive) { confirmsClearHistory = true }
                } label: {
                    Text("Undo history")
                    Text("After clearing, past operations can’t be undone.")
                }
            }
            Section {
                LabeledContent {
                    Button("Reset All Settings…", role: .destructive) { confirmsReset = true }
                } label: {
                    Text("Undo history and edited presets are kept.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Troubleshooting") {
                LabeledContent("Logs") {
                    Button("Open Console", action: openConsole)
                }
                LabeledContent {
                    Button("Copy Diagnostics", action: copyDiagnostics)
                } label: {
                    Text("Diagnostics")
                    Text("Copies version information and recent logs for a bug report.")
                }
            }
            if let status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .confirmationDialog("Clear the undo history?", isPresented: $confirmsClearHistory) {
            Button("Clear History", role: .destructive, action: clearHistory)
        } message: {
            Text("Past operations can no longer be undone. Items in the Trash stay there.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                store.resetAll()
                status = String(localized: "All settings were reset.")
            }
        } message: {
            Text("All settings, including the Finder menu layout, return to their defaults.")
        }
        .alert("The action couldn’t be completed.", isPresented: isPresent($failure), presenting: failure) { _ in
            Button("OK") {}
        } message: { text in
            Text(text)
        }
        .task(id: status) {
            guard status != nil else { return }
            do {
                try await Task.sleep(for: Self.statusDuration)
                status = nil
            } catch {
                // A newer status replaced this one.
            }
        }
    }

    private func rotate() {
        do {
            try rotateToken()
            status = String(localized: "A new token was created.")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func clearHistory() {
        Task {
            do {
                try await jobs.engine.history.clear()
                status = String(localized: "History cleared.")
            } catch {
                failure = error.localizedDescription
            }
            await jobs.refreshRecent()
        }
    }

    private func openConsole() {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.consoleBundleID) else {
            failure = String(localized: "Console can’t be found.")
            return
        }
        NSWorkspace.shared.openApplication(at: console, configuration: NSWorkspace.OpenConfiguration())
    }

    private func copyDiagnostics() {
        Task {
            do {
                let report = Diagnostics.summary() + "\n\n" + (try await Diagnostics.recentLogLines())
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                status = String(localized: "Diagnostics copied to the clipboard.")
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

enum Diagnostics {
    private static let logWindow: TimeInterval = 60 * 60
    private static let maxLogLines = 300

    @MainActor
    static func summary() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let location = InstallLocation.current
        return [
            "MacEase \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "?")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Processors: \(ProcessInfo.processInfo.activeProcessorCount)",
            "Finder extension enabled: \(FIFinderSyncController.isExtensionEnabled)",
            "In Applications: \(location.isInApplications), translocated: \(location.isTranslocated)",
        ].joined(separator: "\n")
    }

    /// The slow scan avoids the main actor.
    static func recentLogLines() async throws -> String {
        try await Task.detached {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-logWindow))
            let predicate = NSPredicate(format: "subsystem == %@", Logger.subsystem)
            let lines = try store.getEntries(at: start, matching: predicate)
                .compactMap { $0 as? OSLogEntryLog }
                .map { "\($0.date.ISO8601Format()) [\($0.category)] \($0.composedMessage)" }
            return lines.suffix(maxLogLines).joined(separator: "\n")
        }.value
    }
}
