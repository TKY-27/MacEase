import AppKit

/// Releasing closed windows keeps idle memory low.
@MainActor
final class SingleWindowPresenter: NSObject, NSWindowDelegate {
    private let makeWindow: () -> NSWindow
    private var window: NSWindow?

    init(makeWindow: @escaping () -> NSWindow) {
        self.makeWindow = makeWindow
    }

    func show() {
        let isNew = self.window == nil
        let window = self.window ?? makeWindow()
        if isNew {
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // SwiftUI sizes content only once ordered in.
        if isNew { window.center() }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
