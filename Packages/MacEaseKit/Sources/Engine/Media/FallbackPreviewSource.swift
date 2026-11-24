import Foundation

/// Probes on open; ffmpeg runs only in `playbackURL`.
public actor FallbackPreviewSource {
    public let duration: Double
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
    ) async throws -> FallbackPreviewSource {
        let native = EngineError.wrapping(nativeError, path: url.path)
        guard StagedMediaFallback.acceptsNativeFailure(native) else { throw nativeError }
        let stamp = try MediaSourceStamp(url: url)
        let probe = try await StagedMediaFallback.restoringNativeError(native, path: url.path) {
            try await StagedMediaFallback.probe(url)
        }
        let streams = audioOnly ? probe.audioStreams : probe.videoStreams
        guard !streams.isEmpty else { throw EngineError.decodeFailed(audioOnly ? "no audio track" : "no video track") }
        guard let duration = probe.durationSeconds, duration.isFinite, duration > 0 else {
            throw EngineError.decodeFailed("unknown media duration")
        }
        try stamp.validate(url)
        return FallbackPreviewSource(
            url: url, audioOnly: audioOnly, duration: duration, stamp: stamp, nativeError: native, staging: staging)
    }

    private init(
        url: URL, audioOnly: Bool, duration: Double, stamp: MediaSourceStamp, nativeError: EngineError,
        staging: StagingArea
    ) {
        self.url = url
        self.audioOnly = audioOnly
        self.duration = duration
        self.stamp = stamp
        self.nativeError = nativeError
        self.staging = staging
    }

    deinit { staged?.context.removeStaging() }

    // Playback drops extra streams without asking.
    public func playbackURL(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard !closed else { throw CancellationError() }
        if let staged { return staged.url }
        try stamp.validate(url)
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

    public func close() {
        closed = true
        staged?.context.removeStaging()
        staged = nil
    }
}
