import AVFoundation
import CoreMedia
import Foundation

final class NativeTimecode {
    private let movieTimeScale: CMTimeScale
    private let reader: AVAssetReader
    private var tracks: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []

    init(asset: AVURLAsset) async throws {
        movieTimeScale = try await asset.load(.duration).timescale
        reader = try AVAssetReader(asset: asset)
        for track in try await asset.loadTracks(withMediaType: .timecode) {
            guard let format = try await track.load(.formatDescriptions).first else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
            input.mediaTimeScale = try await track.load(.naturalTimeScale)
            input.metadata = try await track.load(.metadata)
            input.languageCode = try await track.load(.languageCode)
            input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            tracks.append((output, input))
        }
        guard !tracks.isEmpty else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
    }

    func attach(to writer: AVAssetWriter, video: AVAssetWriterInput?) throws {
        guard let video else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
        writer.movieTimeScale = movieTimeScale
        let association = AVAssetTrack.AssociationType.timecode.rawValue
        for (_, input) in tracks {
            guard writer.canAdd(input), video.canAddTrackAssociation(withTrackOf: input, type: association) else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            writer.add(input)
            video.addTrackAssociation(withTrackOf: input, type: association)
        }
        guard reader.startReading() else {
            throw EngineError.decodeFailed(reader.error.map { "\($0)" } ?? "timecode reader did not start")
        }
    }

    var isFinished: Bool { tracks.isEmpty }

    func appendReady() throws {
        var remaining: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for (output, input) in tracks {
            var finished = false
            while input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        throw EngineError.decodeFailed(reader.error.map { "\($0)" } ?? "timecode read failed")
                    }
                    input.markAsFinished()
                    finished = true
                    break
                }
                guard input.append(sample) else { throw EngineError.encodeFailed("timecode append failed") }
            }
            if !finished { remaining.append((output, input)) }
        }
        tracks = remaining
    }

    func cancel() { reader.cancelReading() }

    deinit { reader.cancelReading() }

    static func verify(original: URL, output: URL) async throws {
        let sourceAsset = AVURLAsset(url: original)
        let outputAsset = AVURLAsset(url: output)
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .timecode)
        let outputTracks = try await outputAsset.loadTracks(withMediaType: .timecode)
        guard !sourceTracks.isEmpty, sourceTracks.count == outputTracks.count,
            let video = try await outputAsset.loadTracks(withMediaType: .video).first
        else { throw EngineError.encodeFailed("timecode track missing") }
        let associated = try await video.loadAssociatedTracks(ofType: .timecode)
        guard Set(associated.map(\.trackID)) == Set(outputTracks.map(\.trackID)) else {
            throw EngineError.encodeFailed("timecode association missing")
        }
        for (source, written) in zip(sourceTracks, outputTracks) {
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
