import AVFoundation
import CoreMedia
import Foundation

final class NativeTimecode {
    private struct Track {
        let reader: AssetTrackReader
        let input: AVAssetWriterInput
        let associated: Bool
        var pending: [CMSampleBuffer]
    }

    private let movieTimeScale: CMTimeScale
    private var tracks: [Track] = []

    init(asset: AVURLAsset) async throws {
        movieTimeScale = try await asset.load(.duration).timescale
        let video = try await asset.loadTracks(withMediaType: .video).first
        let associated = Set(try await video?.loadAssociatedTracks(ofType: .timecode).map(\.trackID) ?? [])
        for track in try await asset.loadTracks(withMediaType: .timecode) {
            guard let format = try await track.load(.formatDescriptions).first else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            let reader = try AssetTrackReader(asset: asset, track: track, number: Int(track.trackID), mode: .packets)
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
            input.mediaTimeScale = try await track.load(.naturalTimeScale)
            input.metadata = try await track.load(.metadata)
            input.languageCode = try await track.load(.languageCode)
            input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            var pending: [CMSampleBuffer] = []
            while let sample = try await reader.nextSample() {
                pending.append(sample)
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { continue }
                let subtype = CMFormatDescriptionGetMediaSubType(format)
                let width =
                    subtype == kCMTimeCodeFormatType_TimeCode32 ? MemoryLayout<Int32>.size : MemoryLayout<Int64>.size
                guard (subtype == kCMTimeCodeFormatType_TimeCode32 || subtype == kCMTimeCodeFormatType_TimeCode64),
                    CMSampleBufferGetTotalSampleSize(sample) / count == width,
                    CMSampleBufferGetTotalSampleSize(sample).isMultiple(of: count)
                else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
                break
            }
            tracks.append(
                Track(reader: reader, input: input, associated: associated.contains(track.trackID), pending: pending))
        }
        guard !tracks.isEmpty else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
    }

    func attach(to writer: AVAssetWriter, video: AVAssetWriterInput?) throws {
        guard let video else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
        writer.movieTimeScale = movieTimeScale
        let association = AVAssetTrack.AssociationType.timecode.rawValue
        for track in tracks {
            let input = track.input
            guard writer.canAdd(input),
                !track.associated || video.canAddTrackAssociation(withTrackOf: input, type: association)
            else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            writer.add(input)
            if track.associated { video.addTrackAssociation(withTrackOf: input, type: association) }
        }
    }

    var isFinished: Bool { tracks.isEmpty }

    func appendReady() async throws {
        var remaining: [Track] = []
        for var track in tracks {
            let input = track.input
            var finished = false
            while input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                let sample: CMSampleBuffer?
                do {
                    if !track.pending.isEmpty {
                        sample = track.pending.removeFirst()
                    } else {
                        sample = try await track.reader.nextSample()
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
                }
                guard let sample else {
                    input.markAsFinished()
                    finished = true
                    break
                }
                guard input.append(sample) else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
            }
            if !finished { remaining.append(track) }
        }
        tracks = remaining
    }

    func cancel() { tracks = [] }

    static func verify(original: URL, output: URL) async throws {
        let sourceAsset = AVURLAsset(url: original)
        let outputAsset = AVURLAsset(url: output)
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .timecode)
        let outputTracks = try await outputAsset.loadTracks(withMediaType: .timecode)
        guard !sourceTracks.isEmpty, sourceTracks.count == outputTracks.count,
            let video = try await outputAsset.loadTracks(withMediaType: .video).first
        else { throw EngineError.encodeFailed("timecode track missing") }
        guard let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw EngineError.encodeFailed("timecode source video missing")
        }
        let sourceAssociated = Set(try await sourceVideo.loadAssociatedTracks(ofType: .timecode).map(\.trackID))
        let expectedAssociated = Set(
            zip(sourceTracks, outputTracks).filter { sourceAssociated.contains($0.0.trackID) }.map { $0.1.trackID })
        let associated = try await video.loadAssociatedTracks(ofType: .timecode)
        guard Set(associated.map(\.trackID)) == expectedAssociated else {
            throw EngineError.encodeFailed("timecode association missing")
        }
        let metadata = try await VideoMetadata.load(from: MediaInput.open(original))
        for (source, written) in zip(sourceTracks, outputTracks) {
            guard try await source.load(.isEnabled) == written.load(.isEnabled),
                try await source.load(.languageCode) == written.load(.languageCode),
                try await source.load(.extendedLanguageTag) == written.load(.extendedLanguageTag),
                try await metadata.preserves(source.load(.metadata), in: written.load(.metadata), container: .mov)
            else { throw EngineError.encodeFailed("timecode track properties changed") }
            guard CMTimeRangeEqual(try await source.load(.timeRange), try await written.load(.timeRange))
            else {
                throw EngineError.encodeFailed("timecode timeline changed")
            }
            let originalReader = try AssetTrackReader(asset: sourceAsset, track: source, number: 1, mode: .packets)
            let outputReader = try AssetTrackReader(asset: outputAsset, track: written, number: 1, mode: .packets)
            while true {
                let first = try await nextSample(from: originalReader)
                let second = try await nextSample(from: outputReader)
                if first == nil, second == nil { break }
                guard let first, let second,
                    let originalFormat = CMSampleBufferGetFormatDescription(first),
                    let outputFormat = CMSampleBufferGetFormatDescription(second),
                    CMFormatDescriptionEqual(originalFormat, otherFormatDescription: outputFormat),
                    CMSampleBufferGetNumSamples(first) == CMSampleBufferGetNumSamples(second),
                    CMTimeCompare(
                        CMSampleBufferGetPresentationTimeStamp(first), CMSampleBufferGetPresentationTimeStamp(second))
                        == 0,
                    CMTimeCompare(CMSampleBufferGetDuration(first), CMSampleBufferGetDuration(second)) == 0,
                    CMTimeCompare(CMSampleBufferGetDecodeTimeStamp(first), CMSampleBufferGetDecodeTimeStamp(second))
                        == 0,
                    CMTimeCompare(
                        CMSampleBufferGetOutputPresentationTimeStamp(first),
                        CMSampleBufferGetOutputPresentationTimeStamp(second)) == 0,
                    CMTimeCompare(CMSampleBufferGetOutputDuration(first), CMSampleBufferGetOutputDuration(second)) == 0,
                    try payload(first) == payload(second)
                else { throw EngineError.encodeFailed("timecode samples changed") }
            }
        }
    }

    private static func nextSample(from reader: AssetTrackReader) async throws -> CMSampleBuffer? {
        while let sample = try await reader.nextSample() {
            if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
        }
        return nil
    }

    private static func payload(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw EngineError.decodeFailed("timecode payload missing")
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes {
            guard let address = $0.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: address)
        }
        guard status == noErr else { throw EngineError.decodeFailed("timecode payload unreadable") }
        return bytes
    }
}
