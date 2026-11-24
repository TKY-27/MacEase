import AppKit
import SwiftUI

struct EditorKeyboardShortcuts: NSViewRepresentable {
    let model: MediaEditorModel?
    let audio: AudioTrimModel?

    init(model: MediaEditorModel) { self.model = model; audio = nil }
    init(audio: AudioTrimModel) { model = nil; self.audio = audio }

    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.model = model
        view.audio = audio
        return view
    }

    func updateNSView(_ view: ShortcutView, context: Context) { view.model = model; view.audio = audio }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        var model: MediaEditorModel?
        var audio: AudioTrimModel?
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
                    guard let self, event.window === self.window,
                        !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField)
                    else { return false }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    if let audio = self.audio, audio.ready {
                        return self.audioShortcut(event, modifiers: modifiers, audio: audio)
                    }
                    guard let model = self.model, model.ready, !model.editingLocked else { return false }
                    if model.category == .markup, self.markupShortcut(event, modifiers: modifiers, model: model) {
                        return true
                    }
                    if modifiers == .command, event.charactersIgnoringModifiers == "b", model.isVideo {
                        model.split(); return true
                    }
                    if modifiers == .option, event.keyCode == 3, model.isVideo {
                        model.insertFreezeFrame(); return true
                    }
                    if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "+", model.isVideo {
                        model.zoomTimeline(by: 2); return true
                    }
                    if modifiers == .command, !model.isVideo, model.category != .crop {
                        switch event.charactersIgnoringModifiers {
                        case "=", "+": model.setPhotoZoom(model.zoom * 2)
                        case "-": model.setPhotoZoom(model.zoom / 2)
                        case "0": model.setPhotoZoom(1)
                        default: return false
                        }
                        return true
                    }
                    if modifiers == .command, model.isVideo {
                        switch event.charactersIgnoringModifiers {
                        case "=", "+": model.zoomTimeline(by: 2)
                        case "-": model.zoomTimeline(by: 0.5)
                        default: return false
                        }
                        return true
                    }
                    if modifiers == .shift, event.charactersIgnoringModifiers?.lowercased() == "z", model.isVideo {
                        model.timelineZoom = 1; return true
                    }
                    guard modifiers.isEmpty else { return false }
                    switch event.keyCode {
                    case 34 where model.isVideo: model.setTrimBoundaryAtPlayhead(start: true)
                    case 31 where model.isVideo: model.setTrimBoundaryAtPlayhead(start: false)
                    case 46: model.original.toggle()
                    case 49 where model.isVideo: model.play()
                    case 38 where model.isVideo: model.shuttle(-1)
                    case 40 where model.isVideo: model.shuttle(0)
                    case 37 where model.isVideo: model.shuttle(1)
                    case 123 where model.isVideo && model.category != .crop: model.stepFrame(-1)
                    case 124 where model.isVideo && model.category != .crop: model.stepFrame(1)
                    case 126 where model.isVideo && model.category != .crop:
                        model.jumpToSegmentBoundary(forward: false)
                    case 125 where model.isVideo && model.category != .crop:
                        model.jumpToSegmentBoundary(forward: true)
                    case 51 where model.isVideo, 117 where model.isVideo:
                        model.deleteSelection()
                    default: return false
                    }
                    return true
                }
                return consumed ? nil : event
            }
        }

        /// Unhandled keys reach the editor shortcuts.
        private func markupShortcut(
            _ event: NSEvent, modifiers: NSEvent.ModifierFlags, model: MediaEditorModel
        ) -> Bool {
            let selected = model.values.selectedOverlayID
            if modifiers.isEmpty || modifiers == .shift, let selected {
                let step = modifiers == .shift ? MediaEditorModel.overlayLargeNudge : MediaEditorModel.overlayNudge
                switch event.keyCode {
                case 123: model.nudgeOverlay(selected, dx: -step, dy: 0); return true
                case 124: model.nudgeOverlay(selected, dx: step, dy: 0); return true
                case 126: model.nudgeOverlay(selected, dx: 0, dy: -step); return true
                case 125: model.nudgeOverlay(selected, dx: 0, dy: step); return true
                default: break
                }
            }
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case 51, 117:
                if let selected { model.deleteOverlay(selected) }
                return true
            case 34 where model.isVideo && selected != nil:
                Task { await model.setOverlayBoundaryAtPlayhead(start: true) }
            case 31 where model.isVideo && selected != nil:
                Task { await model.setOverlayBoundaryAtPlayhead(start: false) }
            case 53 where selected != nil: model.selectOverlay(nil)
            case 53 where model.markupTool != .select: model.markupTool = .select
            default: return false
            }
            return true
        }

        private func audioShortcut(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, audio: AudioTrimModel) -> Bool {
            if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "+" {
                audio.zoom = min(audio.maximumZoom, audio.zoom * 2); return true
            }
            if modifiers == .command {
                switch event.charactersIgnoringModifiers {
                case "=", "+": audio.zoom = min(audio.maximumZoom, audio.zoom * 2)
                case "-": audio.zoom = max(1, audio.zoom / 2)
                case "z": audio.undo()
                default: return false
                }
                return true
            }
            if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
                audio.redo(); return true
            }
            if modifiers == .shift, event.charactersIgnoringModifiers?.lowercased() == "z" {
                audio.zoom = 1; return true
            }
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case 49: audio.play()
            case 38: audio.shuttle(-1)
            case 40: audio.shuttle(0)
            case 37: audio.shuttle(1)
            case 34: audio.setBoundary(start: true)
            case 31: audio.setBoundary(start: false)
            case 123: audio.seek(audio.position - 1 / audio.sampleRate)
            case 124: audio.seek(audio.position + 1 / audio.sampleRate)
            default: return false
            }
            return true
        }
    }
}
