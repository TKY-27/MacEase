import AudioToolbox
import Foundation
import Testing

@testable import Formats

@Suite struct MP3EncoderTests {
    private func encode(_ samples: [Float], options: MP3EncoderOptions) throws -> URL {
        let encoder = try MP3Encoder(options: options)
        var output = Data()
        let chunk = 4096 * options.channels
        for start in stride(from: 0, to: samples.count, by: chunk) {
            output.append(try encoder.encode(interleaved: Array(samples[start..<min(start + chunk, samples.count)])))
        }
        let finish = try encoder.finish()
        output.append(finish.trailingBytes)
        if let xing = finish.xingFrame { output.replaceSubrange(0..<xing.count, with: xing) }
        let url = FileManager.default.temporaryDirectory.appending(path: "mp3-\(UUID().uuidString).mp3")
        TestTemporaryFolders.register(url)
        try output.write(to: url)
        return url
    }

    private func packetCount(_ url: URL) throws -> Int {
        var file: AudioFileID?
        #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr)
        let opened = try #require(file)
        defer { AudioFileClose(opened) }
        var count: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        #expect(AudioFileGetProperty(opened, kAudioFilePropertyAudioDataPacketCount, &size, &count) == noErr)
        return Int(count)
    }

    /// Each frame header must follow the last.
    private func frameCount(_ url: URL, sampleRate: Int) throws -> Int {
        let bytes = [UInt8](try Data(contentsOf: url))
        var offset = 0
        var frames = 0
        while offset + 4 <= bytes.count {
            let synced = bytes[offset] == 0xFF && bytes[offset + 1] & 0xFE == 0xFA
            #expect(synced, "sync lost at \(offset)")
            guard synced else { return frames }
            let bitrate = MP3Constants.bitrates[Int(bytes[offset + 2] >> 4)]
            let padding = Int(bytes[offset + 2] >> 1 & 1)
            offset += 144 * bitrate * 1000 / sampleRate + padding
            frames += 1
        }
        #expect(offset == bytes.count)
        return frames
    }

    private func segmentSNRs(_ reference: [Float], _ decoded: [Float], lag: Int) -> [Double] {
        stride(from: 0, to: reference.count - 1024, by: 1024).compactMap { start in
            var signal = 0.0
            var noise = 0.0
            for index in start..<(start + 1024) where index + lag < decoded.count {
                signal += Double(reference[index] * reference[index])
                let error = Double(reference[index] - decoded[index + lag])
                noise += error * error
            }
            return signal > 1e-3 ? 10 * log10(signal / max(noise, 1e-20)) : nil
        }
    }

    @Test(arguments: [
        (44_100, 2, MP3EncoderOptions.Mode.constant(kilobits: 128)),
        (44_100, 2, .constant(kilobits: 256)),
        (48_000, 2, .constant(kilobits: 320)),
        (48_000, 1, .constant(kilobits: 192)),
        (44_100, 1, .constant(kilobits: 320)),
        (44_100, 1, .variable(quality: 9)),
        (48_000, 2, .variable(quality: 0)),
    ])
    func audioToolboxDecodesEveryFrame(sampleRate: Int, channels: Int, mode: MP3EncoderOptions.Mode) throws {
        let music = AudioFixtures.music(seconds: 3, sampleRate: sampleRate)
        let samples = channels == 1 ? music.left : zip(music.left, music.right).flatMap { [$0, $1] }
        let url = try encode(
            samples, options: MP3EncoderOptions(sampleRate: sampleRate, channels: channels, mode: mode))
        let decoded = try AudioFixtures.decode(url)
        #expect(decoded.sampleRate == Double(sampleRate))
        let frames = try frameCount(url, sampleRate: sampleRate)
        let xingFrames = if case .variable = mode { 1 } else { 0 }
        #expect(try packetCount(url) == frames - xingFrames)
        let lag = AudioFixtures.delay(of: decoded.left, behind: music.left, maximum: 3000)
        let worst = segmentSNRs(music.left, decoded.left, lag: lag).min() ?? 0
        #expect(worst > 3, "a segment decoded as noise: \(worst) dB")
    }

    @Test func musicAt192KilobitsMeetsQualityAndBandwidth() throws {
        let music = AudioFixtures.music(seconds: 8)
        let url = try encode(
            zip(music.left, music.right).flatMap { [$0, $1] },
            options: MP3EncoderOptions(sampleRate: 44_100, channels: 2, mode: .constant(kilobits: 192))
        )
        let decoded = try AudioFixtures.decode(url)
        let lag = AudioFixtures.delay(of: decoded.left, behind: music.left, maximum: 3000)
        let snr = AudioFixtures.segmentalSNR(music.left, decoded.left, lag: lag)
        #expect(snr >= 20, "segmental SNR \(snr) dB")
        let aligned = Array(decoded.left.dropFirst(lag))
        let original = AudioFixtures.bandEnergy(music.left, sampleRate: 44_100, from: 16_000, to: 16_500)
        let coded = AudioFixtures.bandEnergy(aligned, sampleRate: 44_100, from: 16_000, to: 16_500)
        let retained = 10 * log10(coded / original)
        #expect(retained > -6, "16–16.5 kHz retained \(retained) dB")
    }

    @Test(arguments: [10 * 576 + 300, 11 * 576 + 300, 7 * 1152])
    func tailIsNotTruncated(length: Int) throws {
        var samples = [Float](repeating: 0, count: length)
        for index in (length - 200)..<length { samples[index] = Float(sin(Double(index) * 0.3) * 0.5) }
        let url = try encode(
            samples, options: MP3EncoderOptions(sampleRate: 44_100, channels: 1, mode: .constant(kilobits: 192))
        )
        let decoded = try AudioFixtures.decode(url).left
        let tail = decoded.suffix(from: max(0, length - 400)).reduce(0) { $0 + $1 * $1 }
        #expect(tail > 5, "tail energy \(tail)")
    }

    @Test func variableBitrateFallsWithQuality() throws {
        let music = AudioFixtures.music(seconds: 4)
        let samples = zip(music.left, music.right).flatMap { [$0, $1] }
        let sizes = try [0, 4, 9].map { quality in
            let options = MP3EncoderOptions(sampleRate: 44_100, channels: 2, mode: .variable(quality: quality))
            return try encode(samples, options: options).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        #expect(sizes[0] > sizes[1] && sizes[1] > sizes[2], "\(sizes)")
    }

    @Test func rejectsUnsupportedSettingsAndMisuse() throws {
        #expect(throws: FormatError.self) {
            try MP3Encoder(options: MP3EncoderOptions(sampleRate: 22_050, channels: 2, mode: .constant(kilobits: 128)))
        }
        #expect(throws: FormatError.self) {
            try MP3Encoder(options: MP3EncoderOptions(sampleRate: 44_100, channels: 2, mode: .constant(kilobits: 160)))
        }
        let encoder = try MP3Encoder(
            options: MP3EncoderOptions(sampleRate: 44_100, channels: 2, mode: .constant(kilobits: 128))
        )
        #expect(throws: FormatError.self) { try encoder.encode(interleaved: [0, 0, 0]) }
        _ = try encoder.finish()
        #expect(throws: FormatError.self) { try encoder.finish() }
        #expect(throws: FormatError.self) { try encoder.encode(interleaved: [0, 0]) }
    }

    @Test func survivesNonFiniteAndShortInput() throws {
        let hostile: [Float] = [.nan, .infinity, -.infinity, 8, -8] + [Float](repeating: 0.1, count: 95)
        let url = try encode(
            hostile, options: MP3EncoderOptions(sampleRate: 44_100, channels: 1, mode: .constant(kilobits: 128))
        )
        #expect(try AudioFixtures.decode(url).left.allSatisfy(\.isFinite))
    }

    @Test func silenceEncodesToValidFrames() throws {
        let url = try encode(
            [Float](repeating: 0, count: 44_100),
            options: MP3EncoderOptions(sampleRate: 44_100, channels: 1, mode: .constant(kilobits: 128))
        )
        let decoded = try AudioFixtures.decode(url)
        #expect(decoded.left.allSatisfy { abs($0) < 1e-4 })
    }
}
