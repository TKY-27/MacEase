import CoreMedia
import Foundation

enum DolbyVisionConfiguration {
    private static let maximumSampleEntryBytes = 1_048_576
    private static let visualSampleEntryBytes = 86
    private static let configurationBytes = 24
    private static let hevcConfigurationBytes = 23
    private static let terminatorBytes = 4
    private static let dolbyAtomTypes: Set<String> = ["dvcC", "dvvC", "dvwC"]
    private static let inspectedAtomTypes: Set<String> = dolbyAtomTypes.union(["hvcC"])

    static func isProfile84(_ format: CMFormatDescription) throws -> Bool {
        var atoms: [String: Data] = [:]
        if let extensions = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        {
            for (type, value) in extensions where inspectedAtomTypes.contains(type) {
                let payload: Data
                if let single = value as? Data {
                    payload = single
                } else if let multiple = value as? [Data], multiple.count == 1, let first = multiple.first {
                    payload = first
                } else {
                    throw EngineError.hdrConversionUnsupported
                }
                try add(payload, type: type, to: &atoms)
            }
        }
        for key in [
            kCMFormatDescriptionExtension_VerbatimISOSampleEntry,
            kCMFormatDescriptionExtension_VerbatimSampleDescription,
        ] {
            if let entry = CMFormatDescriptionGetExtension(format, extensionKey: key) as? Data {
                try inspect(entry, subtype: CMFormatDescriptionGetMediaSubType(format), into: &atoms)
            }
        }

        let dolbyTypes = atoms.keys.filter { dolbyAtomTypes.contains($0) }
        guard !dolbyTypes.isEmpty else {
            let subtype = CMFormatDescriptionGetMediaSubType(format)
            guard !["dvhe", "dvh1", "dvav", "dva1"].contains(code(subtype)) else {
                throw EngineError.hdrConversionUnsupported
            }
            return false
        }
        guard dolbyTypes == ["dvvC"], let record = atoms["dvvC"], record.count == configurationBytes,
            CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
            let hevc = atoms["hvcC"], isMain10(hevc)
        else { throw EngineError.hdrConversionUnsupported }
        let bytes = [UInt8](record)
        let profile = bytes[2] >> 1
        let compatibility = bytes[4] >> 4
        guard bytes[0] == 1, bytes[1] == 0, profile == 8, compatibility == 4,
            bytes[3] & 0b0000_0100 != 0, bytes[3] & 0b0000_0010 == 0,
            bytes[3] & 0b0000_0001 != 0,
            bytes[4] & 0x0F == 0, bytes[5...].allSatisfy({ $0 == 0 }),
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
                as? String == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
                as? String == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
                as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        else { throw EngineError.hdrConversionUnsupported }
        return true
    }

    private static func isMain10(_ payload: Data) -> Bool {
        let bytes = [UInt8](payload)
        return bytes.count >= hevcConfigurationBytes && bytes[0] == 1 && bytes[1] & 0x1F == 2
            && bytes[16] & 0x03 == 1 && bytes[17] & 0x07 == 2 && bytes[18] & 0x07 == 2
    }

    private static func add(_ payload: Data, type: String, to atoms: inout [String: Data]) throws {
        guard payload.count <= maximumSampleEntryBytes, atoms[type].map({ $0 == payload }) ?? true else {
            throw EngineError.hdrConversionUnsupported
        }
        atoms[type] = payload
    }

    private static func inspect(_ entry: Data, subtype: FourCharCode, into atoms: inout [String: Data]) throws {
        guard entry.count >= visualSampleEntryBytes, entry.count <= maximumSampleEntryBytes else {
            throw EngineError.hdrConversionUnsupported
        }
        let bytes = [UInt8](entry)
        guard size(at: 0, in: bytes) == entry.count,
            code(at: 4, in: bytes) == code(subtype)
        else { throw EngineError.hdrConversionUnsupported }
        var position = visualSampleEntryBytes
        while position < bytes.count {
            // QuickTime may end extension atoms with zeros.
            if bytes.count - position == terminatorBytes, bytes[position...].allSatisfy({ $0 == 0 }) { break }
            guard bytes.count - position >= 8 else { throw EngineError.hdrConversionUnsupported }
            let smallSize = size(at: position, in: bytes)
            let headerSize = smallSize == 1 ? 16 : 8
            guard bytes.count - position >= headerSize else { throw EngineError.hdrConversionUnsupported }
            let length =
                smallSize == 0
                ? bytes.count - position
                : smallSize == 1 ? largeSize(at: position + 8, in: bytes) : smallSize
            guard length >= headerSize, length <= bytes.count - position else {
                throw EngineError.hdrConversionUnsupported
            }
            let type = code(at: position + 4, in: bytes)
            if inspectedAtomTypes.contains(type) {
                let payload = Data(bytes[(position + headerSize)..<(position + length)])
                try add(payload, type: type, to: &atoms)
            }
            position += length
        }
    }

    private static func size(at offset: Int, in bytes: [UInt8]) -> Int {
        bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func largeSize(at offset: Int, in bytes: [UInt8]) -> Int {
        let raw = bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(exactly: raw) ?? 0
    }

    private static func code(at offset: Int, in bytes: [UInt8]) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func code(_ value: FourCharCode) -> String {
        String(decoding: (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) }, as: UTF8.self)
    }
}
