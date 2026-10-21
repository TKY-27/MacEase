import AVFoundation
import AudioToolbox
import Formats
import Foundation

/// Every audio file format MacEase writes.
public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case mp3
    case m4aAAC = "m4a-aac"
    case m4aALAC = "m4a-alac"
    case aac
    case wav
    case aiff
    case flac
    case ogg
    case opus
    case cafPCM = "caf-pcm"
    case cafALAC = "caf-alac"

    private static let opusKilobits = Array(6...510)
    private static let vorbisCandidates = Array(stride(from: 32, through: 480, by: 8))
    private static let aacRates: Set<Double> = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    private static let mp3Rates = (low: 44_100.0, high: 48_000.0)

    public var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .m4aAAC, .m4aALAC: "m4a"
        case .aac: "aac"
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .ogg: "ogg"
        case .opus: "opus"
        case .cafPCM, .cafALAC: "caf"
        }
    }

    /// Original extensions an output may keep.
    var keptExtensions: Set<String> {
        switch self {
        case .m4aAAC, .m4aALAC: ["m4a", "mp4", "m4b"]
        case .aiff: ["aiff", "aif", "aifc"]
        case .ogg: ["ogg", "oga"]
        case .opus: ["opus", "ogg", "oga"]
        default: [fileExtension]
        }
    }

    public var isLossy: Bool {
        switch self {
        case .mp3, .m4aAAC, .aac, .ogg, .opus: true
        default: false
        }
    }

    /// Ascending; empty for lossless formats.
    public func supportedKilobits(sampleRate: Double, channels: Int) throws -> [Int] {
        let rate = Int(outputSampleRate(sampleRate))
        let count = outputChannels(channels)
        return switch self {
        case .mp3: MP3EncoderOptions.constantBitrates
        case .m4aAAC, .aac: try AACEncoder.applicableKilobits(sampleRate: rate, channels: count)
        case .opus: Self.opusKilobits
        case .ogg:
            Self.vorbisCandidates.filter {
                VorbisAudioEncoder.accepts(sampleRate: rate, channels: count, bitrate: $0 * 1_000)
            }
        default: []
        }
    }

    /// Encoders reject bitrates outside their lists.
    func nearestKilobits(_ requested: Int, sampleRate: Double, channels: Int) throws -> Int {
        let supported = try supportedKilobits(sampleRate: sampleRate, channels: channels)
        guard let lowest = supported.first else { throw EngineError.unsupportedCodec("\(fileExtension) bitrates") }
        return supported.last { $0 <= requested } ?? lowest
    }

    func outputSampleRate(_ rate: Double) -> Double {
        let mp3Rate =
            rate.truncatingRemainder(dividingBy: Self.mp3Rates.high) == 0 ? Self.mp3Rates.high : Self.mp3Rates.low
        return switch self {
        case .mp3: mp3Rate
        case .opus: Double(OpusAudioEncoder.sampleRate)
        case .m4aAAC, .aac, .ogg: Self.aacRates.contains(rate) ? rate : mp3Rate
        default: rate
        }
    }

    func outputChannels(_ channels: Int) -> Int {
        isLossy ? min(channels, 2) : channels
    }
}

/// A format with its encoder settings.
public struct AudioTarget: Hashable, Sendable {
    public var format: AudioFormat
    /// Ignored by lossless formats.
    public var kilobits: Int
    /// MP3 only; `nil` means constant bitrate.
    public var variableQuality: Int?

    public init(format: AudioFormat, kilobits: Int, variableQuality: Int? = nil) {
        self.format = format
        self.kilobits = kilobits
        self.variableQuality = variableQuality
    }

    public static func defaults(for format: AudioFormat, settings: AudioSettings) -> AudioTarget {
        switch format {
        case .mp3:
            AudioTarget(
                format: format, kilobits: settings.mp3Bitrate,
                variableQuality: settings.mp3Mode == .vbr ? settings.mp3VBRQuality : nil)
        case .m4aAAC, .aac: AudioTarget(format: format, kilobits: settings.aacBitrate)
        case .opus: AudioTarget(format: format, kilobits: settings.opusBitrate)
        case .ogg: AudioTarget(format: format, kilobits: settings.vorbisBitrate)
        default: AudioTarget(format: format, kilobits: 0)
        }
    }
}

protocol AudioSink: AnyObject {
    func write(_ interleaved: [Float]) async throws
    func finish() async throws
}

extension FLACFileWriter: AudioSink {}
extension OggAudioWriter: AudioSink {}

/// Resamples as needed, then writes a file.
public final class AudioFileEncoder {
    private static let defaultDepth = 16
    private static let highDepth = 24
    private static let alacMiddleDepth = 20
    private static let floatDepth = 32

    private let sink: any AudioSink
    private let converter: PCMConverter?

    public init(
        url: URL, target: AudioTarget, sampleRate: Double, channels: Int, bitDepth: Int? = nil, isFloat: Bool = false,
        tags: AudioTags = AudioTags()
    ) throws {
        let format = target.format
        let rate = format.outputSampleRate(sampleRate)
        let count = format.outputChannels(channels)
        let losslessDepth = bitDepth.map { $0 <= Self.defaultDepth ? Self.defaultDepth : Self.highDepth }
        do {
            let kilobits =
                format.isLossy && target.variableQuality == nil
                ? try format.nearestKilobits(target.kilobits, sampleRate: sampleRate, channels: channels)
                : target.kilobits
            let bits = kilobits * 1_000
            converter =
                rate == sampleRate && count == channels
                ? nil
                : try PCMConverter(sampleRate: sampleRate, channels: channels, toSampleRate: rate, channels: count)
            switch format {
            case .mp3:
                let mode: MP3EncoderOptions.Mode =
                    target.variableQuality.map { .variable(quality: $0) } ?? .constant(kilobits: kilobits)
                sink = try MP3Sink(url: url, sampleRate: Int(rate), channels: count, mode: mode, tags: tags)
            case .m4aAAC, .m4aALAC:
                let depth = bitDepth == Self.alacMiddleDepth ? Self.alacMiddleDepth : losslessDepth ?? Self.highDepth
                sink = try MPEG4Sink(
                    url: url, sampleRate: rate, channels: count, codec: format == .m4aAAC ? .aac(bits) : .alac(depth),
                    tags: tags)
            case .aac:
                sink = try ADTSSink(url: url, sampleRate: Int(rate), channels: count, kilobits: kilobits)
            case .wav, .aiff, .cafPCM:
                let float = isFloat && format != .aiff
                let depth = float ? Self.floatDepth : isFloat ? Self.highDepth : bitDepth ?? Self.defaultDepth
                sink = try PCMFileSink(
                    url: url, format: format, sampleRate: rate, channels: count, codec: .pcm(bits: depth, float: float))
            case .cafALAC:
                sink = try PCMFileSink(
                    url: url, format: format, sampleRate: rate, channels: count,
                    codec: .alac(losslessDepth ?? Self.highDepth))
            case .flac:
                sink = try FLACFileWriter(
                    url: url, sampleRate: Int(rate), channels: count,
                    bitsPerSample: isFloat ? Self.highDepth : losslessDepth ?? Self.defaultDepth, tags: tags)
            case .ogg, .opus:
                sink = try OggAudioWriter(
                    url: url, codec: format == .ogg ? .vorbis : .opus, sampleRate: Int(rate), channels: count,
                    bitrate: bits, tags: tags)
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    public func write(_ interleaved: [Float]) async throws {
        do {
            let converted = try converter?.convert(interleaved) ?? interleaved
            if !converted.isEmpty { try await sink.write(converted) }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    public func finish() async throws {
        do {
            if let tail = try converter?.finish(), !tail.isEmpty { try await sink.write(tail) }
            try await sink.finish()
        } catch {
            throw EngineError.fromAudio(error)
        }
    }
}

enum StoredCodec {
    case pcm(bits: Int, float: Bool)
    case alac(Int)
    case aac(Int)
}

/// AudioToolbox encoding into WAV, AIFF or CAF.
private final class PCMFileSink: AudioSink {
    private let file: AVAudioFile

    init(url: URL, format: AudioFormat, sampleRate: Double, channels: Int, codec: StoredCodec) throws {
        let processing = try PCMFormat.make(sampleRate: sampleRate, channels: channels)
        var settings: [String: Any] = [
            AVAudioFileTypeKey: format == .wav
                ? kAudioFileWAVEType : format == .aiff ? kAudioFileAIFFType : kAudioFileCAFType,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]
        if let layout = processing.channelLayout {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        switch codec {
        case .pcm(let bits, let float):
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = bits
            settings[AVLinearPCMIsFloatKey] = float
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .alac(let bits):
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = bits
        case .aac:
            throw EngineError.unsupportedCodec("AAC in \(format.fileExtension)")
        }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    func write(_ interleaved: [Float]) throws {
        try file.write(from: PCMFormat.buffer(interleaved, format: file.processingFormat))
    }

    func finish() throws {
        file.close()
    }
}

/// `AVAssetWriter` records priming and tags.
private final class MPEG4Sink: AudioSink {
    private static let readinessPoll = Duration.milliseconds(5)

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: AVAudioFormat
    private var position: Int64 = 0

    init(url: URL, sampleRate: Double, channels: Int, codec: StoredCodec, tags: AudioTags) throws {
        format = try PCMFormat.make(sampleRate: sampleRate, channels: channels)
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        if let layout = format.channelLayout {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        switch codec {
        case .aac(let bitrate):
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = bitrate
            // Constant bitrate keeps target sizes predictable.
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        case .alac(let bits):
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = bits
        case .pcm:
            throw EngineError.unsupportedCodec("PCM in M4A")
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError.encodeFailed("M4A writer rejected the audio settings") }
        writer.add(input)
        writer.metadata = Self.metadata(tags)
        guard writer.startWriting() else { throw EngineError.encodeFailed("M4A writer did not start") }
        writer.startSession(atSourceTime: .zero)
    }

    deinit {
        if writer.status == .writing { writer.cancelWriting() }
    }

    private static func metadata(_ tags: AudioTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        let texts: [(AVMetadataIdentifier, String?)] = [
            (.iTunesMetadataSongName, tags.title), (.iTunesMetadataArtist, tags.artist),
            (.iTunesMetadataAlbum, tags.album),
        ]
        for case (let identifier, let value?) in texts {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            items.append(item)
        }
        if let artwork = tags.artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = artwork.data as NSData
            item.dataType =
                (artwork.mimeType == "image/png" ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
            items.append(item)
        }
        return items
    }

    func write(_ interleaved: [Float]) async throws {
        let frames = interleaved.count / Int(format.channelCount)
        let (following, overflow) = position.addingReportingOverflow(Int64(frames))
        guard !overflow else { throw EngineError.encodeFailed("audio frame count out of range") }
        let buffer = try sampleBuffer(interleaved, frames: frames)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writerFailure }
            try await Task.sleep(for: Self.readinessPoll)
        }
        guard input.append(buffer) else { throw writerFailure }
        position = following
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerFailure }
    }

    private var writerFailure: EngineError {
        EngineError.encodeFailed(writer.error.map { "AVAssetWriter \(($0 as NSError).code)" } ?? "AVAssetWriter failed")
    }

    private func sampleBuffer(_ interleaved: [Float], frames: Int) throws -> CMSampleBuffer {
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw EngineError.encodeFailed("CMBlockBuffer \(status)") }
        status = interleaved.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadLengthParameterErr) }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        if status == noErr {
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format.formatDescription,
                sampleCount: frames,
                presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(format.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
        }
        guard status == noErr, let sample else { throw EngineError.encodeFailed("CMSampleBuffer \(status)") }
        return sample
    }
}

/// In-house MP3 frames behind an ID3v2 tag.
private final class MP3Sink: AudioSink {
    private let encoder: MP3Encoder
    private let handle: FileHandle
    private let audioStart: UInt64

    init(url: URL, sampleRate: Int, channels: Int, mode: MP3EncoderOptions.Mode, tags: AudioTags) throws {
        encoder = try MP3Encoder(options: MP3EncoderOptions(sampleRate: sampleRate, channels: channels, mode: mode))
        try ID3Tag.encode(tags).write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        audioStart = try handle.seekToEnd()
    }

    func write(_ interleaved: [Float]) throws {
        try handle.write(contentsOf: try encoder.encode(interleaved: interleaved))
    }

    func finish() throws {
        let finish = try encoder.finish()
        try handle.write(contentsOf: finish.trailingBytes)
        if let xing = finish.xingFrame {
            try handle.seek(toOffset: audioStart)
            try handle.write(contentsOf: xing)
        }
        try handle.close()
    }
}

/// ADTS frames cannot hold tags.
private final class ADTSSink: AudioSink {
    private let encoder: AACEncoder
    private let handle: FileHandle

    init(url: URL, sampleRate: Int, channels: Int, kilobits: Int) throws {
        encoder = try AACEncoder(sampleRate: sampleRate, channels: channels, kilobits: kilobits)
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ interleaved: [Float]) throws {
        try append(try encoder.encode(interleaved))
    }

    func finish() throws {
        try append(try encoder.finish())
        try handle.close()
    }

    private func append(_ packets: [Data]) throws {
        for packet in packets {
            try handle.write(contentsOf: encoder.adtsHeader(payloadLength: packet.count) + packet)
        }
    }
}
