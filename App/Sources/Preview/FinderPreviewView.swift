import AppKit
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
    var kind: PreviewKind?
    var fileFailure: String?
    var dock: FinderPreviewGeometry.Dock = .right
    var docked = true

    var selectedURL: URL? { urls.indices.contains(selectedIndex) ? urls[selectedIndex] : nil }
}

struct FinderPreviewView: View {
    let state: FinderPreviewState
    let close: () -> Void
    let retry: () -> Void
    let select: (Int) -> Void
    let resize: (CGFloat) -> Void
    @State private var accessoryWidth: CGFloat = 0
    @Environment(\.displayScale) private var displayScale
    private static let resizeEdgeWidth: CGFloat = 5
    private static let keyboardResizeStep: CGFloat = 20

    var body: some View {
        content
            .environment(\.previewBarTrailingInset, state.docked ? accessoryWidth : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topTrailing) {
                if state.docked { accessories }
            }
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

    private var accessories: some View {
        HStack(spacing: 8) {
            if state.urls.count > 1 { selectionStepper }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(PreviewButtonStyle(cornerRadius: 12, restingOpacity: 0.06))
            .help(Text("Close Preview"))
            .accessibilityLabel(Text("Close Preview"))
        }
        .padding(.trailing, PreviewLayout.margin - 4)
        .frame(minHeight: PreviewLayout.barHeight)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            accessoryWidth = $0
        }
        .accessibilitySortPriority(1)
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
            barred {
                PreviewMessage(symbol: notice.symbol, message: Text(notice.text)) {
                    switch notice {
                    case .accessibility:
                        Button("Open Accessibility Settings") {
                            SystemSettingsPane.open(SystemSettingsPane.accessibility)
                        }
                        .buttonStyle(.borderedProminent)
                    case .automation:
                        Button("Open Automation Settings") { SystemSettingsPane.open(SystemSettingsPane.automation) }
                            .buttonStyle(.borderedProminent)
                    case .unavailable, .timedOut:
                        EmptyView()
                    }
                    Button("Try Again", action: retry)
                }
            }
        } else if let failure = state.fileFailure {
            barred { PreviewMessage(symbol: "exclamationmark.triangle", message: Text(failure)) { EmptyView() } }
        } else if let url = state.selectedURL {
            if let kind = state.kind {
                PreviewContent(url: url, kind: kind).id(state.generation)
            } else {
                barred { Color.clear }
            }
        } else {
            barred {
                PreviewMessage(
                    symbol: "doc.viewfinder", title: Text("No Selection"),
                    message: Text("Select a file in Finder to preview it.")
                ) { EmptyView() }
            }
        }
    }

    private func barred(@ViewBuilder _ body: () -> some View) -> some View {
        VStack(spacing: 0) {
            if state.docked { PreviewToolbar {} }
            body().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
