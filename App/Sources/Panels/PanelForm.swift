import Engine
import SwiftUI

enum PanelLayout {
    static let width: CGFloat = 420
    static let wideWidth: CGFloat = 600
    static let listHeight: CGFloat = 280
    static let thumbnailEdge: CGFloat = 48
    static let rowSpacing: CGFloat = 8
}

struct PanelForm<Content: View, Accessory: View>: View {
    let actionTitle: String
    var canRun = true
    var width = PanelLayout.width
    let cancel: () -> Void
    let run: () -> Void
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            PanelBar(actionTitle: actionTitle, canRun: canRun, cancel: cancel, run: run) { accessory }
        }
        .frame(width: width)
    }
}

extension PanelForm where Accessory == EmptyView {
    init(
        actionTitle: String, canRun: Bool = true, width: CGFloat = PanelLayout.width, cancel: @escaping () -> Void,
        run: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) {
        self.init(
            actionTitle: actionTitle, canRun: canRun, width: width, cancel: cancel, run: run,
            accessory: { EmptyView() },
            content: content)
    }
}

/// Return runs the action, Esc cancels.
struct PanelBar<Accessory: View>: View {
    let actionTitle: String
    var canRun = true
    var cancelTitle = String(localized: "Cancel", comment: "Panel button")
    let cancel: () -> Void
    let run: () -> Void
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                accessory
                Spacer()
                Button(cancelTitle, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
            .padding()
        }
    }
}

extension PanelBar where Accessory == EmptyView {
    init(
        actionTitle: String, canRun: Bool = true,
        cancelTitle: String = String(localized: "Cancel", comment: "Panel button"), cancel: @escaping () -> Void,
        run: @escaping () -> Void
    ) {
        self.init(actionTitle: actionTitle, canRun: canRun, cancelTitle: cancelTitle, cancel: cancel, run: run) {
            EmptyView()
        }
    }
}

/// Determinate progress with a Cancel button.
struct ScanProgress: View {
    let title: String
    let fraction: Double
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.rowSpacing) {
            ProgressView(value: fraction) { Text(title) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: PanelLayout.width)
    }
}

struct PanelFailure: View {
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.rowSpacing) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: PanelLayout.width)
    }
}

/// Cancelling the caller cancels the work.
func offMain<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let task = Task.detached(operation: work)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

extension Int64 {
    var fileSize: String { formatted(.byteCount(style: .file)) }
}

extension URL {
    /// Panels show names, never full paths.
    var displayName: String { FileManager.default.displayName(atPath: path) }
}
