import AppKit
import SwiftUI

private final class FeatureWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class FeatureWindowHost: NSObject, NSWindowDelegate {
    private struct OwnedWindow {
        let window: NSWindow
        let cleanup: @MainActor () async -> Void
    }

    private var windows: [ObjectIdentifier: OwnedWindow] = [:]
    private var closing: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func show<Content: View>(
        title: String, minimumSize: NSSize = NSSize(width: 850, height: 560),
        onClose: @escaping @MainActor () async -> Void,
        content: (_ close: @escaping () -> Void) -> Content
    ) -> NSWindow {
        let window = FeatureWindow(
            contentRect: NSRect(origin: .zero, size: minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.contentMinSize = minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: content { [weak window] in
                window?.performClose(nil)
            })
        window.setContentSize(minimumSize)
        windows[ObjectIdentifier(window)] = OwnedWindow(window: window, cleanup: onClose)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        beginClose(sender)
        return false
    }

    func closeAll() async {
        for owned in Array(windows.values) { beginClose(owned.window) }
        for task in Array(closing.values) { await task.value }
    }

    private func beginClose(_ window: NSWindow) {
        guard let owned = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        window.orderOut(nil)
        window.contentViewController = nil
        let id = UUID()
        let task = Task { [weak self] in
            await owned.cleanup()
            owned.window.delegate = nil
            owned.window.close()
            self?.closing.removeValue(forKey: id)
        }
        closing[id] = task
    }
}
