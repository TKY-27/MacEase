import CoreMedia
import Foundation

/// FLV v10.1 constants, AMF0, codec configs.
enum FLV {
    static let audioTag: UInt8 = 8
    static let videoTag: UInt8 = 9
    static let scriptTag: UInt8 = 18
    static let tagHeaderSize = 11
    static let fileHeaderSize = 9
    static let avcCodecID: UInt8 = 7
    static let aacSoundFormat: UInt8 = 10
    static let sequenceHeader: UInt8 = 0
    static let codedFrames: UInt8 = 1
    static let endOfSequence: UInt8 = 2
    static let keyFrame: UInt8 = 1
    static let interFrame: UInt8 = 2
    static let videoTrack = 1
    static let audioTrack = 2
    private static let amfNestingLimit = 16
    private static let amfString: UInt8 = 2
    private static let aacSampleRates: [Double] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]

    static func videoCodec(_ id: UInt8) -> MediaCodec {
        switch id {
        case avcCodecID: .h264
        case 2: .unsupported("Sorenson H.263")
        case 3, 6: .unsupported("Screen Video")
        case 4, 5: .unsupported("On2 VP6")
        default: .unsupported("FLV video codec \(id)")
        }
    }

    static func audioCodec(format: UInt8, sixteenBit: Bool) -> MediaCodec {
        switch format {
        case 0, 3: .pcm(bits: sixteenBit ? 16 : 8, float: false, bigEndian: false)
        case 2, 14: .mp3
        case aacSoundFormat: .aac
        case 4, 5, 6: .unsupported("Nellymoser")
        case 11: .unsupported("Speex")
        default: .unsupported("FLV audio format \(format)")
        }
    }

    static func audioRate(_ flags: UInt8) -> Double {
        if flags >> 4 == 14 { return 8000 }
        return [5512.5, 11025, 22050, 44100][Int(flags >> 2 & 3)]
    }

    /// Sample rate and channels from an AudioSpecificConfig.
    static func aacFormat(_ config: [UInt8]) throws -> (sampleRate: Double, channels: Int) {
        let available = min(config.count, 8)
        let bits = config.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } << UInt64(8 * (8 - available))
        var position = 0
        func read(_ count: Int) throws -> Int {
            guard position + count <= 8 * available else { throw FormatError.corrupt("short AudioSpecificConfig") }
            defer { position += count }
            return Int(bits >> UInt64(64 - position - count) & ((1 << UInt64(count)) - 1))
        }
        if try read(5) == 31 { _ = try read(6) }
        let frequencyIndex = try read(4)
        let sampleRate: Double
        if frequencyIndex == 15 {
            sampleRate = Double(try read(24))
        } else {
            guard frequencyIndex < aacSampleRates.count else { throw FormatError.corrupt("AAC frequency index") }
            sampleRate = aacSampleRates[frequencyIndex]
        }
        let channelConfiguration = try read(4)
        guard (1...7).contains(channelConfiguration) else { throw FormatError.unsupported("AAC channel layout") }
        return (sampleRate, channelConfiguration == 7 ? 8 : channelConfiguration)
    }

    /// Coded size from the avcC SPS.
    static func avcDimensions(_ record: [UInt8]) throws -> (width: Int, height: Int) {
        guard record.count >= 7, record[0] == 1 else { throw FormatError.corrupt("invalid avcC") }
        var parameterSets: [[UInt8]] = []
        var offset = 5
        for group in 0..<2 {
            guard offset < record.count else { throw FormatError.corrupt("truncated avcC") }
            let count = Int(record[offset] & (group == 0 ? 0x1F : 0xFF))
            offset += 1
            for _ in 0..<count {
                guard offset + 2 <= record.count else { throw FormatError.corrupt("truncated avcC") }
                let length = Int(record[offset]) << 8 | Int(record[offset + 1])
                guard offset + 2 + length <= record.count else { throw FormatError.corrupt("truncated avcC") }
                parameterSets.append(Array(record[(offset + 2)..<(offset + 2 + length)]))
                offset += 2 + length
            }
        }
        let joined = parameterSets.flatMap { $0 }
        var description: CMFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            var starts: [UnsafePointer<UInt8>] = []
            var offset = 0
            for set in parameterSets {
                starts.append(base + offset)
                offset += set.count
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: parameterSets.count, parameterSetPointers: starts,
                parameterSetSizes: parameterSets.map(\.count), nalUnitHeaderLength: Int32(record[4] & 3) + 1,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { throw FormatError.corrupt("H.264 parameter sets (\(status))") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return (Int(dimensions.width), Int(dimensions.height))
    }

    /// Numeric properties of an onMetaData script tag.
    static func metadata(_ body: [UInt8]) throws -> [String: Double] {
        var offset = 0
        guard body.first == amfString, try readString(body, &offset) == "onMetaData" else { return [:] }
        var numbers: [String: Double] = [:]
        try readValue(body, &offset, depth: 0, numbers: &numbers)
        return numbers
    }

    private static func readString(_ body: [UInt8], _ offset: inout Int) throws -> String {
        guard offset + 3 <= body.count, body[offset] == 2 else { throw FormatError.corrupt("AMF0 string expected") }
        offset += 1
        return try readKey(body, &offset)
    }

    private static func readKey(_ body: [UInt8], _ offset: inout Int) throws -> String {
        guard offset + 2 <= body.count else { throw FormatError.corrupt("truncated AMF0") }
        let length = Int(body[offset]) << 8 | Int(body[offset + 1])
        offset += 2
        guard offset + length <= body.count else { throw FormatError.corrupt("truncated AMF0") }
        defer { offset += length }
        return String(decoding: body[offset..<(offset + length)], as: UTF8.self)
    }

    private static func skip(_ count: Int, _ body: [UInt8], _ offset: inout Int) throws {
        guard offset + count <= body.count else { throw FormatError.corrupt("truncated AMF0") }
        offset += count
    }

    private static func readValue(
        _ body: [UInt8], _ offset: inout Int, depth: Int, numbers: inout [String: Double], key: String? = nil
    ) throws {
        guard depth < amfNestingLimit, offset < body.count else { throw FormatError.corrupt("AMF0 nesting") }
        let type = body[offset]
        offset += 1
        switch type {
        case 0:
            guard offset + 8 <= body.count else { throw FormatError.corrupt("truncated AMF0") }
            let bits = body[offset..<(offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if let key, depth == 1 { numbers[key] = Double(bitPattern: bits) }
            offset += 8
        case 1: try skip(1, body, &offset)
        case 2: _ = try readKey(body, &offset)
        case 3, 8, 16:
            if type == 8 { try skip(4, body, &offset) }
            if type == 16 { _ = try readKey(body, &offset) }
            while true {
                let name = try readKey(body, &offset)
                if name.isEmpty, offset < body.count, body[offset] == 9 {
                    offset += 1
                    break
                }
                try readValue(body, &offset, depth: depth + 1, numbers: &numbers, key: name)
            }
        case 5, 6, 13: break
        case 7: try skip(2, body, &offset)
        case 10:
            guard offset + 4 <= body.count else { throw FormatError.corrupt("truncated AMF0") }
            let count = Int(UInt32(bigEndian: body, at: offset))
            offset += 4
            for _ in 0..<count { try readValue(body, &offset, depth: depth + 1, numbers: &numbers) }
        case 11: try skip(10, body, &offset)
        case 12:
            guard offset + 4 <= body.count else { throw FormatError.corrupt("truncated AMF0") }
            try skip(4 + Int(UInt32(bigEndian: body, at: offset)), body, &offset)
        default: throw FormatError.unsupported("AMF0 type \(type)")
        }
    }

    static func amfNumber(_ key: String, _ value: Double) -> Data {
        var bytes = amfKey(key)
        bytes.append(0)
        bytes.appendBigEndian(value.bitPattern)
        return bytes
    }

    static func amfKey(_ key: String) -> Data {
        var bytes = Data()
        bytes.appendBigEndian(UInt16(key.utf8.count))
        bytes += Data(key.utf8)
        return bytes
    }
}
