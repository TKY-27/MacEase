import AudioToolbox
import Engine
import Foundation
import Testing

@testable import Formats

@Suite struct MP3OutputTests {
    private func encode(
        _ samples: [Float], sampleRate: Int = 44_100, channels: Int = 2, kilobits: Int = 192, quality: Int? = nil
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mp3-\(UUID().uuidString).mp3")
        TestTemporaryFolders.register(url)
        let encoder = try AudioFileEncoder(
            url: url, target: AudioTarget(format: .mp3, kilobits: kilobits, variableQuality: quality),
            sampleRate: Double(sampleRate), channels: channels)
        let chunk = 4096 * channels
        for start in stride(from: 0, to: samples.count, by: chunk) {
            try await encoder.write(Array(samples[start..<min(start + chunk, samples.count)]))
        }
        try await encoder.finish()
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
        let encoded = try Data(contentsOf: url)
        let header = ID3Tag.length(prefix: Array(encoded.prefix(ID3Tag.headerLength))) ?? 0
        let bytes = [UInt8](encoded.dropFirst(header))
        var offset = 0
        var frames = 0
        while offset + 4 <= bytes.count {
            let synced = bytes[offset] == 0xFF && bytes[offset + 1] & 0xFE == 0xFA
            #expect(synced, "sync lost at \(offset)")
            guard synced else { return frames }
            let bitrate = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][
                Int(bytes[offset + 2] >> 4)]
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
        (44_100, 2, 128, nil as Int?), (44_100, 2, 256, nil), (48_000, 2, 320, nil),
        (48_000, 1, 192, nil), (44_100, 1, 320, nil), (44_100, 1, 128, 9), (48_000, 2, 128, 0),
    ])
    func audioToolboxDecodesEveryFrame(sampleRate: Int, channels: Int, kilobits: Int, quality: Int?) async throws {
        let music = AudioFixtures.music(seconds: 3, sampleRate: sampleRate)
        let samples = channels == 1 ? music.left : zip(music.left, music.right).flatMap { [$0, $1] }
        let url = try await encode(
            samples, sampleRate: sampleRate, channels: channels, kilobits: kilobits, quality: quality)
        let decoded = try AudioFixtures.decode(url)
        #expect(decoded.sampleRate == Double(sampleRate))
        #expect(decoded.left.count == music.left.count)
        #expect(decoded.right.count == music.right.count)
        let frames = try frameCount(url, sampleRate: sampleRate)
        #expect(try packetCount(url) == frames - 1)
        for (reference, channel) in [
            (music.left, decoded.left), (channels == 1 ? music.left : music.right, decoded.right),
        ] {
            let lag = AudioFixtures.delay(of: channel, behind: reference, maximum: 3000)
            let worst = segmentSNRs(reference, channel, lag: lag).min() ?? 0
            #expect(worst > 3, "a segment decoded as noise: \(worst) dB")
        }
    }

    @Test func musicAt192KilobitsMeetsQualityAndBandwidth() async throws {
        let music = AudioFixtures.music(seconds: 8)
        let url = try await encode(zip(music.left, music.right).flatMap { [$0, $1] })
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
    func tailIsNotTruncated(length: Int) async throws {
        var samples = [Float](repeating: 0, count: length)
        for index in (length - 200)..<length { samples[index] = Float(sin(Double(index) * 0.3) * 0.5) }
        let url = try await encode(samples, channels: 1)
        let decoded = try AudioFixtures.decode(url).left
        let tail = decoded.suffix(from: max(0, length - 400)).reduce(0) { $0 + $1 * $1 }
        #expect(tail > 5, "tail energy \(tail)")
    }

    @Test func variableBitrateFallsWithQuality() async throws {
        let music = AudioFixtures.music(seconds: 4)
        let samples = zip(music.left, music.right).flatMap { [$0, $1] }
        var sizes: [Int] = []
        for quality in [0, 4, 9] {
            let url = try await encode(samples, quality: quality)
            sizes.append(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(sizes[0] > sizes[1] && sizes[1] > sizes[2], "\(sizes)")
    }

    @Test func rejectsUnsupportedSettingsAndMisuse() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "invalid-mp3-\(UUID().uuidString).mp3")
        TestTemporaryFolders.register(url)
        #expect(throws: (any Error).self) {
            try AudioFileEncoder(url: url, target: AudioTarget(format: .mp3, kilobits: 128), sampleRate: 0, channels: 2)
        }
        #expect(throws: (any Error).self) {
            try AudioFileEncoder(
                url: url, target: AudioTarget(format: .mp3, kilobits: 128), sampleRate: 44_100, channels: 3)
        }
        let encoder = try AudioFileEncoder(
            url: url, target: AudioTarget(format: .mp3, kilobits: 128), sampleRate: 44_100, channels: 2)
        await #expect(throws: (any Error).self) { try await encoder.write([0, 0, 0]) }
        try await encoder.write([Float](repeating: 0, count: 4096))
        try await encoder.finish()
        await #expect(throws: (any Error).self) { try await encoder.finish() }
        await #expect(throws: (any Error).self) { try await encoder.write([0, 0]) }
    }

    @Test func rejectsNonFiniteSamples() async throws {
        for invalid in [Float.nan, .infinity, -.infinity] {
            await #expect(throws: (any Error).self) { try await encode([invalid, 0], channels: 1) }
        }
    }

    @Test func silenceEncodesToValidFrames() async throws {
        let url = try await encode([Float](repeating: 0, count: 44_100), channels: 1, kilobits: 128)
        let decoded = try AudioFixtures.decode(url)
        #expect(decoded.left.allSatisfy { abs($0) < 1e-4 })
    }

    @Test(arguments: [100, 1_153, 6_060, 44_117], [nil as Int?, 4])
    func gaplessDurationMatchesInput(length: Int, quality: Int?) async throws {
        let samples = (0..<length).map { Float(sin(Double($0) * 0.071) * 0.4) }
        let url = try await encode(samples, channels: 1, quality: quality)
        let decoded = try AudioFixtures.decode(url)
        #expect(decoded.left.count == length)
        #expect(decoded.right.count == length)
        let directory = try #require(ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"])
        let tools = try MediaDownloadTools(directory: URL(filePath: directory))
        let decoding = Process()
        decoding.executableURL = tools.ffmpeg
        decoding.arguments = ["-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "f32le", "pipe:1"]
        let output = Pipe()
        decoding.standardOutput = output
        try decoding.run()
        var decodedBytes = 0
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            decodedBytes += chunk.count
        }
        try output.fileHandleForReading.close()
        decoding.waitUntilExit()
        #expect(decoding.terminationReason == .exit)
        #expect(decoding.terminationStatus == 0)
        #expect(decodedBytes == length * MemoryLayout<Float>.size)
    }

    @Test func clippedStereoMusicKeepsBothMelodies() async throws {
        let music = AudioFixtures.music(seconds: 4)
        let left = music.left.map { min(1, max(-1, $0 * 6)) }
        let right = music.right.map { min(1, max(-1, -$0 * 6)) }
        let url = try await encode(zip(left, right).flatMap { [$0, $1] })
        let decoded = try AudioFixtures.decode(url)
        for (reference, channel) in [(left, decoded.left), (right, decoded.right)] {
            let lag = AudioFixtures.delay(of: channel, behind: reference, maximum: 3000)
            #expect(AudioFixtures.segmentalSNR(reference, channel, lag: lag) >= 20)
        }
    }

    @Test func cancellationStopsStreamingMP3() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cancel-mp3-\(UUID().uuidString).mp3")
        TestTemporaryFolders.register(url)
        let encoding = Task {
            let encoder = try AudioFileEncoder(
                url: url, target: AudioTarget(format: .mp3, kilobits: 192), sampleRate: 44_100, channels: 2)
            let chunk = [Float](repeating: 0.2, count: 8_192)
            for _ in 0..<100_000 { try await encoder.write(chunk) }
            try await encoder.finish()
        }
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        encoding.cancel()
        await #expect(throws: CancellationError.self) { try await encoding.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func encoderFailureDoesNotOverwriteExistingOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "occupied-mp3-\(UUID().uuidString).mp3")
        TestTemporaryFolders.register(url)
        let original = Data("existing output".utf8)
        try original.write(to: url)
        await #expect(throws: EngineError.self) {
            let encoder = try AudioFileEncoder(
                url: url, target: AudioTarget(format: .mp3, kilobits: 192), sampleRate: 44_100, channels: 2)
            try await encoder.write([Float](repeating: 0, count: 8_192))
            try await encoder.finish()
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
