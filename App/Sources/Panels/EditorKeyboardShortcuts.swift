import AppKit
import SwiftUI

struct EditorKeyboardShortcuts: NSViewRepresentable {
    let model: MediaEditorModel

    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ShortcutView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        var model: MediaEditorModel?
        private var monitor: Any?

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, event.window === self.window, let model = self.model, model.ready,
                        !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField)
                    else { return false }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    if modifiers == .command, event.charactersIgnoringModifiers == "b", model.isVideo {
                        model.split(); return true
                    }
                    guard modifiers.isEmpty else { return false }
                    switch event.keyCode {
                    case 46: model.original.toggle()
                    case 49 where model.isVideo: model.play()
                    case 123 where model.isVideo && model.category != .crop: model.stepFrame(-1)
                    case 124 where model.isVideo && model.category != .crop: model.stepFrame(1)
                    case 51 where model.isVideo, 117 where model.isVideo:
                        model.deleteSelection()
                    default: return false
                    }
                    return true
                }
                return consumed ? nil : event
            }
        }
    }
}
