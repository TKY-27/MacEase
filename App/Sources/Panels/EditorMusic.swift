import Engine
import SwiftUI
import UniformTypeIdentifiers

extension MediaEditorModel {
    /// Containers `AudioInput` decodes.
    static let musicTypes = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "oga", "opus"]
        .compactMap { UTType(filenameExtension: $0) }
    /// Starts must precede the song's end.
    static let musicStartMargin = 0.001

    var musicChanged: Bool {
        guard let music = values.music else { return false }
        do {
            try music.validateSource()
            return false
        } catch {
            return true
        }
    }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.musicTypes
        if panel.runModal() == .OK, let url = panel.url { setMusic(url) }
    }

    func setMusic(_ url: URL) {
        guard !editingLocked, musicTask == nil else { return }
        musicFailure = nil
        musicTask = Task {
            defer { musicTask = nil }
            do {
                var music = try await Task.detached { try BackgroundMusic.load(from: url) }.value
                try Task.checkCancellation()
                guard !closed else { return }
                if let current = values.music {
                    music.volume = current.volume
                    music.start = min(current.start, max(0, music.duration - Self.musicStartMargin))
                }
                change { $0.music = music }
                musicRevealRequest = UUID()
            } catch is CancellationError {
                return
            } catch {
                musicFailure = describeMusic(error, file: url.lastPathComponent)
                musicRevealRequest = UUID()
            }
        }
    }

    func removeMusic() {
        musicFailure = nil
        change { $0.music = nil }
    }

    func musicBinding(_ keyPath: WritableKeyPath<BackgroundMusic, Double>) -> Binding<Double> {
        Binding(
            get: { self.values.music?[keyPath: keyPath] ?? 0 },
            set: { value in self.change { $0.music?[keyPath: keyPath] = value } })
    }

    func describeMusic(_ error: Error, file: String) -> String {
        switch error {
        case EngineError.decodeFailed, EngineError.unsupportedCodec:
            String(
                localized:
                    "“\(file)” can’t be used as music. Choose an MP3, AAC, WAV, AIFF, FLAC, Ogg or Opus file.")
        default:
            UserMessages.describe(EngineError.wrapping(error, path: file), file: file)
        }
    }
}

/// Background music settings in the Video tab.
struct EditorMusicSection: View {
    @Bindable var model: MediaEditorModel

    var body: some View {
        InspectorSection(String(localized: "Background Music")) {
            if let music = model.values.music {
                Label(music.url.lastPathComponent, systemImage: "music.note")
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    Text("Volume").foregroundStyle(.secondary)
                    Slider(value: model.musicBinding(\.volume), in: 0...1) {
                        Text("Music Volume")
                    } onEditingChanged: { active in
                        active ? model.beginInteraction() : model.endInteraction()
                    }
                    .labelsHidden()
                    Text("\(Int((music.volume * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Start in Song").foregroundStyle(.secondary)
                    EditorNumberField(
                        model: model, title: String(localized: "Start in Song"), id: "music-start",
                        value: model.musicBinding(\.start),
                        range: 0...max(0, music.duration - MediaEditorModel.musicStartMargin), precision: 3,
                        timecode: true)
                }
                Text("Plays once from the start of the video. A longer song fades out over the last second.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Replace…", action: model.chooseMusic)
                    Button("Remove", role: .destructive, action: model.removeMusic)
                }
            } else {
                Button(action: model.chooseMusic) {
                    Label("Add Music…", systemImage: "music.note")
                }
                Text("Plays under the video’s own sound.").font(.caption).foregroundStyle(.secondary)
            }
            if model.musicTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening music…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let failure = model.musicFailure { ProblemLabel(text: failure) }
        }
        .disabled(model.musicTask != nil)
    }
}
