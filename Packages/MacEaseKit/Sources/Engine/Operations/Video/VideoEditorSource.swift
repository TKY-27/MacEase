import AVFoundation
import CoreGraphics
import Formats
import Foundation

public struct VideoEditorDetails: Sendable {
    public let size: CGSize
    public let duration: Double
    public let frameDuration: Double
    public let hasAudio: Bool
    public let containsHDR: Bool
    public let stamp: MediaSourceStamp
}

public actor VideoEditorSource {
    public let details: VideoEditorDetails
    private let url: URL
    private let preview: MediaPreview
    private let staging: StagingArea
    private var proxies: [Bool: URL] = [:]
    private var directories: [URL] = []
    private var closed = false
    private var frameTimes: [Int64]?
    private static let maximumIndexedFrames = 4_000_000

    public static func open(_ url: URL, staging: StagingArea) async throws -> VideoEditorSource {
        let stamp = try MediaSourceStamp(url: url)
        let input = try await MediaInput.open(url)
        try input.requireSingleTracksForReplacement()
        guard input.video != nil, input.duration > 0 else { throw EngineError.decodeFailed("no video track") }
        let hdr = try await VideoProperties.hdrConfiguration(input)
        let preview = try await MediaPreview(videoAt: url)
        try stamp.validate(url)
        return VideoEditorSource(
            url: url, input: input, preview: preview, staging: staging,
            containsHDR: hdr != nil, stamp: stamp)
    }

    private init(
        url: URL, input: MediaInput, preview: MediaPreview, staging: StagingArea,
        containsHDR: Bool, stamp: MediaSourceStamp
    ) {
        self.url = url
        self.preview = preview
        self.staging = staging
        details = VideoEditorDetails(
            size: CGSize(width: input.displaySize.width, height: input.displaySize.height),
            duration: preview.durationSeconds,
            frameDuration: Double(input.frameDuration) / Double(Nanoseconds.perSecond),
            hasAudio: input.audio != nil, containsHDR: containsHDR, stamp: stamp)
    }

    public func frames(
        at seconds: [Double], width: Int, edit: VideoEdit = VideoEdit(), cropPreview: Bool = false,
        exactFrame: Bool = false
    )
        async throws -> [CGImage]
    {
        guard !closed else { throw CancellationError() }
        var geometry = edit.geometry
        if cropPreview { geometry.crop = EditCrop() }
        return try await preview.frames(
            at: seconds, width: width, geometry: geometry, adjustments: edit.adjustments,
            toneMapToSDR: details.containsHDR && !edit.adjustments.isIdentity, exactFrame: exactFrame)
    }

    public func adjacentFrameTime(to seconds: Double, forward: Bool) async throws -> Double {
        guard !closed else { throw CancellationError() }
        if frameTimes == nil { frameTimes = try await Self.readFrameTimes(url) }
        try Task.checkCancellation()
        guard !closed, let frameTimes, let first = frameTimes.first, let last = frameTimes.last else {
            throw EngineError.decodeFailed("no video frames")
        }
        let current = try Nanoseconds.from(seconds: seconds)
        let timestamp =
            forward
            ? frameTimes.first { $0 > current + 1 } ?? last
            : frameTimes.last { $0 < current - 1 } ?? first
        return Double(timestamp) / Double(Nanoseconds.perSecond)
    }

    private nonisolated static func readFrameTimes(_ url: URL) async throws -> [Int64] {
        let input = try await MediaInput.open(url)
        guard let video = input.video else { throw EngineError.decodeFailed("no video track") }
        var timestamps: [Int64] = []
        switch input.backend {
        case .asset(let asset, let track?, _):
            let reader = try AssetTrackReader(asset: asset, track: track, number: video.number, mode: .packets)
            while let packets = try await reader.nextPackets() {
                timestamps.append(contentsOf: packets.map(\.timestamp))
                guard timestamps.count <= maximumIndexedFrames else {
                    throw EngineError.decodeFailed("video frame index limit exceeded")
                }
            }
        default:
            guard var demuxer = try input.demuxer else { throw EngineError.decodeFailed("no video demuxer") }
            while let packet = try demuxer.nextPacket() {
                try Task.checkCancellation()
                guard packet.track == video.number else { continue }
                guard !packet.continuesPrevious, packet.remainingLaceFrames == 0 else {
                    throw EngineError.unsupportedCodec(video.codec.displayName)
                }
                timestamps.append(packet.timestamp)
                guard timestamps.count <= maximumIndexedFrames else {
                    throw EngineError.decodeFailed("video frame index limit exceeded")
                }
            }
        }
        return timestamps.filter { $0 >= 0 && $0 < input.duration }.sorted()
    }

    public func playbackURL(sdr: Bool) async throws -> URL {
        guard !closed else { throw CancellationError() }
        try details.stamp.validate(url)
        let toneMap = sdr && details.containsHDR
        if !toneMap, try await Self.canPlay(url) { return url }
        if let cached = proxies[toneMap] { return cached }
        let directory = try staging.makeDirectory(for: url)
        directories.append(directory)
        let output = directory.appending(path: "preview.mp4")
        do {
            try await Self.makePreview(url: url, output: output, toneMap: toneMap)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            try details.stamp.validate(url)
            proxies[toneMap] = output
            return output
        } catch {
            staging.remove(directory)
            directories.removeAll { $0 == directory }
            throw error
        }
    }

    private nonisolated static func canPlay(_ url: URL) async throws -> Bool {
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else { return false }
        return try await AVURLAsset(url: url).load(.isPlayable)
    }

    private nonisolated static func makePreview(url: URL, output: URL, toneMap: Bool) async throws {
        let input = try await MediaInput.open(url)
        guard let source = input.video else { throw EngineError.decodeFailed("no video track") }
        if toneMap, case .asset(_, let track?, _) = input.backend {
            for format in try await track.load(.formatDescriptions) { try VideoSDR.validateSourceFormat(format) }
        }
        let size = try VideoResize.lines(720).outputSize(input.displaySize).evened()
        var encoding = VideoEncoding(
            codec: .h264, width: size.width, height: size.height,
            frameDuration: input.frameDuration, bitrate: nil)
        encoding.quality = 0.85
        let edit = FrameEdit(displayOrientation: try input.displayOrientation, size: size)
        var plan = TranscodePlan(
            container: .mp4, video: .encode(encoding, edit),
            audio: input.audio.map { _ in .encode(.aac, kilobits: 192) })
        plan.toneMapToSDR = toneMap
        plan.range = 0..<input.duration
        if source.hasAlpha { throw EngineError.videoAlphaUnsupported }
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
    }

    public func close() {
        closed = true
        for directory in directories { staging.remove(directory) }
        directories.removeAll()
        proxies.removeAll()
        frameTimes = nil
    }
}
