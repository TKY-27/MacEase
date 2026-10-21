import AVFoundation
import CoreMedia
import Formats
import Foundation

public enum OutputContainer: String, Codable, CaseIterable, Sendable {
    case mp4
    case mov
    case m4v
    case mkv
    case webm
    case avi
    case flv

    var fileExtension: String { rawValue }

    var fileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        case .mkv, .webm, .avi, .flv: nil
        }
    }

    /// Codecs each container can carry when copying.
    func holds(_ codec: MediaCodec) -> Bool {
        switch self {
        case .mp4, .m4v: [.h264, .hevc, .av1, .mpeg4Part2, .aac, .alac, .mp3, .ac3].contains(codec)
        case .mov: [.h264, .hevc, .prores, .mjpeg, .mpeg4Part2, .aac, .alac, .mp3, .ac3].contains(codec)
        case .mkv: (try? MatroskaCodec.id(for: codec)) != nil
        case .webm: [.vp8, .vp9, .av1, .opus, .vorbis].contains(codec)
        case .avi: codec == .mjpeg || codec.isPCM
        case .flv: [.h264, .aac].contains(codec)
        }
    }
}

extension MediaCodec {
    var isPCM: Bool {
        if case .pcm = self { true } else { false }
    }
}

/// What each backend needs per stream.
struct OutputTrack {
    var track: MediaTrack
    /// Wins over one rebuilt from `track`.
    var format: CMFormatDescription?
    var metadata: [AVMetadataItem] = []
    var languageCode: String?
    var extendedLanguageTag: String?
    var preferredVolume: Float = 1
    var isEnabled = true
}

protocol PacketSink {
    /// AVAssetWriter interleaves; muxers take anything.
    func accepts(track: Int) -> Bool
    func checkHealth() throws
    mutating func cancel()
    /// Stops AVAssetWriter waiting on a drained stream.
    func endTrack(_ track: Int)
    mutating func write(_ packet: MediaPacket) async throws
    mutating func finish() async throws
}

enum Sinks {
    static func make(
        _ container: OutputContainer, url: URL, tracks: [OutputTrack], transform: CGAffineTransform,
        metadata: [AVMetadataItem] = []
    ) throws -> any PacketSink {
        if let fileType = container.fileType {
            return try AssetWriterSink(
                url: url, fileType: fileType, tracks: tracks, transform: transform, metadata: metadata)
        }
        let described = tracks.map(\.track)
        switch container {
        case .avi: return MuxerSink(muxer: try AVIMuxer(url: url, tracks: described))
        case .flv: return MuxerSink(muxer: try FLVMuxer(url: url, tracks: described))
        default: return MuxerSink(muxer: try MatroskaMuxer(url: url, tracks: described, webm: container == .webm))
        }
    }
}

struct MuxerSink: PacketSink {
    var muxer: any MediaMuxer

    func accepts(track: Int) -> Bool { true }

    func checkHealth() throws {}

    mutating func cancel() {}

    func endTrack(_ track: Int) {}

    mutating func write(_ packet: MediaPacket) async throws {
        try muxer.write(packet)
    }

    mutating func finish() async throws {
        try muxer.finish()
    }
}

/// AVAssetWriter in passthrough mode.
final class AssetWriterSink: PacketSink {
    private static let readinessPoll = Duration.milliseconds(2)

    private let writer: AVAssetWriter
    private var inputs: [Int: (input: AVAssetWriterInput, format: CMFormatDescription)] = [:]

    init(
        url: URL, fileType: AVFileType, tracks: [OutputTrack], transform: CGAffineTransform,
        metadata: [AVMetadataItem] = []
    ) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        for output in tracks {
            let format =
                try output.format
                ?? (output.track.isVideo
                    ? VideoFormat.description(for: output.track) : AudioTrackFormat.description(for: output.track))
            let input = AVAssetWriterInput(
                mediaType: output.track.isVideo ? .video : .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.metadata = output.metadata
            input.languageCode = output.languageCode
            input.extendedLanguageTag = output.extendedLanguageTag
            input.marksOutputTrackAsEnabled = output.isEnabled
            if !output.track.isVideo { input.preferredVolume = output.preferredVolume }
            if output.track.isVideo { input.transform = transform }
            guard writer.canAdd(input) else {
                throw EngineError.encodeFailed("\(output.track.codec.displayName) cannot go into \(fileType.rawValue)")
            }
            writer.add(input)
            inputs[output.track.number] = (input, format)
        }
        guard writer.startWriting() else { throw EngineError.encodeFailed(Self.describe(writer.error)) }
        writer.startSession(atSourceTime: .zero)
    }

    private static func describe(_ error: (any Error)?) -> String {
        error.map { "\($0)" } ?? "asset writer failed"
    }

    func accepts(track: Int) -> Bool {
        inputs[track]?.input.isReadyForMoreMediaData ?? true
    }

    func checkHealth() throws {
        if writer.status == .failed || writer.status == .cancelled {
            throw EngineError.encodeFailed(Self.describe(writer.error))
        }
    }

    func cancel() {
        writer.cancelWriting()
    }

    func endTrack(_ track: Int) {
        inputs.removeValue(forKey: track)?.input.markAsFinished()
    }

    func write(_ packet: MediaPacket) async throws {
        guard let (input, format) = inputs[packet.track] else {
            throw EngineError.encodeFailed("packet for unknown track \(packet.track)")
        }
        while !input.isReadyForMoreMediaData {
            try checkHealth()
            try Task.checkCancellation()
            try await Task.sleep(for: Self.readinessPoll)
        }
        let sample = try SampleBuffers.make(packet.payload, packet: packet, format: format)
        guard input.append(sample) else { throw EngineError.encodeFailed(Self.describe(writer.error)) }
    }

    func finish() async throws {
        for (input, _) in inputs.values { input.markAsFinished() }
        inputs = [:]
        await writer.finishWriting()
        guard writer.status == .completed else { throw EngineError.encodeFailed(Self.describe(writer.error)) }
    }
}
