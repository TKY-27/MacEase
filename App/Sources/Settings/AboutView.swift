import AppKit
import SwiftUI

struct AboutView: View {
    @State private var notices: String?
    @State private var failure: String?

    private static let repository = URL(string: "https://github.com/TKY-27/MacEase")
    private static let license = URL(string: "https://github.com/TKY-27/MacEase/blob/main/LICENSE")
    private static let iconSize: CGFloat = 96
    private static let rowSpacing: CGFloat = 12
    private static let linkSpacing: CGFloat = 16
    private static let linkTopPadding: CGFloat = 4
    private static let margin: CGFloat = 32
    /// Leaves room for the notices sheet.
    private static let minHeight: CGFloat = 440
    private static let noticesWidth: CGFloat = 580
    private static let noticesHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            Text(Self.info("CFBundleName"))
                .font(.title.bold())
            Text("Version \(Self.info("CFBundleShortVersionString")) (\(Self.info("CFBundleVersion")))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Convert, compress and tidy files from the Finder menu.")
                .multilineTextAlignment(.center)
            HStack(spacing: Self.linkSpacing) {
                if let repository = Self.repository {
                    Link(destination: repository) { Label("GitHub", systemImage: "arrow.up.right.square") }
                }
                if let license = Self.license {
                    Link(destination: license) { Label("MIT License", systemImage: "doc.text") }
                }
                Button("Third-Party Notices", action: showNotices)
            }
            .padding(.top, Self.linkTopPadding)
            Text(Self.info("NSHumanReadableCopyright"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .padding(Self.margin)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight)
        .sheet(isPresented: isPresent($notices)) {
            NoticesSheet(text: notices ?? "")
                .frame(width: Self.noticesWidth, height: Self.noticesHeight)
        }
    }

    private func showNotices() {
        do {
            guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else {
                throw CocoaError(.fileNoSuchFile)
            }
            notices = try String(contentsOf: url, encoding: .utf8)
        } catch {
            failure = String(localized: "The notices could not be opened: \(error.localizedDescription)")
        }
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

private struct NoticesSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}
