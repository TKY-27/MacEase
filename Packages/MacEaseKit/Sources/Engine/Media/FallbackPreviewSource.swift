import Foundation

/// ffprobe and ffmpeg run only in `playbackURL`.
public actor FallbackPreviewSource {
    public struct DurationRefused: Error {}

    private let url: URL
    private let audioOnly: Bool
    private let stamp: MediaSourceStamp
    private let nativeError: EngineError
    private let staging: StagingArea
    private var staged: (context: ItemContext, url: URL)?
    private var closed = false

    /// Rethrows `nativeError` unless ffmpeg could decode instead.
    public static func open(
        _ url: URL, audioOnly: Bool, staging: StagingArea, nativeError: any Error
    ) throws -> FallbackPreviewSource {
        let native = EngineError.wrapping(nativeError, path: url.path)
        guard StagedMediaFallback.acceptsNativeFailure(native) else { throw nativeError }
        return FallbackPreviewSource(
            url: url, audioOnly: audioOnly, stamp: try MediaSourceStamp(url: url), nativeError: native,
            staging: staging)
    }

    private init(url: URL, audioOnly: Bool, stamp: MediaSourceStamp, nativeError: EngineError, staging: StagingArea) {
        self.url = url
        self.audioOnly = audioOnly
        self.stamp = stamp
        self.nativeError = nativeError
        self.staging = staging
    }

    deinit { staged?.context.removeStaging() }

    // Playback drops extra streams without asking.
    public func playbackURL(
        allowsDuration: @Sendable (Double) -> Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard !closed else { throw CancellationError() }
        if let staged { return staged.url }
        try stamp.validate(url)
        try await Self.requireAllowedDuration(
            of: url, audioOnly: audioOnly, nativeError: nativeError, allowsDuration: allowsDuration)
        let context = ItemContext(settings: Settings(), staging: staging, progress: progress)
        do {
            let stagedURL =
                audioOnly
                ? try await StagedMediaFallback.prepareAudio(
                    url, context: context, enforceStreamConsent: false, nativeError: nativeError
                ).stagedURL
                : try await StagedMediaFallback.prepareVideo(
                    url, context: context, enforceStreamConsent: false, nativeError: nativeError
                ).stagedURL
            try stamp.validate(url)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            staged = (context, stagedURL)
            return stagedURL
        } catch {
            context.removeStaging()
            throw error
        }
    }

    private static func requireAllowedDuration(
        of url: URL, audioOnly: Bool, nativeError: EngineError, allowsDuration: @Sendable (Double) -> Bool
    ) async throws {
        let probe = try await StagedMediaFallback.restoringNativeError(nativeError, path: url.path) {
            try await StagedMediaFallback.probe(url)
        }
        let streams = audioOnly ? probe.audioStreams : probe.videoStreams
        guard !streams.isEmpty else { throw EngineError.decodeFailed(audioOnly ? "no audio track" : "no video track") }
        guard let duration = probe.durationSeconds, duration.isFinite, duration > 0 else {
            throw EngineError.decodeFailed("unknown media duration")
        }
        guard allowsDuration(duration) else { throw DurationRefused() }
    }

    public func close() {
        closed = true
        staged?.context.removeStaging()
        staged = nil
    }
}
