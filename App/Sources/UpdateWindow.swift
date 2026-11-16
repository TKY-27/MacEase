import AppKit
import FinderSync
import SwiftUI

@MainActor
enum UpdateWindow {
    static func make(updates: UpdateChecker, close: @escaping () -> Void) -> NSWindow {
        let content = NSHostingController(rootView: UpdateView(updates: updates, close: close))
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "MacEase Update")
        window.setContentSize(content.view.fittingSize)
        return window
    }
}

private struct UpdateView: View {
    let updates: UpdateChecker
    let close: () -> Void
    private static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                if let version = updates.availableVersion {
                    Text("MacEase v\(version) is available")
                        .font(.title2.bold())
                }
                Text("You have v\(updates.currentVersion)")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("How to update")
                    .font(.headline)
                step(1, "Quit MacEase from the menu bar.")
                step(2, "Move the old MacEase in Applications to the Trash.")
                step(3, "Open the downloaded file and drag MacEase into Applications.")
                step(4, "Open MacEase.")
                step(
                    5,
                    "Turn on MacEase again in System Settings > General > Login Items & Extensions > Finder, and allow folder and privacy access again when macOS asks."
                )
                Button("Open Extension Settings") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            }
            HStack {
                Spacer()
                Button("Later", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Download from Official Site") {
                    NSWorkspace.shared.open(updates.officialDownloadURL)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ instruction: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).")
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)
            Text(instruction)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
