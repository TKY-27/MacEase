import AppKit
import Engine
import Observation
import Quartz
import SwiftUI
import os

@MainActor
@Observable
final class FinderPreviewState {
    enum Notice {
        case accessibility, automation, unavailable, timedOut

        var text: String {
            switch self {
            case .accessibility: String(localized: "Allow Accessibility access to attach Finder Preview to Finder.")
            case .automation: String(localized: "Allow MacEase to control Finder to follow the selection.")
            case .unavailable: String(localized: "Finder Preview is unavailable. Try again.")
            case .timedOut: String(localized: "Finder did not respond in time. Try again.")
            }
        }
    }

    var urls: [URL] = []
    var selectedIndex = 0
    var notice: Notice?
    var isFolder = false
    var isLoading = false
    var folderSummary: String?
    var fileFailure: String?
    var dock: FinderPreviewGeometry.Dock = .right
    var docked = true

    var selectedURL: URL? { urls.indices.contains(selectedIndex) ? urls[selectedIndex] : nil }
}

struct FinderPreviewView: View {
    @Bindable var state: FinderPreviewState
    let close: () -> Void
    let retry: () -> Void
    let select: (Int) -> Void
    let open: (URL) -> Void
    let edit: (URL) -> Void
    let canEdit: Bool
    let resize: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let url = state.selectedURL, state.notice == nil, state.fileFailure == nil, !state.isLoading {
                Divider()
                HStack {
                    Button("Open") { open(url) }
                    Spacer()
                    if canEdit { Button("Edit in MacEase") { edit(url) } }
                }
                .controlSize(.small)
                .padding(12)
            }
        }
        .background(PreviewSidebar())
        .overlay(alignment: state.dock == .left ? .trailing : .leading) {
            if state.docked {
                PreviewResizeEdge(resize: resize)
                    .frame(width: 6)
                    .accessibilityLabel(Text("Preview Width"))
                    .accessibilityAdjustableAction { direction in
                        let growth: CGFloat = direction == .increment ? 20 : -20
                        resize(state.dock == .left ? growth : -growth)
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let url = state.selectedURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(url.lastPathComponent)
                    if state.urls.count > 1 {
                        HStack(spacing: 6) {
                            Text("\(state.urls.count) items").foregroundStyle(.secondary)
                            Button {
                                select(state.selectedIndex - 1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(state.selectedIndex == 0)
                            .accessibilityLabel(Text("Previous File"))
                            Button {
                                select(state.selectedIndex + 1)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(state.selectedIndex == state.urls.count - 1)
                            .accessibilityLabel(Text("Next File"))
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text("Finder Preview").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Close Preview"))
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if let notice = state.notice {
            VStack(spacing: 12) {
                Text(notice.text).foregroundStyle(.secondary)
                switch notice {
                case .accessibility:
                    Button("Open Accessibility Settings") { SystemSettingsPane.open(SystemSettingsPane.accessibility) }
                case .automation:
                    Button("Open Automation Settings") { SystemSettingsPane.open(SystemSettingsPane.automation) }
                case .unavailable, .timedOut:
                    EmptyView()
                }
                Button("Try Again", action: retry)
            }
            .multilineTextAlignment(.center)
            .padding(20)
        } else if let failure = state.fileFailure {
            Text(failure).foregroundStyle(.secondary).padding(20)
        } else if state.isLoading {
            ProgressView().controlSize(.small).accessibilityLabel(Text("Reading File"))
        } else if let url = state.selectedURL {
            if state.isFolder {
                VStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 64, height: 64)
                    if let summary = state.folderSummary {
                        Text(summary).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel(Text("Reading Folder"))
                    }
                }
                .padding(20)
            } else {
                QuickLookPreview(url: url)
            }
        } else {
            Text("No Selection").foregroundStyle(.secondary)
        }
    }
}

private struct PreviewSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            Logger(category: "finder-preview").error("Quick Look preview view could not be created")
            return NSTextField(labelWithString: String(localized: "This preview could not be displayed."))
        }
        view.autostarts = false
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let preview = nsView as? QLPreviewView else { return }
        if preview.previewItem?.previewItemURL != url { preview.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let preview = nsView as? QLPreviewView else { return }
        preview.previewItem = nil
        preview.close()
    }
}
