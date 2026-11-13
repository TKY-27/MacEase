import Foundation
import Testing

@testable import Formats

@Suite struct AVIFLVAudioConfigTests {
    @Test(arguments: [0, 768_001])
    func rejectsInvalidExplicitAACCoreRate(rate: Int) throws {
        let config = explicitConfig(coreRate: rate)
        if rate == 0 { #expect(config == [0x17, 0x80, 0x00, 0x00, 0x10]) }
        #expect(throws: FormatError.corrupt("Audio sample rate out of range")) {
            try FLV.audioSpecificConfig(config)
        }
        let url = ContainerFixtures.temporaryURL("invalid-aac.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2), codec: .aac, codecPrivate: Data(config))
        #expect(throws: FormatError.corrupt("Audio sample rate out of range")) {
            try MatroskaMuxer(url: url, tracks: [track], webm: false)
        }
    }

    @Test(arguments: [0, 768_001], [false, true])
    func rejectsInvalidExplicitSBRRate(rate: Int, explicitSBR: Bool) throws {
        let config = explicitConfig(coreRate: 24_000, sbrRate: rate, explicitSBR: explicitSBR)
        #expect(throws: FormatError.corrupt("Audio sample rate out of range")) {
            try FLV.audioSpecificConfig(config)
        }
    }

    @Test(arguments: [1, 48_000, 768_000])
    func acceptsValidExplicitAACRates(rate: Int) throws {
        let parsed = try FLV.audioSpecificConfig(explicitConfig(coreRate: rate, sbrRate: rate))
        #expect(parsed.sampleRate == Double(rate))
        #expect(parsed.sbrSampleRate == Double(rate))
    }

    private func explicitConfig(coreRate: Int, sbrRate: Int? = nil, explicitSBR: Bool = false) -> [UInt8] {
        var bits: [UInt8] = []
        func append(_ value: Int, width: Int) {
            bits += (0..<width).reversed().map { UInt8(value >> $0 & 1) }
        }
        append(explicitSBR ? 5 : 2, width: 5)
        append(15, width: 4)
        append(coreRate, width: 24)
        append(2, width: 4)
        if !explicitSBR { append(0, width: 3) }
        if let sbrRate {
            if !explicitSBR {
                append(0x2B7, width: 11)
                append(5, width: 5)
                append(1, width: 1)
            }
            append(15, width: 4)
            append(sbrRate, width: 24)
            if explicitSBR { append(2, width: 5) }
        }
        while !bits.count.isMultiple(of: 8) { bits.append(0) }
        return stride(from: 0, to: bits.count, by: 8).map { offset in
            bits[offset..<(offset + 8)].reduce(0) { $0 << 1 | $1 }
        }
    }
}
