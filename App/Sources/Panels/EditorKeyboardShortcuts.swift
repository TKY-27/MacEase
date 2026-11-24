import AppKit
import SwiftUI

struct EditorKeyboardShortcuts: NSViewRepresentable {
    let model: MediaEditorModel?
    let audio: AudioTrimModel?
    var save: (() -> Void)?
    var saveFrame: (() -> Void)?
    var close: (() -> Void)?

    init(
        model: MediaEditorModel, save: @escaping () -> Void, saveFrame: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.model = model
        audio = nil
        self.save = save
        self.saveFrame = saveFrame
        self.close = close
    }
    init(audio: AudioTrimModel) { model = nil; self.audio = audio }

    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.model = model
        view.audio = audio
        view.save = save
        view.saveFrame = saveFrame
        view.close = close
        return view
    }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.model = model
        view.audio = audio
        view.save = save
        view.saveFrame = saveFrame
        view.close = close
    }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        var model: MediaEditorModel?
        var audio: AudioTrimModel?
        var save: (() -> Void)?
        var saveFrame: (() -> Void)?
        var close: (() -> Void)?
        private var monitor: Any?
        private enum ArrowKey {
            static let left: UInt16 = 123
            static let right: UInt16 = 124
            static let down: UInt16 = 125
            static let up: UInt16 = 126
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return consumed ? nil : event
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> Bool {
            guard event.window === window,
                !(window?.firstResponder is NSTextView), !(window?.firstResponder is NSTextField)
            else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            if let audio, audio.ready { return audioShortcut(event, modifiers: modifiers, audio: audio) }
            guard let model else { return false }
            let character = event.charactersIgnoringModifiers?.lowercased()
            if modifiers.isEmpty, character == "\u{1b}" {
                handleEscape(model: model)
                return true
            }
            guard model.ready, !model.editingLocked else { return false }
            if model.category == .markup, markupShortcut(event, modifiers: modifiers, model: model) {
                return true
            }
            if modifiers == .command, character == "b", model.isVideo { model.split(); return true }
            if modifiers == .option, character == "f", model.isVideo { model.insertFreezeFrame(); return true }
            if modifiers == .command, character == "z" { model.undo(); return true }
            if modifiers == [.command, .shift], character == "z" { model.redo(); return true }
            if modifiers == [.command, .shift], character == "s", model.canSaveFrame {
                saveFrame?(); return true
            }
            if modifiers.isEmpty, character == "\r" {
                if model.showsSilencePreview {
                    if model.canApplySilence { model.removeSilence(model.silenceRule) }
                    return true
                }
                if model.canSave { save?(); return true }
            }
            if zoomShortcut(character, modifiers: modifiers, model: model) { return true }
            guard modifiers.isEmpty else { return false }
            return plainShortcut(event, character: character, model: model)
        }

        private func handleEscape(model: MediaEditorModel) {
            if model.showsSilencePreview {
                model.cancelSilenceAnalysis()
                model.showsSilencePreview = false
            } else if !model.editingLocked, model.category == .markup, model.values.selectedOverlayID != nil {
                model.selectOverlay(nil)
            } else if !model.editingLocked, model.category == .markup, model.markupTool != .select {
                model.markupTool = .select
            } else {
                close?()
            }
        }

        private func zoomShortcut(
            _ character: String?, modifiers: NSEvent.ModifierFlags, model: MediaEditorModel
        ) -> Bool {
            if modifiers == .shift, character == "z", model.isVideo {
                model.timelineZoom = 1
                return true
            }
            guard modifiers == .command || modifiers == [.command, .shift] else { return false }
            switch character {
            case "=", "+":
                if model.isVideo {
                    model.zoomTimeline(by: 2)
                } else if model.category != .crop {
                    model.setPhotoZoom(model.zoom * 2)
                } else {
                    return false
                }
            case "-" where modifiers == .command:
                if model.isVideo {
                    model.zoomTimeline(by: 0.5)
                } else if model.category != .crop {
                    model.setPhotoZoom(model.zoom / 2)
                } else {
                    return false
                }
            case "0" where modifiers == .command && !model.isVideo && model.category != .crop:
                model.setPhotoZoom(1)
            default: return false
            }
            return true
        }

        private func plainShortcut(_ event: NSEvent, character: String?, model: MediaEditorModel) -> Bool {
            switch character {
            case "i" where model.isVideo: model.setTrimBoundaryAtPlayhead(start: true)
            case "o" where model.isVideo: model.setTrimBoundaryAtPlayhead(start: false)
            case "m": model.original.toggle()
            case " " where model.isVideo: model.play()
            case "j" where model.isVideo: model.shuttle(-1)
            case "k" where model.isVideo: model.shuttle(0)
            case "l" where model.isVideo: model.shuttle(1)
            case "\u{7f}" where model.isVideo, "\u{f728}" where model.isVideo: model.deleteSelection()
            default:
                guard model.isVideo, model.category != .crop else { return false }
                switch event.keyCode {
                case ArrowKey.left: model.stepFrame(-1)
                case ArrowKey.right: model.stepFrame(1)
                case ArrowKey.up: model.jumpToSegmentBoundary(forward: false)
                case ArrowKey.down: model.jumpToSegmentBoundary(forward: true)
                default: return false
                }
            }
            return true
        }

        /// Unhandled keys reach the editor shortcuts.
        private func markupShortcut(
            _ event: NSEvent, modifiers: NSEvent.ModifierFlags, model: MediaEditorModel
        ) -> Bool {
            let selected = model.values.selectedOverlayID
            if modifiers.isEmpty || modifiers == .shift, let selected {
                let step = modifiers == .shift ? MediaEditorModel.overlayLargeNudge : MediaEditorModel.overlayNudge
                switch event.keyCode {
                case ArrowKey.left: model.nudgeOverlay(selected, dx: -step, dy: 0); return true
                case ArrowKey.right: model.nudgeOverlay(selected, dx: step, dy: 0); return true
                case ArrowKey.up: model.nudgeOverlay(selected, dx: 0, dy: -step); return true
                case ArrowKey.down: model.nudgeOverlay(selected, dx: 0, dy: step); return true
                default: break
                }
            }
            guard modifiers.isEmpty else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "\u{7f}", "\u{f728}":
                if let selected { model.deleteOverlay(selected) }
                return true
            case "i" where model.isVideo && selected != nil:
                model.setOverlayBoundaryAtPlayhead(start: true)
            case "o" where model.isVideo && selected != nil:
                model.setOverlayBoundaryAtPlayhead(start: false)
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
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": audio.play()
            case "j": audio.shuttle(-1)
            case "k": audio.shuttle(0)
            case "l": audio.shuttle(1)
            case "i": audio.setBoundary(start: true)
            case "o": audio.setBoundary(start: false)
            default:
                switch event.keyCode {
                case ArrowKey.left: audio.seek(audio.position - 1 / audio.sampleRate)
                case ArrowKey.right: audio.seek(audio.position + 1 / audio.sampleRate)
                default: return false
                }
            }
            return true
        }
    }
}
