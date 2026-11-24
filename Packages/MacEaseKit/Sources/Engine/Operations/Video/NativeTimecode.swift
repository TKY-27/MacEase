import AVFoundation
import CoreMedia
import Foundation

final class NativeTimecode {
    private struct Track {
        let input: AVAssetWriterInput
        let associated: Bool
        var samples: ArraySlice<CMSampleBuffer>
    }

    private var movieTimeScale: CMTimeScale
    private var tracks: [Track] = []

    init(asset: AVURLAsset) async throws {
        movieTimeScale = try await asset.load(.duration).timescale
        let video = try await asset.loadTracks(withMediaType: .video).first
        let associated = Set(try await video?.loadAssociatedTracks(ofType: .timecode).map(\.trackID) ?? [])
        for track in try await asset.loadTracks(withMediaType: .timecode) {
            let formats = try await track.load(.formatDescriptions)
            guard formats.count == 1, let format = formats.first, try await track.load(.totalSampleDataLength) > 0
            else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            let mediaScale = try await track.load(.naturalTimeScale)
            let combinedTick = CMTimeAdd(
                CMTime(value: 1, timescale: movieTimeScale), CMTime(value: 1, timescale: mediaScale))
            guard combinedTick.isNumeric, !combinedTick.hasBeenRounded else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
            }
            movieTimeScale = combinedTick.timescale
            let reader = try AssetTrackReader(asset: asset, track: track, number: Int(track.trackID), mode: .packets)
            var samples: [CMSampleBuffer] = []
            while let sample = try await Self.nextSample(from: reader) {
                try Self.validate(sample, format: format)
                samples.append(sample)
            }
            let edits = try await track.load(.segments).filter { !$0.isEmpty }
            guard !samples.isEmpty, edits.count == 1,
                samples.count == 1 || CMTimeCompare(edits[0].timeMapping.source.start, .zero) == 0
            else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
            input.mediaTimeScale = try await track.load(.naturalTimeScale)
            input.metadata = try await track.load(.metadata)
            input.languageCode = try await track.load(.languageCode)
            input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            tracks.append(
                Track(input: input, associated: associated.contains(track.trackID), samples: samples[...]))
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

    func appendReady(writer: AVAssetWriter) throws {
        if writer.status == .failed || writer.status == .cancelled {
            throw EngineError.encodeFailed(writer.error.map { "\($0)" } ?? "asset writer failed")
        }
        for index in tracks.indices {
            let input = tracks[index].input
            while input.isReadyForMoreMediaData, let sample = tracks[index].samples.first {
                try Task.checkCancellation()
                guard input.append(sample) else {
                    if writer.error != nil || writer.status == .failed || writer.status == .cancelled {
                        throw EngineError.encodeFailed(writer.error.map { "\($0)" } ?? "asset writer failed")
                    }
                    throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
                }
                tracks[index].samples.removeFirst()
            }
            if tracks[index].samples.isEmpty { input.markAsFinished() }
        }
        tracks.removeAll { $0.samples.isEmpty }
    }

    private static func validate(_ sample: CMSampleBuffer, format: CMFormatDescription) throws {
        guard let sampleFormat = sample.formatDescription,
            CMFormatDescriptionEqual(format, otherFormatDescription: sampleFormat)
        else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
        let subtype = CMFormatDescriptionGetMediaSubType(sampleFormat)
        let width = subtype == kCMTimeCodeFormatType_TimeCode32 ? MemoryLayout<Int32>.size : MemoryLayout<Int64>.size
        let count = sample.numSamples
        guard subtype == kCMTimeCodeFormatType_TimeCode32 || subtype == kCMTimeCodeFormatType_TimeCode64,
            CMTimeCompare(sample.duration, sample.outputDuration) == 0,
            sample.totalSampleSize == count * width,
            (0..<count).allSatisfy({ CMSampleBufferGetSampleSize(sample, at: $0) == width })
        else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
    }

    func cancel() { tracks = [] }

    static func verify(original: URL, output: URL) async throws {
        let sourceAsset = UntrustedMediaAsset.make(original)
        let outputAsset = UntrustedMediaAsset.make(output)
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .timecode)
        let outputTracks = try await outputAsset.loadTracks(withMediaType: .timecode)
        guard !sourceTracks.isEmpty, sourceTracks.count == outputTracks.count,
            let video = try await outputAsset.loadTracks(withMediaType: .video).first
        else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
        guard let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
        }
        let sourceAssociated = Set(try await sourceVideo.loadAssociatedTracks(ofType: .timecode).map(\.trackID))
        let expectedAssociated = Set(
            zip(sourceTracks, outputTracks).filter { sourceAssociated.contains($0.0.trackID) }.map { $0.1.trackID })
        let associated = try await video.loadAssociatedTracks(ofType: .timecode)
        guard Set(associated.map(\.trackID)) == expectedAssociated else {
            throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
        }
        let metadata = try await VideoMetadata.load(from: MediaInput.open(original))
        for (source, written) in zip(sourceTracks, outputTracks) {
            guard try await source.load(.isEnabled) == written.load(.isEnabled),
                try await source.load(.languageCode) == written.load(.languageCode),
                try await source.load(.extendedLanguageTag) == written.load(.extendedLanguageTag),
                try await metadata.preserves(source.load(.metadata), in: written.load(.metadata), container: .mov)
            else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
            let originalRange = try await source.load(.timeRange)
            let writtenRange = try await written.load(.timeRange)
            let sourceMovieScale = try await sourceAsset.load(.duration).timescale
            let movieRoundingTolerance = CMTime(value: 1, timescale: sourceMovieScale)
            guard CMTimeCompare(originalRange.start, writtenRange.start) == 0,
                CMTimeCompare(
                    CMTimeAbsoluteValue(originalRange.duration - writtenRange.duration), movieRoundingTolerance) < 0
            else {
                throw EngineError.invalidInput(.unpreservedStreams([.timecode]))
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
                else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
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
