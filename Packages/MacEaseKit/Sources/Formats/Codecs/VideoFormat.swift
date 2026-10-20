import CoreMedia
import Foundation

/// Bridges `MediaTrack` and CoreMedia video format descriptions.
public enum VideoFormat {
    private static let startCode: [UInt8] = [0, 0, 1]
    private static let vopStartCode: UInt8 = 0xB6
    private static let avcLengthSize = 4
    private static let reservedLengthBits: UInt8 = 0xFC
    private static let reservedCountBits: UInt8 = 0xE0
    private static let avcSequenceParameterSet: UInt8 = 7
    private static let avcPictureParameterSet: UInt8 = 8
    private static let maximumSequenceSets = 31

    public static func codecType(_ codec: MediaCodec) -> CMVideoCodecType? {
        switch codec {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .mpeg4Part2: kCMVideoCodecType_MPEG4Video
        case .mjpeg: kCMVideoCodecType_JPEG
        case .av1: kCMVideoCodecType_AV1
        case .vp9: kCMVideoCodecType_VP9
        case .prores: kCMVideoCodecType_AppleProRes422
        default: nil
        }
    }

    public static func description(for track: MediaTrack) throws -> CMVideoFormatDescription {
        guard case .video(let width, let height) = track.kind, var codecType = codecType(track.codec) else {
            throw FormatError.unsupported(track.codec.displayName)
        }
        guard width > 0, height > 0, Int32(exactly: width) != nil, Int32(exactly: height) != nil else {
            throw FormatError.corrupt(
                String(localized: "Video dimensions out of range", comment: "Invalid video metadata"))
        }
        if track.codec == .prores, let fourCC = track.codecPrivate, fourCC.count == 4 {
            codecType = fourCC.reduce(0) { $0 << 8 | CMVideoCodecType($1) }
        }
        var atoms: [String: Data] = [:]
        switch (track.codec, track.codecPrivate) {
        case (.h264, let record?): atoms["avcC"] = record
        case (.hevc, let record?): atoms["hvcC"] = record
        case (.av1, let record?): atoms["av1C"] = record
        case (.mpeg4Part2, let header?): atoms["esds"] = ElementaryStream.videoDescriptor(header)
        case (.h264, nil), (.hevc, nil), (.av1, nil):
            throw FormatError.corrupt("\(track.codec.displayName) without decoder configuration")
        default: break
        }
        let extensions: [CFString: Any] =
            atoms.isEmpty ? [:] : [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codecType, width: Int32(width), height: Int32(height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw FormatError.corrupt("format description (\(status))") }
        return description
    }

    public static func decoderConfiguration(of description: CMFormatDescription) -> Data? {
        let atoms =
            CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any]
        return (atoms?["avcC"] ?? atoms?["hvcC"] ?? atoms?["av1C"]) as? Data
    }

    /// The bytes before the first VOP.
    public static func mpeg4Header(inKeyframe payload: Data) -> Data? {
        let bytes = [UInt8](payload)
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1, bytes[index + 3] == vopStartCode {
                return index > 0 ? Data(bytes[0..<index]) : nil
            }
            index += 1
        }
        return nil
    }

    public static func isAnnexB(_ payload: Data) -> Bool {
        payload.starts(with: [0, 0, 0, 1]) || payload.starts(with: startCode)
    }

    /// Start-code NAL units to 4-byte length prefixes.
    public static func lengthPrefixed(annexB payload: Data) throws -> Data {
        var output = Data()
        for unit in nalUnits(annexB: payload) {
            guard let length = UInt32(exactly: unit.count) else {
                throw FormatError.corrupt(
                    String(localized: "Video packet too large", comment: "Invalid video packet"))
            }
            output.appendBigEndian(length)
            output.append(contentsOf: unit)
        }
        return output
    }

    static func nalUnits(annexB payload: Data) -> [ArraySlice<UInt8>] {
        let bytes = [UInt8](payload)
        var starts: [(code: Int, data: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let code = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
                starts.append((code, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().map { position, start in
            let end = position + 1 < starts.count ? starts[position + 1].code : bytes.count
            return bytes[start.data..<max(start.data, end)]
        }
    }

    /// Built from an Annex B keyframe.
    public static func avcConfiguration(annexB keyframe: Data) throws -> Data {
        let units = nalUnits(annexB: keyframe)
        let sequenceSets = units.filter { $0.first.map { $0 & 0x1F } == avcSequenceParameterSet }
        let pictureSets = units.filter { $0.first.map { $0 & 0x1F } == avcPictureParameterSet }
        guard let first = sequenceSets.first, first.count >= 4, !pictureSets.isEmpty else {
            throw FormatError.corrupt("H.264 keyframe without SPS and PPS")
        }
        guard sequenceSets.count <= maximumSequenceSets, pictureSets.count <= Int(UInt8.max),
            sequenceSets.allSatisfy({ $0.count <= Int(UInt16.max) }),
            pictureSets.allSatisfy({ $0.count <= Int(UInt16.max) })
        else {
            throw FormatError.corrupt(
                String(localized: "H.264 parameter sets out of range", comment: "Invalid decoder configuration"))
        }
        let profile = Array(first)
        var record = Data([1, profile[1], profile[2], profile[3], reservedLengthBits | UInt8(avcLengthSize - 1)])
        record.append(reservedCountBits | UInt8(sequenceSets.count))
        for set in sequenceSets {
            record.appendBigEndian(UInt16(set.count))
            record.append(contentsOf: set)
        }
        record.append(UInt8(pictureSets.count))
        for set in pictureSets {
            record.appendBigEndian(UInt16(set.count))
            record.append(contentsOf: set)
        }
        return record
    }
}
