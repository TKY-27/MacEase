import AppKit
import SwiftUI

enum PreviewFindDirection: Sendable {
    case forward, backward
}

struct PreviewFindOutcome: Equatable, Sendable {
    static let notFound = Self(found: false)

    let found: Bool
    // One-based; nil when the viewer cannot count.
    var current: Int?
    var total: Int?
}

// Text, web and PDF search differently.
@MainActor
protocol PreviewFindTarget: AnyObject {
    func find(_ query: String, direction: PreviewFindDirection, restart: Bool) async -> PreviewFindOutcome
    func endFind()
}

// Owned per file; new selections reset it.
@MainActor
@Observable
final class PreviewFind {
    var isPresented = false
    var query = "" {
        didSet {
            if query != oldValue { search(.forward, restart: true) }
        }
    }
    private(set) var outcome: PreviewFindOutcome?
    private(set) var focusRequest = 0
    @ObservationIgnored private weak var target: (any PreviewFindTarget)?
    @ObservationIgnored private var running: Task<Void, Never>?

    func present() {
        isPresented = true
        focusRequest += 1
        search(.forward, restart: true)
    }

    func dismiss() {
        running?.cancel()
        isPresented = false
        outcome = nil
        target?.endFind()
    }

    func next() { search(.forward, restart: false) }

    func previous() { search(.backward, restart: false) }

    func attach(_ newTarget: any PreviewFindTarget) {
        target = newTarget
        search(.forward, restart: true)
    }

    func detach(_ oldTarget: any PreviewFindTarget) {
        guard target === oldTarget else { return }
        running?.cancel()
        target = nil
        outcome = nil
    }

    private func search(_ direction: PreviewFindDirection, restart: Bool) {
        running?.cancel()
        guard isPresented, let target, !query.isEmpty else {
            outcome = nil
            return
        }
        let query = query
        running = Task {
            let result = await target.find(query, direction: direction, restart: restart)
            guard !Task.isCancelled else { return }
            outcome = result
        }
    }
}

struct PreviewFindButton: View {
    let find: PreviewFind

    var body: some View {
        Button(action: find.present) {
            Image(systemName: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        .help(Text("Find"))
        .accessibilityLabel(Text("Find"))
    }
}

// Modeled on Safari's find banner.
struct PreviewFindBar: View {
    @Bindable var find: PreviewFind
    private static let height: CGFloat = 36
    private static let minimumFieldWidth: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PreviewSearchField(
                    text: $find.query, focusRequest: find.focusRequest,
                    submit: { $0 == .forward ? find.next() : find.previous() }, cancel: find.dismiss
                )
                .frame(minWidth: Self.minimumFieldWidth, maxWidth: .infinity)
                status
                HStack(spacing: 0) {
                    Button(action: find.previous) {
                        Image(systemName: "chevron.left").frame(width: 22, height: 22)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help(Text("Find Previous"))
                    .accessibilityLabel(Text("Find Previous"))
                    Button(action: find.next) {
                        Image(systemName: "chevron.right").frame(width: 22, height: 22)
                    }
                    .keyboardShortcut("g", modifiers: .command)
                    .help(Text("Find Next"))
                    .accessibilityLabel(Text("Find Next"))
                }
                .buttonStyle(PreviewButtonStyle(cornerRadius: 6, restingOpacity: 0))
                .disabled(find.outcome?.found != true)
                Button("Done", action: find.dismiss)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, PreviewLayout.margin)
            .frame(height: Self.height)
            Divider()
        }

        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Find"))
    }

    @ViewBuilder private var status: some View {
        if let outcome = find.outcome {
            Group {
                if !outcome.found {
                    Text("Not found")
                } else if let current = outcome.current, let total = outcome.total {
                    Text("\(current) of \(total)")
                }
            }
            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
            .layoutPriority(1)
        }
    }
}

private struct PreviewSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let submit: (PreviewFindDirection) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    func makeNSView(context: Context) -> PreviewSearchFieldView {
        let field = PreviewSearchFieldView()
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.placeholderString = String(localized: "Find")
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(String(localized: "Find"))
        return field
    }

    func updateNSView(_ field: PreviewSearchFieldView, context: Context) {
        context.coordinator.field = self
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.appliedFocusRequest != focusRequest else { return }
        context.coordinator.appliedFocusRequest = focusRequest
        field.wantsFocus = true
        Task { @MainActor in field.focusIfNeeded() }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: PreviewSearchField
        var appliedFocusRequest = 0

        init(field: PreviewSearchField) { self.field = field }

        func controlTextDidChange(_ notification: Notification) {
            guard let control = notification.object as? NSSearchField else { return }
            field.text = control.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                field.submit(backwards ? .backward : .forward)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.cancel()
                return true
            default:
                return false
            }
        }
    }
}

final class PreviewSearchFieldView: NSSearchField {
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    // New fields join their window later.
    func focusIfNeeded() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeKey()
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}
