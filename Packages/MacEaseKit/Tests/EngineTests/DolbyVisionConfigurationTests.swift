import CoreMedia
import Foundation
import Testing

@testable import Engine

@Suite struct DolbyVisionConfigurationTests {
    private static let hevc: Data = {
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1
        record[1] = 2
        record[16] = 0xF1
        record[17] = 0xFA
        record[18] = 0xFA
        return Data(record)
    }()

    private static let profile84: Data = {
        var record = [UInt8](repeating: 0, count: 24)
        record[0] = 1
        record[2] = 0x10
        record[3] = 0x35
        record[4] = 0x40
        return Data(record)
    }()

    private func format(atoms: [String: Data], entry: Data? = nil) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
        ]
        if let entry { extensions[kCMFormatDescriptionExtension_VerbatimISOSampleEntry] = entry }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 64, height: 48,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        #expect(status == noErr)
        return try #require(description)
    }

    private func sampleEntry(_ atoms: [(String, Data)], terminator: Data = Data()) -> Data {
        var entry = Data(repeating: 0, count: 86)
        entry.replaceSubrange(4..<8, with: "hvc1".utf8)
        for (type, payload) in atoms {
            let length = UInt32(payload.count + 8)
            entry.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: length >> (24 - 8 * $0)) })
            entry.append(contentsOf: type.utf8)
            entry.append(payload)
        }
        entry.append(terminator)
        let length = UInt32(entry.count)
        entry.replaceSubrange(0..<4, with: (0..<4).map { UInt8(truncatingIfNeeded: length >> (24 - 8 * $0)) })
        return entry
    }

    @Test func ordinaryHEVCIsNotDolbyVision() throws {
        let described = try format(atoms: ["hvcC": Self.hevc])
        #expect(try DolbyVisionConfiguration.isProfile84(described) == false)
    }

    @Test func acceptsHLGCompatibleProfile84() throws {
        let described = try format(atoms: ["hvcC": Self.hevc, "dvvC": Self.profile84])
        #expect(try DolbyVisionConfiguration.isProfile84(described))
    }

    @Test func readsDolbyConfigurationFromVerbatimSampleEntry() throws {
        let entry = sampleEntry([("hvcC", Self.hevc), ("dvvC", Self.profile84)])
        let described = try format(atoms: [:], entry: entry)
        #expect(try DolbyVisionConfiguration.isProfile84(described))
    }

    @Test func acceptsQuickTimeZeroTerminatorOnly() throws {
        let terminated = sampleEntry([("hvcC", Self.hevc), ("dvvC", Self.profile84)], terminator: Data(count: 4))
        #expect(try DolbyVisionConfiguration.isProfile84(format(atoms: [:], entry: terminated)))
        let ordinary = sampleEntry([("hvcC", Self.hevc)], terminator: Data(count: 4))
        #expect(try DolbyVisionConfiguration.isProfile84(format(atoms: [:], entry: ordinary)) == false)
        for trailing in [Data([0, 0, 0, 1]), Data(count: 3), Data(count: 6)] {
            let malformed = sampleEntry([("hvcC", Self.hevc)], terminator: trailing)
            #expect(throws: EngineError.hdrConversionUnsupported) {
                try DolbyVisionConfiguration.isProfile84(format(atoms: [:], entry: malformed))
            }
        }
    }

    @Test func rejectsUnsupportedAndIncompleteDolbySignalling() throws {
        var profile81 = [UInt8](Self.profile84)
        profile81[4] = 0x10
        var noBaseLayer = [UInt8](Self.profile84)
        noBaseLayer[3] &= ~UInt8(1)
        var hasEnhancementLayer = [UInt8](Self.profile84)
        hasEnhancementLayer[3] |= 2
        let configurations: [Data] = [
            Data(profile81), Data(noBaseLayer), Data(hasEnhancementLayer), Self.profile84.prefix(4),
        ]
        for configuration in configurations {
            let described = try format(atoms: ["hvcC": Self.hevc, "dvvC": configuration])
            #expect(throws: EngineError.hdrConversionUnsupported) {
                try DolbyVisionConfiguration.isProfile84(described)
            }
        }
    }

    @Test func rejectsConflictingSampleDescriptions() throws {
        let entry = sampleEntry([("hvcC", Self.hevc), ("dvvC", Self.profile84)])
        var altered = [UInt8](Self.profile84)
        altered[4] = 0x10
        let described = try format(atoms: ["dvvC": Data(altered)], entry: entry)
        #expect(throws: EngineError.hdrConversionUnsupported) {
            try DolbyVisionConfiguration.isProfile84(described)
        }
    }
}
