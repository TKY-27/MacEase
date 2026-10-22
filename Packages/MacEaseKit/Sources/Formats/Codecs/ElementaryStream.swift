import Foundation

/// ISO/IEC 14496-1 descriptors inside `esds` atoms.
public enum ElementaryStream {
    private static let esDescriptorTag: UInt8 = 3
    private static let decoderConfigTag: UInt8 = 4
    private static let decoderSpecificTag: UInt8 = 5
    private static let syncLayerTag: UInt8 = 6
    private static let mp4SyncLayer: UInt8 = 2
    private static let mpeg4VideoObjectType: UInt8 = 0x20
    private static let aacObjectType: UInt8 = 0x40
    private static let visualStreamType: UInt8 = 0x11
    private static let audioStreamType: UInt8 = 0x15
    private static let streamDependenceFlag: UInt8 = 0x80
    private static let urlFlag: UInt8 = 0x40
    private static let ocrStreamFlag: UInt8 = 0x20
    /// Buffer size and two bitrates.
    private static let decoderConfigTail = 11

    /// An `esds` atom body for MPEG-4 Visual.
    static func videoDescriptor(_ decoderSpecificInfo: Data) -> Data {
        Data(count: 4) + descriptor(decoderSpecificInfo, objectType: mpeg4VideoObjectType, streamType: visualStreamType)
    }

    /// The magic cookie AudioToolbox expects for AAC.
    public static func audioDescriptor(_ audioSpecificConfig: Data) -> Data {
        descriptor(audioSpecificConfig, objectType: aacObjectType, streamType: audioStreamType)
    }

    private static func descriptor(_ specific: Data, objectType: UInt8, streamType: UInt8) -> Data {
        let configuration = Data([objectType, streamType]) + Data(count: decoderConfigTail)
        let decoder = element(decoderConfigTag, configuration + element(decoderSpecificTag, specific))
        let identifier = Data([0, 1, 0])
        return element(esDescriptorTag, identifier + decoder + element(syncLayerTag, Data([mp4SyncLayer])))
    }

    private static func element(_ tag: UInt8, _ body: Data) -> Data {
        var length = body.count
        var encoded: [UInt8] = [UInt8(length & 0x7F)]
        length >>= 7
        while length > 0 {
            encoded.insert(UInt8(length & 0x7F) | 0x80, at: 0)
            length >>= 7
        }
        return Data([tag] + encoded) + body
    }

    public static func decoderSpecificInfo(in descriptors: Data) -> Data? {
        let bytes = [UInt8](descriptors)
        var index = bytes.first == esDescriptorTag ? 0 : 4
        while index < bytes.count {
            let tag = bytes[index]
            index += 1
            var length = 0
            for _ in 0..<4 where index < bytes.count {
                let byte = bytes[index]
                index += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            switch tag {
            case decoderSpecificTag:
                guard index + length <= bytes.count else { return nil }
                return Data(bytes[index..<(index + length)])
            case esDescriptorTag:
                guard index + 3 <= bytes.count else { return nil }
                let flags = bytes[index + 2]
                index += 3
                if flags & streamDependenceFlag != 0 { index += 2 }
                if flags & urlFlag != 0, index < bytes.count { index += 1 + Int(bytes[index]) }
                if flags & ocrStreamFlag != 0 { index += 2 }
            case decoderConfigTag:
                index += 2 + decoderConfigTail
            default:
                index += length
            }
        }
        return nil
    }
}
