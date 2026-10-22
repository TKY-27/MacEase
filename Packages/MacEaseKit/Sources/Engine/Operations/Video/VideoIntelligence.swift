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

    static func preset(_ preset: String, settings: IntelligenceSettings) -> SubtitleRequest? {
        if preset == "translated-srt" {
            return SubtitleRequest(
                format: .srt, language: settings.subtitleLanguage, translation: settings.translationTarget)
        }
        return SubtitleFormat(rawValue: preset).map {
            SubtitleRequest(format: $0, language: settings.subtitleLanguage, translation: nil)
        }
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
        return try await Subtitles.export(request, audioFile: speech, nextTo: url, context: context)
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
            container: container, video: .encode(encoding, FrameEdit(displayOrientation: try input.displayOrientation)),
            audio: audio(for: input, in: container, settings: context.settings.audio))
        plan.matte = BackgroundMatte(source: request.mask, fill: request.fill)
        plan.derived = true
        plan = try await VideoProperties.prepare(plan, input: input, context: context, allowsCodecChange: false)
        let name = url.deletingPathExtension().lastPathComponent + " (background removed)." + container.fileExtension
        let output = try context.stagingURL(for: url, name: name)
        try await Transcoder.run(input, plan: plan, to: output) { context.progress($0) }
        try await VideoProperties.verify(plan, output: output, context: context)
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
