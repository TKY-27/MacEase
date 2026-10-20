import AudioToolbox
import CoreMedia
import Foundation

/// Lets MP4 and MOV copy compressed audio.
public enum AudioFormat {
    private static let aacFramesPerPacket: UInt32 = 1024
    private static let mp3FramesPerPacket: UInt32 = 1152
    private static let ac3FramesPerPacket: UInt32 = 1536

    public static func description(for track: MediaTrack) throws -> CMAudioFormatDescription {
        guard case .audio(let sampleRate, let channels) = track.kind else {
            throw FormatError.unsupported("not an audio track")
        }
        var cookie: Data?
        let format: (id: AudioFormatID, frames: UInt32)
        switch track.codec {
        case .aac:
            guard let config = track.codecPrivate else { throw FormatError.corrupt("AAC without AudioSpecificConfig") }
            cookie = ElementaryStream.audioDescriptor(config)
            format = (kAudioFormatMPEG4AAC, aacFramesPerPacket)
        case .mp3: format = (kAudioFormatMPEGLayer3, mp3FramesPerPacket)
        case .ac3: format = (kAudioFormatAC3, ac3FramesPerPacket)
        default: throw FormatError.unsupported("\(track.codec.displayName) in MP4 or MOV")
        }
        var basic = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: format.id, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: format.frames, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = (cookie ?? Data()).withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &basic, layoutSize: 0, layout: nil, magicCookieSize: bytes.count,
                magicCookie: bytes.baseAddress, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw FormatError.corrupt("audio description (\(status))") }
        return description
    }
}
