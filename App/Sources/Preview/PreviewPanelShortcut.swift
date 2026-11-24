import AppKit
import SwiftUI

enum PreviewPanelShortcut: Equatable {
    case previousFile, nextFile, playPause

    private static let space = " "

    func matches(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        return switch self {
        case .previousFile: modifiers == [.command, .option] && event.specialKey == .leftArrow
        case .nextFile: modifiers == [.command, .option] && event.specialKey == .rightArrow
        case .playPause: modifiers.isEmpty && event.charactersIgnoringModifiers == Self.space
        }
    }

    // Text, selections and focused controls win.
    @MainActor
    func isAvailable(firstResponder: NSResponder?, in window: NSWindow?, fullKeyboardAccess: Bool) -> Bool {
        guard let responder = firstResponder, responder !== window else { return true }
        if responder is NSText || responder is any NSTextInputClient || Self.holdsCopyableSelection(responder) {
            return false
        }
        return self != .playPause || !fullKeyboardAccess
    }

    // Copy is enabled only with a selection.
    @MainActor
    private static func holdsCopyableSelection(_ responder: NSResponder) -> Bool {
        let copy = #selector(NSText.copy(_:))
        guard responder.responds(to: copy) else { return false }
        let probe = NSMenuItem(title: "", action: copy, keyEquivalent: "")
        if let validator = responder as? any NSMenuItemValidation { return validator.validateMenuItem(probe) }
        if let validator = responder as? any NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(probe)
        }
        return true
    }
}

extension View {
    // SwiftUI shortcuts ignore the first responder.
    func previewShortcut(_ shortcut: PreviewPanelShortcut, perform action: @escaping () -> Bool) -> some View {
        background(PreviewShortcutReceiver(shortcut: shortcut, action: action))
    }
}

private struct PreviewShortcutReceiver: NSViewRepresentable {
    let shortcut: PreviewPanelShortcut
    let action: () -> Bool

    func makeNSView(context: Context) -> ReceiverView { ReceiverView() }

    func updateNSView(_ view: ReceiverView, context: Context) {
        view.shortcut = shortcut
        view.action = action
    }

    final class ReceiverView: NSView {
        var shortcut = PreviewPanelShortcut.playPause
        var action: (() -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, shortcut.matches(event),
                shortcut.isAvailable(
                    firstResponder: window?.firstResponder, in: window,
                    fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled),
                let action
            else { return super.performKeyEquivalent(with: event) }
            return action()
        }
    }
}
