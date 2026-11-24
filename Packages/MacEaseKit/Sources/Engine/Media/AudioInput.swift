import AVFoundation
import AudioToolbox
import Formats
import Foundation

public enum AudioContainer: Sendable {
    case mp3
    case mpeg4
    case adts
    case wave
    case aiff
    case caf
    case flac
    case ogg
}

public enum AudioCodec: Equatable, Sendable {
    case pcm
    case alac
    case flac
    case aac
    case mp3
    case vorbis
    case opus
    case other(String)

    public var isLossy: Bool {
        switch self {
        case .pcm, .alac, .flac: false
        default: true
        }
    }
}

/// A probed file, decodable repeatedly.
public struct AudioInput: Sendable {
    private static let headerLength = 64
    static let asfSignature: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]

    public let url: URL
    public let container: AudioContainer
    public let codec: AudioCodec
    public let sampleRate: Double
    public let channels: Int
    let channelLayoutTag: AudioChannelLayoutTag?
    /// Integer depth of PCM and lossless sources.
    public let bitDepth: Int?
    public let isFloat: Bool
    /// `nil` when the container does not say.
    public let frameCount: Int64?
    let multiplexedOggStreams: Set<SkippedMediaStream>
    let fallbackOrigin: FallbackSourceDescription?
    var isFallback: Bool { fallbackOrigin != nil }
    var sourceIsLossy: Bool {
        if let fallbackOrigin { return !fallbackOrigin.isLosslessAudio }
        return codec.isLossy
    }

    public init(url: URL, allowsMultiplexedOgg: Bool = false) throws {
        try self.init(url: url, allowsMultiplexedOgg: allowsMultiplexedOgg, fallbackOrigin: nil)
    }

    init(url: URL, allowsMultiplexedOgg: Bool, fallbackOrigin: FallbackSourceDescription?) throws {
        self.url = url
        self.fallbackOrigin = fallbackOrigin
        do {
            container = try Self.sniff(url)
            if container == .ogg {
                let reader = try OggAudioReader(url: url, allowsMultiplexedStreams: allowsMultiplexedOgg)
                codec = reader.codec == .opus ? .opus : .vorbis
                sampleRate = reader.sampleRate
                channels = reader.channels
                channelLayoutTag = PCMFormat.layoutTag(channels: reader.channels)
                bitDepth = nil
                isFloat = false
                frameCount = reader.frameCount
                multiplexedOggStreams = reader.multiplexedStreams
            } else {
                try Self.validateAudioToolbox(url)
                let file: AVAudioFile
                do {
                    file = try AVAudioFile(forReading: url)
                } catch {
                    throw EngineError.decodeFailed("AudioToolbox cannot open the file: \((error as NSError).code)")
                }
                let description = file.fileFormat.streamDescription.pointee
                codec = Self.codec(description.mFormatID)
                sampleRate = description.mSampleRate
                channels = Int(description.mChannelsPerFrame)
                channelLayoutTag = file.fileFormat.channelLayout?.layout.pointee.mChannelLayoutTag
                let nativeFloat = codec == .pcm && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                let nativeBitDepth = Self.bitDepth(codec: codec, description: description)
                if let fallbackOrigin {
                    isFloat = fallbackOrigin.isFloat
                    bitDepth = fallbackOrigin.isLosslessAudio ? (fallbackOrigin.bitDepth ?? nativeBitDepth) : nil
                } else {
                    isFloat = nativeFloat
                    bitDepth = nativeBitDepth
                }
                frameCount = file.length
                multiplexedOggStreams = []
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
        try AudioMetadata.validate(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
    }

    static func openWithFallback(
        _ originalURL: URL, context: ItemContext, allowsMultiplexedOgg: Bool = true, enforceStreamConsent: Bool = true
    ) async throws -> AudioInput {
        try await UntrustedMediaAsset.rejectExternalReferences(in: originalURL)
        let nativeError: EngineError
        do {
            return try AudioInput(url: originalURL, allowsMultiplexedOgg: allowsMultiplexedOgg)
        } catch {
            let wrapped = EngineError.wrapping(error, path: originalURL.path)
            switch wrapped {
            case .decodeFailed, .unsupportedCodec:
                nativeError = wrapped
            default:
                throw wrapped
            }
        }
        let staged: StagedMediaFallback.StagedAudio
        do {
            staged = try await StagedMediaFallback.prepareAudio(
                originalURL, context: context, enforceStreamConsent: enforceStreamConsent)
        } catch {
            let wrapped = EngineError.wrapping(error, path: originalURL.path)
            switch wrapped {
            case .decodeFailed, .unsupportedCodec:
                throw nativeError
            default:
                throw wrapped
            }
        }
        return try AudioInput(url: staged.stagedURL, allowsMultiplexedOgg: false, fallbackOrigin: staged.origin)
    }

    /// A fresh decoder positioned at the start.
    public func open() throws -> any PCMSource {
        do {
            return container == .ogg
                ? try OggAudioReader(url: url, allowsMultiplexedStreams: !multiplexedOggStreams.isEmpty)
                : try AudioFileReader(url: url)
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    public func tags() async throws -> AudioTags {
        do {
            var loaded: AudioTags
            switch container {
            case .ogg:
                loaded = try OggAudioReader(url: url, allowsMultiplexedStreams: !multiplexedOggStreams.isEmpty).tags
            case .flac:
                loaded = try FLACMetadata.tags(in: url)
            default:
                loaded = try await Self.commonTags(url)
            }
            if let fallbackTags = fallbackOrigin?.fallbackAudioTags {
                if loaded.title == nil { loaded.title = fallbackTags.title }
                if loaded.artist == nil { loaded.artist = fallbackTags.artist }
                if loaded.album == nil { loaded.album = fallbackTags.album }
                if loaded.artwork == nil { loaded.artwork = fallbackTags.artwork }
            }
            return loaded
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    /// The writable format reproducing container and codec.
    var exactFormat: AudioFormat? {
        guard !isFallback else { return nil }
        return switch (container, codec) {
        case (.mp3, .mp3): .mp3
        case (.mpeg4, .aac): .m4aAAC
        case (.mpeg4, .alac): .m4aALAC
        case (.adts, .aac): .aac
        case (.wave, .pcm): .wav
        case (.aiff, .pcm): .aiff
        case (.flac, .flac): .flac
        case (.ogg, .vorbis): .ogg
        case (.ogg, .opus): .opus
        case (.caf, .pcm): .cafPCM
        case (.caf, .alac): .cafALAC
        default: nil
        }
    }

    public var duration: Double? {
        frameCount.map { Double($0) / sampleRate }
    }

    private static func sniff(_ url: URL) throws -> AudioContainer {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var header = [UInt8](try handle.read(upToCount: headerLength) ?? Data())
        if header.starts(with: asfSignature) { throw EngineError.unsupportedCodec("Windows Media Audio") }
        let ascii = { (offset: Int, text: String) in
            header.count >= offset + text.utf8.count
                && header[offset..<(offset + text.utf8.count)].elementsEqual(text.utf8)
        }
        if ascii(4, "ftyp") { return .mpeg4 }
        if (ascii(0, "RIFF") || ascii(0, "RF64") || ascii(0, "BW64")), ascii(8, "WAVE") { return .wave }
        if ascii(0, "FORM"), ascii(8, "AIF") { return .aiff }
        if ascii(0, "caff") { return .caf }
        if ascii(0, "fLaC") { return .flac }
        if ascii(0, "OggS") { return .ogg }
        if let tagLength = ID3Tag.length(prefix: header) {
            try handle.seek(toOffset: UInt64(tagLength))
            header = [UInt8](try handle.read(upToCount: headerLength) ?? Data())
            if ascii(0, "fLaC") { return .flac }
        }
        guard header.count >= 2, header[0] == 0xFF, header[1] & 0xE0 == 0xE0 else {
            throw EngineError.decodeFailed("unrecognized audio container")
        }
        // ADTS has zero MPEG layer bits.
        return header[1] & 0x06 == 0 ? .adts : .mp3
    }

    private static func codec(_ formatID: AudioFormatID) -> AudioCodec {
        switch formatID {
        case kAudioFormatLinearPCM: .pcm
        case kAudioFormatAppleLossless: .alac
        case kAudioFormatFLAC: .flac
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
            kAudioFormatMPEG4AAC_ELD:
            .aac
        case kAudioFormatMPEGLayer3: .mp3
        case kAudioFormatOpus: .opus
        default: .other(fourCharacterCode(formatID))
        }
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(value >> $0 & 0xFF) }, as: UTF8.self)
    }

    /// Apple source-depth flags: 1 means 16 bits.
    private static func bitDepth(codec: AudioCodec, description: AudioStreamBasicDescription) -> Int? {
        switch codec {
        case .pcm: Int(description.mBitsPerChannel)
        case .alac, .flac: [1: 16, 2: 20, 3: 24, 4: 32][description.mFormatFlags]
        default: nil
        }
    }

    private static func commonTags(_ url: URL) async throws -> AudioTags {
        var tags = AudioTags()
        for item in try await UntrustedMediaAsset.make(url).load(.commonMetadata) {
            switch item.commonKey {
            case .commonKeyTitle where tags.title == nil: tags.title = try await item.load(.stringValue)
            case .commonKeyArtist where tags.artist == nil: tags.artist = try await item.load(.stringValue)
            case .commonKeyAlbumName where tags.album == nil: tags.album = try await item.load(.stringValue)
            case .commonKeyArtwork where tags.artwork == nil:
                if let data = try await item.load(.dataValue) {
                    tags.artwork = Artwork(data: data, mimeType: mimeType(of: data))
                }
            default: break
            }
        }
        return tags
    }

    private static func mimeType(of image: Data) -> String {
        image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    // AVAudioFile raises NSException on undecodable tracks.
    static func validateAudioToolbox(_ url: URL) throws {
        var audioFile: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &audioFile)
        guard openStatus == noErr, let audioFile else {
            throw EngineError.decodeFailed("AudioToolbox cannot open the file: \(openStatus)")
        }
        defer { ExtAudioFileDispose(audioFile) }
        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = ExtAudioFileGetProperty(
            audioFile, kExtAudioFileProperty_FileDataFormat, &formatSize, &fileFormat)
        guard formatStatus == noErr else {
            throw EngineError.decodeFailed("AudioToolbox cannot read the format: \(formatStatus)")
        }
        guard fileFormat.mChannelsPerFrame > 0, fileFormat.mSampleRate.isFinite, fileFormat.mSampleRate > 0 else {
            throw EngineError.decodeFailed("AudioToolbox reported invalid audio parameters")
        }
        let sampleBytes = UInt32(MemoryLayout<Float>.size)
        let frameBytes = fileFormat.mChannelsPerFrame * sampleBytes
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: frameBytes,
            mFramesPerPacket: 1, mBytesPerFrame: frameBytes, mChannelsPerFrame: fileFormat.mChannelsPerFrame,
            mBitsPerChannel: sampleBytes * 8, mReserved: 0)
        let clientStatus = ExtAudioFileSetProperty(
            audioFile, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard clientStatus == noErr else {
            if case .other(let name) = codec(fileFormat.mFormatID) {
                throw EngineError.unsupportedCodec(name)
            }
            throw EngineError.decodeFailed("AudioToolbox cannot decode the file: \(clientStatus)")
        }
        var frameLength: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        let lengthStatus = ExtAudioFileGetProperty(
            audioFile, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &frameLength)
        guard lengthStatus == noErr else {
            throw EngineError.decodeFailed("AudioToolbox cannot read the file length: \(lengthStatus)")
        }
        var position: Int64 = 0
        let tellStatus = ExtAudioFileTell(audioFile, &position)
        guard tellStatus == noErr else {
            throw EngineError.decodeFailed("AudioToolbox cannot seek the file: \(tellStatus)")
        }
    }
}

/// `AVAudioFile` decoding, in WAV channel order.
final class AudioFileReader: PCMSource {
    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    /// AAC surround starts with the centre.
    private let reorder: PCMConverter?
    let sampleRate: Double
    let channels: Int

    init(url: URL) throws {
        try AudioInput.validateAudioToolbox(url)
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else {
            throw EngineError.decodeFailed("no buffer for \(format)")
        }
        self.buffer = buffer
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        reorder = channels > 2 ? try PCMConverter(from: format, toSampleRate: sampleRate, channels: channels) : nil
    }

    func read() throws -> [Float]? {
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: Self.chunkFrames)
            let samples = PCMFormat.samples(buffer)
            guard !samples.isEmpty else { break }
            guard samples.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
            guard let reorder else { return samples }
            let reordered = try reorder.convert(samples)
            guard reordered.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
            if !reordered.isEmpty { return reordered }
        }
        guard let tail = try reorder?.finish(), !tail.isEmpty else { return nil }
        guard tail.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
        return tail
    }
}

extension EngineError {
    /// Formats failures in engine terms.
    static func fromAudio(_ error: any Error) -> any Error {
        guard let format = error as? FormatError else { return error }
        return EngineError(format)
    }
}
