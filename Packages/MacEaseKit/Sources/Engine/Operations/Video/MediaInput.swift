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
    let duration: Int64
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
        let duration = try opened.duration ?? Self.scanDuration(try demuxer())
        return MediaInput(
            url: url, backend: backend, video: video, audio: audio, duration: duration, transform: .identity)
    }

    /// Median spacing of the first frames.
    private static func measuredFrameDuration(_ demuxer: any MediaDemuxer, track: Int) throws -> Int64? {
        var demuxer = demuxer
        var times: [Int64] = []
        while times.count < frameRateProbe, let packet = try demuxer.nextPacket() {
            if packet.track == track { times.append(packet.timestamp) }
        }
        times.sort()
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    /// AVI and FLV may omit the duration.
    private static func scanDuration(_ demuxer: any MediaDemuxer) throws -> Int64 {
        var demuxer = demuxer
        var end: Int64 = 0
        while let packet = try demuxer.nextPacket() {
            try Task.checkCancellation()
            end = max(end, packet.timestamp + (packet.duration ?? 0))
        }
        return end
    }

    private static func openAsset(_ url: URL) async throws -> MediaInput {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = SampleBuffers.nanoseconds(try await asset.load(.duration))
        var video: MediaTrack?
        var transform = CGAffineTransform.identity
        if let videoTrack {
            video = try await AssetTracks.describe(videoTrack, number: 1)
            transform = try await videoTrack.load(.preferredTransform)
        }
        var audio: MediaTrack?
        if let audioTrack { audio = try await AssetTracks.describe(audioTrack, number: 2) }
        return MediaInput(
            url: url, backend: .asset(asset, video: videoTrack, audio: audioTrack), video: video, audio: audio,
            duration: duration, transform: transform)
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
        let coded = codedSize
        return quarterTurns == 1 ? PixelSize(width: coded.height, height: coded.width) : coded
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
