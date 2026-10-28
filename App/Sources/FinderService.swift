import AppKit
import MenuCatalog
import SwiftUI
import os

@MainActor
final class FinderService: NSObject {
    private let host = PanelHost()
    private let catalog: () -> MenuFile?
    private let jobs: JobCenter
    private let logger = Logger(category: "services")

    init(catalog: @escaping () -> MenuFile?, jobs: JobCenter) {
        self.catalog = catalog
        self.jobs = jobs
    }

    @objc func processFiles(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        logger.info("Finder service requested")
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            logger.error(
                "Finder service received no file URLs; types: \(pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "none", privacy: .public)"
            )
            error.pointee = String(localized: "Select files or folders in Finder first.") as NSString
            return
        }
        guard let file = catalog(), file.hostAvailable else {
            logger.error("Finder service catalog unavailable")
            error.pointee = String(localized: "MacEase is starting. Try the service again.") as NSString
            return
        }
        let allowed = file.entries.filter { MenuLayout.isApplicable($0, selection: urls) }
        guard !allowed.isEmpty else {
            error.pointee = String(localized: "No enabled operations match this selection.") as NSString
            return
        }
        host.show(title: String(localized: "Process with MacEase")) { close in
            ServiceOperationPanel(entries: allowed, selectionCount: urls.count, cancel: close) { entry in
                guard let current = self.catalog(), current.hostAvailable, current.entries.contains(entry) else {
                    return String(localized: "The menu changed. Close this window and choose the service again.")
                }
                close()
                self.jobs.start(entry: entry, inputs: urls)
                return nil
            }
        }
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        {
            return urls
        }
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        guard let paths = pasteboard.propertyList(forType: filenames) as? [String],
            paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) })
        else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }
}

private struct ServiceOperationPanel: View {
    let entries: [MenuEntry]
    let selectionCount: Int
    let cancel: () -> Void
    let run: (MenuEntry) -> String?
    @State private var search = ""
    @State private var selected: Int?
    @State private var failure: String?

    private var filtered: [Int] {
        entries.indices.filter { search.isEmpty || title(entries[$0]).localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(selectionCount) selected")
                .foregroundStyle(.secondary)
            TextField("Find an operation", text: $search)
            List(filtered, id: \.self, selection: $selected) { index in
                Text(title(entries[index])).tag(index)
            }
            if let failure { ProblemLabel(text: failure) }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    if let selected, filtered.contains(selected) { failure = run(entries[selected]) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.map { !filtered.contains($0) } ?? true)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }

    private func title(_ entry: MenuEntry) -> String {
        ([MenuStrings.kind(entry.kind)] + entry.path).joined(separator: " › ")
    }
}
