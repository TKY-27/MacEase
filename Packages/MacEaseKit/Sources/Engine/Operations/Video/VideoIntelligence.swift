import Formats
import Foundation

public struct SubtitleRequest: Codable, Hashable, Sendable {
    public var format: SubtitleFormat
    /// Empty uses the system locale.
    public var language: String
    public var translation: String?

    public init(format: SubtitleFormat, language: String, translation: String?) {
        self.format = format
        self.language = language
        self.translation = translation
    }
}

public struct VideoBackgroundRequest: Codable, Hashable, Sendable {
    public var mask: MaskSource
    public var fill: BackgroundFill
    public var transparentFormat: TransparentVideoFormat

    public init(mask: MaskSource, fill: BackgroundFill, transparentFormat: TransparentVideoFormat) {
        self.mask = mask
        self.fill = fill
        self.transparentFormat = transparentFormat
    }
}

enum VideoSubtitles {
    private static let speechFormat = AudioTarget(format: .wav, kilobits: 0)

    static func run(_ request: SubtitleRequest, url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        guard let track = input.audio, case .audio(let sampleRate, _) = track.kind else {
            throw EngineError.invalidInput(.malformed("no audio track"))
        }
        let speech = try context.stagingURL(for: url, name: "speech.wav")
        try await VideoAudio.encode(input, track: track, sampleRate: sampleRate, target: speechFormat, to: speech) {
            context.progress($0 / 2)
        }
        let locale = request.language.isEmpty ? Locale.current : Locale(identifier: request.language)
        var cues = Subtitles.cues(from: try await Subtitles.transcribe(audioFile: speech, locale: locale))
        guard !cues.isEmpty else { return .skipped(.noTextFound) }
        var suffix = ""
        if let target = request.translation {
            cues = try await Subtitles.translated(cues, from: locale.language, to: Locale.Language(identifier: target))
            suffix = "." + target
        }
        let text: String =
            switch request.format {
            case .srt: Subtitles.srt(cues)
            case .vtt: Subtitles.vtt(cues)
            case .txt: Subtitles.plainText(cues)
            }
        let name = url.deletingPathExtension().lastPathComponent + suffix + "." + request.format.rawValue
        let output = try context.stagingURL(for: url, name: name)
        try Data(text.utf8).write(to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .text(.utf8))])
    }
}

enum VideoBackgroundRemoval {
    static func run(_ request: VideoBackgroundRequest, url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        guard let source = input.video else { throw EngineError.invalidInput(.malformed("no video track")) }
        var encoding = VideoEdits.encoding(input, source: source, settings: context.settings.video)
        let container: OutputContainer
        switch (request.fill, request.transparentFormat) {
        case (.transparent, .hevcAlpha):
            container = .mov
            encoding.codec = .hevc
            encoding.alpha = true
        case (.transparent, .proRes4444):
            container = .mov
            encoding.codec = .prores4444
        case (.transparent, .vp9AlphaWebM):
            container = .webm
            encoding.codec = .vp9
            encoding.alpha = true
        default:
            container = .mp4
            encoding.codec = context.settings.video.codec == .hevc ? .hevc : .h264
        }
        var plan = TranscodePlan(
            container: container, video: .encode(encoding, FrameEdit(rotation: input.displayRotation)),
            audio: audio(for: input, in: container, settings: context.settings.audio))
        plan.matte = BackgroundMatte(source: request.mask, fill: request.fill)
        let name = url.deletingPathExtension().lastPathComponent + " (background removed)." + container.fileExtension
        let output = try context.stagingURL(for: url, name: name)
        try await Transcoder.run(input, plan: plan, to: output) { context.progress($0) }
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .media)])
    }

    private static func audio(for input: MediaInput, in container: OutputContainer, settings: AudioSettings)
        -> TranscodePlan.Audio?
    {
        guard let audio = input.audio else { return nil }
        if container.holds(audio.codec) { return .copy }
        return container == .webm
            ? .encode(.opus, kilobits: settings.opusBitrate) : .encode(.aac, kilobits: settings.aacBitrate)
    }
}
