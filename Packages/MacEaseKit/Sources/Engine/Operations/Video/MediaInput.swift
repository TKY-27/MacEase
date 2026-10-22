import AVFoundation
import CoreMedia
import Formats
import Foundation

struct MediaInput {
    enum Backend {
        case asset(AVURLAsset, video: AVAssetTrack?, audio: AVAssetTrack?)
        case matroska
        case avi
        case flv
    }

    let url: URL
    let backend: Backend
    let video: MediaTrack?
    let audio: MediaTrack?
    let hasMultipleTracks: Bool
    let skippedStreams: Set<SkippedMediaStream>
    let duration: Int64
    var hasContainerDescriptiveMetadata = false
    var hasContainerTrackMetadata = false
    /// MP4 and MOV store rotation separately.
    let transform: CGAffineTransform

    static func open(_ url: URL) async throws -> MediaInput {
        switch try ContainerSignature.detect(url) {
        case .isoMedia: try await openAsset(url)
        case .matroska: try openContainer(url, backend: .matroska) { try MatroskaDemuxer(url: url) }
        case .avi: try openContainer(url, backend: .avi) { try AVIDemuxer(url: url) }
        case .flv: try openContainer(url, backend: .flv) { try FLVDemuxer(url: url) }
        }
    }

    private static func openContainer(
        _ url: URL, backend: Backend, demuxer: () throws -> any MediaDemuxer
    ) throws -> MediaInput {
        let opened = try demuxer()
        var video = opened.tracks.first(where: \.isVideo)
        if let track = video, track.defaultDuration == nil {
            video?.defaultDuration = try measuredFrameDuration(try demuxer(), track: track.number)
        }
        let audio = opened.tracks.first { !$0.isVideo }
        let hasMultipleTracks =
            opened.tracks.filter(\.isVideo).count > 1 || opened.tracks.filter { !$0.isVideo }.count > 1
        var skippedStreams = opened.skippedStreams
        for track in opened.tracks where track.number != video?.number && track.number != audio?.number {
            skippedStreams.insert(.track(track.number))
        }
        let duration = try opened.duration ?? Self.scanDuration(try demuxer())
        let matroska = opened as? MatroskaDemuxer
        return MediaInput(
            url: url, backend: backend, video: video, audio: audio, hasMultipleTracks: hasMultipleTracks,
            skippedStreams: skippedStreams, duration: duration,
            hasContainerDescriptiveMetadata: matroska?.hasDescriptiveMetadata ?? false,
            hasContainerTrackMetadata: matroska?.hasTrackMetadata ?? false,
            transform: .identity)
    }

    /// Median spacing of the first frames.
    private static func measuredFrameDuration(_ demuxer: any MediaDemuxer, track: Int) throws -> Int64? {
        var demuxer = demuxer
        var times: [Int64] = []
        while times.count < frameRateProbe, let packet = try demuxer.nextPacket() {
            if packet.track == track { times.append(packet.timestamp) }
        }
        times.sort()
        var gaps: [Int64] = []
        for (later, earlier) in zip(times.dropFirst(), times) {
            let (gap, overflow) = later.subtractingReportingOverflow(earlier)
            guard !overflow else { throw EngineError.decodeFailed("video frame spacing out of range") }
            if gap > 0 { gaps.append(gap) }
        }
        gaps.sort()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    /// AVI and FLV may omit the duration.
    private static func scanDuration(_ demuxer: any MediaDemuxer) throws -> Int64 {
        var demuxer = demuxer
        var end: Int64 = 0
        while let packet = try demuxer.nextPacket() {
            try Task.checkCancellation()
            let (packetEnd, overflow) = packet.timestamp.addingReportingOverflow(packet.duration ?? 0)
            guard !overflow else { throw EngineError.decodeFailed("media duration out of range") }
            end = max(end, packetEnd)
        }
        return end
    }

    private static func openAsset(_ url: URL) async throws -> MediaInput {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let allTracks = try await asset.load(.tracks)
        var skippedStreams: Set<SkippedMediaStream> = []
        for track in allTracks {
            let type = track.mediaType
            if type == .video, track.trackID == videoTracks.first?.trackID { continue }
            if type == .audio, track.trackID == audioTracks.first?.trackID { continue }
            skippedStreams.insert(.track(Int(track.trackID)))
        }
        if !(try await asset.load(.availableChapterLocales)).isEmpty { skippedStreams.insert(.chapter) }
        let videoTrack = videoTracks.first
        let audioTrack = audioTracks.first
        let duration = SampleBuffers.nanoseconds(try await asset.load(.duration))
        var video: MediaTrack?
        var transform = CGAffineTransform.identity
        if let videoTrack {
            video = try await AssetTracks.describe(videoTrack, number: 1)
            transform = try await videoTrack.load(.preferredTransform)
            _ = try VideoDisplayOrientation(transform)
        }
        var audio: MediaTrack?
        if let audioTrack { audio = try await AssetTracks.describe(audioTrack, number: 2) }
        return MediaInput(
            url: url, backend: .asset(asset, video: videoTrack, audio: audioTrack), video: video, audio: audio,
            hasMultipleTracks: videoTracks.count > 1 || audioTracks.count > 1, skippedStreams: skippedStreams,
            duration: duration, hasContainerDescriptiveMetadata: false, hasContainerTrackMetadata: false,
            transform: transform)
    }

    func requireSingleTracksForReplacement() throws {
        if hasMultipleTracks { throw EngineError.invalidInput(.multipleTracks) }
        if !skippedStreams.isEmpty { throw EngineError.invalidInput(.unpreservedStreams) }
        _ = try VideoDisplayOrientation(transform)
    }

    private static let frameRateProbe = 32
    /// Single-frame clips have no spacing to measure.
    private static let fallbackFrameDuration = Nanoseconds.perSecond / 30

    var container: OutputContainer {
        switch backend {
        case .asset:
            OutputContainer(rawValue: url.pathExtension.lowercased()).flatMap { $0.fileType == nil ? nil : $0 } ?? .mp4
        case .matroska: url.pathExtension.lowercased() == "webm" ? .webm : .mkv
        case .avi: .avi
        case .flv: .flv
        }
    }

    var codedSize: PixelSize {
        guard case .video(let width, let height)? = video?.kind else { return PixelSize(width: 0, height: 0) }
        return PixelSize(width: width, height: height)
    }

    var displaySize: PixelSize {
        let quarterTurns = Int((displayRotation / 90).rounded()) % 2
        var size = codedSize
        if let presentation = video?.displayGeometry?.presentationSize(width: size.width, height: size.height) {
            size = PixelSize(width: Int(presentation.width.rounded()), height: Int(presentation.height.rounded()))
        }
        return quarterTurns == 1 ? PixelSize(width: size.height, height: size.width) : size
    }

    var displayOrientation: VideoDisplayOrientation {
        get throws { try VideoDisplayOrientation(transform) }
    }

    var frameDuration: Int64 {
        video?.defaultDuration ?? Self.fallbackFrameDuration
    }

    /// Clockwise degrees that `transform` turns the picture.
    var displayRotation: Double {
        let degrees = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    var demuxer: (any MediaDemuxer)? {
        get throws {
            switch backend {
            case .asset: nil
            case .matroska: try MatroskaDemuxer(url: url)
            case .avi: try AVIDemuxer(url: url)
            case .flv: try FLVDemuxer(url: url)
            }
        }
    }
}

enum ContainerSignature {
    case isoMedia
    case matroska
    case avi
    case flv

    private static let ebmlMagic: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
    /// QuickTime files may start with any.
    private static let quickTimeAtoms: Set<String> = ["ftyp", "moov", "wide", "mdat", "free", "skip", "pnot"]

    static func detect(_ url: URL) throws -> ContainerSignature {
        guard let signature = try signature(of: url) else {
            throw EngineError.decodeFailed("unrecognized video container")
        }
        return signature
    }

    private static func signature(of url: URL) throws -> ContainerSignature? {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let header = [UInt8](try reader.read(upToCount: 12) ?? Data())
        guard header.count == 12 else { return nil }
        if header.starts(with: ebmlMagic) { return .matroska }
        if header.starts(with: Array("FLV".utf8)) { return .flv }
        if header.starts(with: Array("RIFF".utf8)), Array(header[8..<12]) == Array("AVI ".utf8) { return .avi }
        if quickTimeAtoms.contains(String(decoding: header[4..<8], as: UTF8.self)) { return .isoMedia }
        return nil
    }

    /// `nil` for files AVFoundation reads.
    static func demuxer(for url: URL) throws -> (any MediaDemuxer)? {
        switch try signature(of: url) {
        case .isoMedia, nil: nil
        case .matroska: try MatroskaDemuxer(url: url)
        case .avi: try AVIDemuxer(url: url)
        case .flv: try FLVDemuxer(url: url)
        }
    }
}
