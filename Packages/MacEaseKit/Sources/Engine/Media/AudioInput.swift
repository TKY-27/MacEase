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
    /// Integer depth of PCM and lossless sources.
    public let bitDepth: Int?
    public let isFloat: Bool
    /// `nil` when the container does not say.
    public let frameCount: Int64?

    public init(url: URL) throws {
        self.url = url
        do {
            container = try Self.sniff(url)
            if container == .ogg {
                let reader = try OggAudioReader(url: url)
                codec = reader.codec == .opus ? .opus : .vorbis
                sampleRate = reader.sampleRate
                channels = reader.channels
                bitDepth = nil
                isFloat = false
                frameCount = reader.frameCount
            } else {
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
                isFloat = codec == .pcm && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                bitDepth = Self.bitDepth(codec: codec, description: description)
                frameCount = file.length
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
        guard sampleRate > 0, channels > 0 else { throw EngineError.decodeFailed("no audio stream") }
    }

    /// A fresh decoder positioned at the start.
    public func open() throws -> any PCMSource {
        do {
            return container == .ogg ? try OggAudioReader(url: url) : try AudioFileReader(url: url)
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    public func tags() async throws -> AudioTags {
        do {
            switch container {
            case .ogg: return try OggAudioReader(url: url).tags
            case .flac: return try FLACMetadata.tags(in: url)
            default: return try await Self.commonTags(url)
            }
        } catch {
            throw EngineError.fromAudio(error)
        }
    }

    /// The writable format reproducing container and codec.
    var exactFormat: AudioFormat? {
        switch (container, codec) {
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
        if ascii(0, "RIFF"), ascii(8, "WAVE") { return .wave }
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
        for item in try await AVURLAsset(url: url).load(.commonMetadata) {
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
            guard let reorder else { return samples }
            let reordered = try reorder.convert(samples)
            if !reordered.isEmpty { return reordered }
        }
        guard let tail = try reorder?.finish(), !tail.isEmpty else { return nil }
        return tail
    }
}

extension EngineError {
    /// Formats failures in engine terms.
    static func fromAudio(_ error: any Error) -> any Error {
        guard let format = error as? FormatError else { return error }
        return switch format {
        case .unsupported(let name): EngineError.unsupportedCodec(name)
        case .corrupt(let detail): EngineError.decodeFailed(detail)
        case .encoderFailure(let detail): EngineError.encodeFailed(detail)
        case .io(let detail): EngineError.unexpected(detail)
        }
    }
}
