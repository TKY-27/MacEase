import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Engine
@testable import Formats

func timecodedClip(named name: String, in folder: URL) async throws -> URL {
    let source = try #require(
        Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
    let asset = AVURLAsset(url: source)
    let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let duration = try await asset.load(.duration)
    let destination = folder.appending(path: name)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    let reader = try AVAssetReader(asset: asset)
    let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    reader.add(videoOut)
    let videoIn = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil,
        sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
    var format: CMTimeCodeFormatDescription?
    try #require(
        CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: 24), frameQuanta: 24, flags: 0, extensions: nil,
            formatDescriptionOut: &format) == noErr)
    let timecodeFormat = try #require(format)
    let timecodeIn = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: timecodeFormat)
    writer.add(videoIn)
    writer.add(timecodeIn)
    try #require(reader.startReading())
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var frame: Int32 = 0
    var buffer: CMBlockBuffer?
    try #require(
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: MemoryLayout<Int32>.size,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: MemoryLayout<Int32>.size, flags: 0, blockBufferOut: &buffer) == noErr)
    let block = try #require(buffer)
    try withUnsafeBytes(of: &frame) { raw in
        let base = try #require(raw.baseAddress)
        try #require(
            CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: MemoryLayout<Int32>.size) == noErr)
    }
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var size = MemoryLayout<Int32>.size
    var sample: CMSampleBuffer?
    try #require(
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: timecodeFormat, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr)
    while !timecodeIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
    try #require(timecodeIn.append(try #require(sample)))
    timecodeIn.markAsFinished()
    while true {
        if videoIn.isReadyForMoreMediaData {
            if let videoSample = videoOut.copyNextSampleBuffer() {
                try #require(videoIn.append(videoSample))
            } else {
                videoIn.markAsFinished()
                break
            }
        } else {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return destination
}

func multiplexedOgg(headers: [Data]) async throws -> URL {
    let folder = try TestVolume.makeFolder()
    let primary = folder.appending(path: "primary.ogg")
    try await AudioSignals.write(AudioSignals.music(seconds: 0.1), to: primary, format: .ogg)
    let primaryBytes = try Data(contentsOf: primary)
    let headerLength = 27
    let segments = Int(primaryBytes[26])
    let firstPageLength =
        headerLength + segments
        + primaryBytes[headerLength..<(headerLength + segments)].reduce(0) { $0 + Int($1) }
    var extra = Data()
    for (index, header) in headers.enumerated() {
        let url = folder.appending(path: "extra-\(index).ogg")
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(header)
        try writer.close()
        extra.append(try Data(contentsOf: url))
    }
    let mixed = folder.appending(path: "mixed.ogg")
    try (primaryBytes.prefix(firstPageLength) + extra + primaryBytes.dropFirst(firstPageLength)).write(to: mixed)
    return mixed
}
