import AppKit
import Engine
import SwiftUI

struct FileOriginPanel: View {
    let source: URL
    let close: () -> Void
    @State private var origin: FileOrigin?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(source.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .textSelection(.enabled)
            if let origin {
                if origin.links.isEmpty {
                    Text("No source link is recorded for this file.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recorded sources").font(.subheadline.weight(.semibold))
                        ForEach(origin.links, id: \.self) { link in
                            Link(link.absoluteString, destination: link)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(origin.sha256)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Recorded links can be edited. They do not prove authorship or authenticity.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let failure {
                ProblemLabel(text: failure)
            } else {
                ProgressView("Reading source information…")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 300)
        .task {
            let work = Task.detached { try FileOrigin.inspect(source) }
            do {
                origin = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                failure = UserMessages.describeActivity(error)
            }
        }
    }
}
