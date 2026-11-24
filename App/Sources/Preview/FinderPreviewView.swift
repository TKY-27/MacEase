import AppKit
import Engine
import MenuCatalog
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

        var symbol: String {
            switch self {
            case .accessibility: "accessibility"
            case .automation: "hand.raised"
            case .unavailable, .timedOut: "exclamationmark.triangle"
            }
        }
    }

    var generation: UInt64 = 0
    var urls: [URL] = []
    var selectedIndex = 0
    var notice: Notice?
    var details: PreviewFileDetails?
    var fileFailure: String?
    var dock: FinderPreviewGeometry.Dock = .right
    var docked = true

    var selectedURL: URL? { urls.indices.contains(selectedIndex) ? urls[selectedIndex] : nil }
}

enum PreviewLayout {
    static let margin: CGFloat = 16
    static let toolbarHeight: CGFloat = 36
    static let previewCornerRadius: CGFloat = 8
}

struct FinderPreviewView: View {
    let state: FinderPreviewState
    let close: () -> Void
    let retry: () -> Void
    let select: (Int) -> Void
    let open: (URL) -> Void
    let edit: (URL) -> Void
    let resize: (CGFloat) -> Void
    @Environment(\.displayScale) private var displayScale
    // Matches the height of Finder's toolbar.
    private static let dockedHeaderHeight: CGFloat = 52
    private static let resizeEdgeWidth: CGFloat = 5
    private static let keyboardResizeStep: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            if state.docked || state.urls.count > 1 {
                header
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let url = state.selectedURL, let details = state.details, state.notice == nil, state.fileFailure == nil {
                Divider()
                actions(url, details: details)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: state.dock == .left ? .trailing : .leading) {
            if state.docked && state.dock != .inset {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1 / displayScale)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: state.dock.resizesLeadingEdge ? .leading : .trailing) {
            if state.docked { resizeEdge }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if state.docked {
                Text("Finder Preview").font(.headline).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if state.urls.count > 1 { selectionStepper }
            if state.docked {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(PreviewButtonStyle(cornerRadius: 12, restingOpacity: 0.06))
                .help(Text("Close Preview"))
                .accessibilityLabel(Text("Close Preview"))
            }
        }
        .padding(.leading, PreviewLayout.margin)
        .padding(.trailing, PreviewLayout.margin - 4)
        .frame(height: state.docked ? Self.dockedHeaderHeight : PreviewLayout.toolbarHeight)
    }

    private var selectionStepper: some View {
        HStack(spacing: 2) {
            Button {
                select(state.selectedIndex - 1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 22, height: 22)
            }
            .disabled(state.selectedIndex == 0)
            .accessibilityLabel(Text("Previous File"))
            Text("\(state.selectedIndex + 1) of \(state.urls.count)")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Button {
                select(state.selectedIndex + 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 22, height: 22)
            }
            .disabled(state.selectedIndex == state.urls.count - 1)
            .accessibilityLabel(Text("Next File"))
        }
        .buttonStyle(PreviewButtonStyle(cornerRadius: 6, restingOpacity: 0))
    }

    private var resizeEdge: some View {
        PreviewResizeEdge(leading: state.dock.resizesLeadingEdge, resize: resize)
            .frame(width: Self.resizeEdgeWidth)
            .accessibilityLabel(Text("Preview Width"))
            .accessibilityAdjustableAction { direction in
                let growth = direction == .increment ? Self.keyboardResizeStep : -Self.keyboardResizeStep
                resize(state.dock.resizesLeadingEdge ? -growth : growth)
            }
    }

    @ViewBuilder private var content: some View {
        if let notice = state.notice {
            PreviewMessage(symbol: notice.symbol, message: Text(notice.text)) {
                switch notice {
                case .accessibility:
                    Button("Open Accessibility Settings") { SystemSettingsPane.open(SystemSettingsPane.accessibility) }
                        .buttonStyle(.borderedProminent)
                case .automation:
                    Button("Open Automation Settings") { SystemSettingsPane.open(SystemSettingsPane.automation) }
                        .buttonStyle(.borderedProminent)
                case .unavailable, .timedOut:
                    EmptyView()
                }
                Button("Try Again", action: retry)
            }
        } else if let failure = state.fileFailure {
            PreviewMessage(symbol: "exclamationmark.triangle", message: Text(failure)) { EmptyView() }
        } else if let url = state.selectedURL {
            if let details = state.details {
                PreviewFilePane(url: url, details: details).id(state.generation)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(Text("Reading File"))
            }
        } else {
            PreviewMessage(
                symbol: "doc.viewfinder", title: Text("No Selection"),
                message: Text("Select a file in Finder to preview it.")
            ) { EmptyView() }
        }
    }

    private func actions(_ url: URL, details: PreviewFileDetails) -> some View {
        let fileKind = FileKind(fileURL: url)
        return HStack(spacing: 8) {
            PreviewActionButton(title: Text("Open"), symbol: "arrow.up.forward.app") { open(url) }
            if !details.isFolder && (fileKind == .image || fileKind == .video) {
                PreviewActionButton(title: Text("Edit in MacEase"), symbol: "slider.horizontal.3") { edit(url) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct PreviewFilePane: View {
    let url: URL
    let details: PreviewFileDetails
    @State private var width: CGFloat = 0
    @State private var showsInformation: Bool
    private static let folderIconSize: CGFloat = 128
    private static let fallbackAspectRatio: CGFloat = 4 / 3

    init(url: URL, details: PreviewFileDetails) {
        self.url = url
        self.details = details
        _showsInformation = State(initialValue: details.isFolder || !details.kind.fillsPane)
    }

    var body: some View {
        if details.isFolder || !details.kind.fillsPane {
            ScrollView {
                VStack(spacing: 0) {
                    if details.isFolder {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                            .frame(width: Self.folderIconSize, height: Self.folderIconSize)
                            .padding(.top, PreviewLayout.margin * 2)
                            .accessibilityHidden(true)
                    } else {
                        PreviewContent(url: url, kind: details.kind, previewHeight: previewHeight)
                    }
                    summary
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            VStack(spacing: 0) {
                PreviewContent(url: url, kind: details.kind, previewHeight: nil)
                    .frame(maxHeight: .infinity)
                Divider()
                summary
            }
        }
    }

    private var previewHeight: CGFloat {
        FinderPreviewGeometry.previewHeight(
            width: max(0, width - PreviewLayout.margin * 2),
            aspectRatio: details.aspectRatio ?? Self.fallbackAspectRatio)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: url.lastPathComponent)
                .font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
            Text(verbatim: details.subtitle).foregroundStyle(.secondary).padding(.top, 2)
            if !details.facts.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Information").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button(showsInformation ? "Show Less" : "Show More") { showsInformation.toggle() }
                        .buttonStyle(.link).font(.callout)
                }
                .padding(.top, PreviewLayout.margin)
                if showsInformation { facts }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PreviewLayout.margin)
    }

    private var facts: some View {
        VStack(spacing: 0) {
            ForEach(Array(details.facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: fact.label).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(verbatim: fact.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                }
                .font(.callout)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 6)
    }
}

private struct PreviewMessage<Actions: View>: View {
    let symbol: String
    var title: Text?
    let message: Text
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary).accessibilityHidden(true)
                .padding(.bottom, 4)
            if let title { title.font(.headline) }
            message.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) { actions }.padding(.top, 8)
        }
        .padding(PreviewLayout.margin * 2)
    }
}

private struct PreviewActionButton: View {
    let title: Text
    let symbol: String
    let action: () -> Void
    private static let width: CGFloat = 88

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17)).frame(height: 22).accessibilityHidden(true)
                title.font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: Self.width)
            .padding(.vertical, 6)
        }
        .buttonStyle(PreviewButtonStyle(cornerRadius: 8, restingOpacity: 0))
    }
}

struct PreviewButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let restingOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, cornerRadius: cornerRadius, restingOpacity: restingOpacity)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let restingOpacity: Double
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(fill), in: shape)
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }

        private var fill: Double {
            guard isEnabled else { return restingOpacity }
            if configuration.isPressed { return 0.14 }
            return hovering ? 0.08 : restingOpacity
        }
    }
}

struct QuickLookPreview: NSViewRepresentable {
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
