import AppKit
import MenuCatalog
import SwiftUI
import os

/// Esc must close every panel.
private final class FloatingPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Centered on the screen under the pointer.
@MainActor
final class PanelHost: NSObject, NSWindowDelegate {
    private var panels: [NSWindow] = []

    func show<Content: View>(title: String, content: (_ close: @escaping () -> Void) -> Content) {
        let panel = FloatingPanel(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = title
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Finder may be in full screen.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let controller = NSHostingController(rootView: content { [weak panel] in panel?.close() })
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        panel.setContentSize(controller.view.fittingSize)
        panels.append(panel)
        center(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func center(_ panel: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    /// Async content can grow a panel off-screen.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let visible = window.screen?.visibleFrame,
            !visible.contains(window.frame)
        else { return }
        center(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Tearing down the view cancels its scans.
        window.contentViewController = nil
        panels.removeAll { $0 === window }
    }
}

/// Last panel values per operation.
enum PanelMemory {
    private static let logger = Logger(category: "panels")

    static func value<Value: Codable>(for op: OperationID, default fallback: Value) -> Value {
        guard let stored = UserDefaults.standard.data(forKey: key(op)) else { return fallback }
        do {
            return try JSONDecoder().decode(Value.self, from: stored)
        } catch {
            logger.error("Panel values for \(op.rawValue, privacy: .public) unreadable: \(error, privacy: .public)")
            return fallback
        }
    }

    static func remember<Value: Codable>(_ value: Value, for op: OperationID) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key(op))
        } catch {
            logger.error("Panel values for \(op.rawValue, privacy: .public) not saved: \(error, privacy: .public)")
        }
    }

    private static func key(_ op: OperationID) -> String {
        "panel.\(op.rawValue)"
    }
}
