import AVFoundation
import AudioToolbox
import CoreGraphics
import Engine
import Formats
import Foundation
import ImageIO
import MenuCatalog
import UniformTypeIdentifiers

/// SPEC section 16 targets.
enum Targets {
    static let menuSeconds = 0.030
    static let heicSeconds = 0.5
    static let videoSeconds = 30.0
    static let menuItems = 1_000
    static let transportPaths = 5_000
    static let photoWidth = 4_000
    static let photoHeight = 3_000
    static let clipWidth = 1_920
    static let clipHeight = 1_080
    static let clipSeconds = 60
    static let clipFrameRate: Int32 = 30
    static let clipBitrate = 15_000_000
    static let audioSampleRate = 48_000
    static let audioChannels = 2
    static let audioBitrate = 192_000
    static let audioToneHertz = 440.0
    static let audioToneAmplitude = 0.25
    static let durationTolerance = 0.05
    static let mp3Seconds = 10
    static let mp3SampleRate = 44_100
    static let mp3BitrateKilobits = 192
    static let mp3TargetFactor = 20.0
    static let mp3ReferenceChip = "Apple M1"
    static let mp3ChunkFrames = 1_152 * 8
    static let mp3DurationTolerance = 0.1
    static let mp3Chords = [
        [261.63, 329.63, 392.0],
        [220.0, 261.63, 329.63],
        [174.61, 220.0, 261.63],
        [196.0, 246.94, 293.66],
    ]
    static let mp3BeatSeconds = 0.5
    static let mp3BeatsPerChord = 4
    static let mp3DecayRate = 3.0
    static let mp3BassGain = 0.18
    static let mp3StrongNoteGain = 0.12
    static let mp3WeakNoteGain = 0.08
}

let labelWidth = 36

struct BenchError: Error, CustomStringConvertible {
    let description: String
}

func measure(_ label: String, target: Double, _ body: () async throws -> Void) async throws {
    let start = ContinuousClock.now
    try await body()
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    let verdict = seconds <= target ? "ok" : "SLOW"
    let column = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
    print(column + String(format: "%8.3f s   target %7.3f s   ", seconds, target) + verdict)
    fflush(stdout)
}

/// Keeps trashed originals off the user's Trash.
func withScratchVolume(_ body: (URL) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "MacEaseBench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let mount = base.appending(path: "mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let image = base.appending(path: "bench.sparseimage")
    try hdiutil(["create", "-size", "4g", "-fs", "APFS", "-type", "SPARSE", "-volname", "MacEaseBench", image.path])
    try hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
    defer { try? hdiutil(["detach", "-force", mount.path]) }
    try await body(mount)
}

func hdiutil(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BenchError(description: "hdiutil \(arguments[0]) failed") }
}

func run(_ op: OperationID, preset: String?, on url: URL) async throws {
    let settings = Settings()
    guard let options = OperationPlanner.options(for: op, preset: preset, settings: settings) else {
        throw BenchError(description: "\(op.rawValue) has no preset \(preset ?? "(none)")")
    }
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseBenchSupport-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let engine = try JobEngine(supportDirectory: support, concurrency: 1)
    let batch = OperationPlanner.batch(
        for: OperationRequest(op: op, options: options, inputs: [url]), settings: settings)
    let outcome = await engine.run(batch, settings: settings) { _ in }
    guard case .succeeded = outcome.outcomes.first else {
        throw BenchError(description: "\(op.rawValue) did not succeed: \(String(describing: outcome.outcomes.first))")
    }
}

func writePhoto(to url: URL) throws {
    guard
        let context = CGContext(
            data: nil, width: Targets.photoWidth, height: Targets.photoHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw BenchError(description: "no drawing context") }
    for band in 0..<Targets.photoHeight / 10 {
        let shade = CGFloat(band % 97) / 97
        context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: band * 10, width: Targets.photoWidth, height: 10))
    }
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
    else { throw BenchError(description: "HEIC encoding unavailable") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BenchError(description: "HEIC write failed") }
}

func writeClip(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Targets.clipWidth,
            AVVideoHeightKey: Targets.clipHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Targets.clipBitrate],
        ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: video,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Targets.clipWidth, kCVPixelBufferHeightKey as String: Targets.clipHeight,
        ])
    guard
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Targets.audioSampleRate),
            channels: AVAudioChannelCount(Targets.audioChannels), interleaved: true)
    else {
        throw BenchError(
            description: String(localized: "No PCM audio format is available.", comment: "Benchmark error"))
    }
    let audio = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Targets.audioSampleRate,
            AVNumberOfChannelsKey: Targets.audioChannels,
            AVEncoderBitRateKey: Targets.audioBitrate,
        ])
    guard writer.canAdd(video) else {
        throw BenchError(description: String(localized: "The clip writer rejected video.", comment: "Benchmark error"))
    }
    writer.add(video)
    guard writer.canAdd(audio) else {
        throw BenchError(description: String(localized: "The clip writer rejected audio.", comment: "Benchmark error"))
    }
    writer.add(audio)
    guard writer.startWriting() else { throw BenchError(description: "clip writer did not start") }
    writer.startSession(atSourceTime: .zero)
    let frames = Targets.clipSeconds * Int(Targets.clipFrameRate)
    let audioFramesPerVideoFrame = Targets.audioSampleRate / Int(Targets.clipFrameRate)
    for index in 0..<frames {
        while !video.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error
                    ?? BenchError(
                        description: String(localized: "The clip writer stopped.", comment: "Benchmark error"))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let pool = adaptor.pixelBufferPool else { throw BenchError(description: "no pixel pool") }
        var buffer: CVPixelBuffer?
        let bufferStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard bufferStatus == kCVReturnSuccess else {
            throw BenchError(
                description: String(
                    localized: "Pixel buffer allocation failed (\(bufferStatus)).",
                    comment: "Benchmark error with system status"))
        }
        guard let buffer else { throw BenchError(description: "no pixel buffer") }
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw BenchError(
                description: String(
                    localized: "Pixel buffer lock failed (\(lockStatus)).",
                    comment: "Benchmark error with system status"))
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw BenchError(
                description: String(localized: "The pixel buffer has no base address.", comment: "Benchmark error"))
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRow(buffer) * Targets.clipHeight
        var grain = UInt64(index + 1)
        for offset in 0..<count {
            grain = grain &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[offset] = UInt8(truncatingIfNeeded: (offset / 4) &+ index &+ Int(grain >> 61))
        }
        let unlockStatus = CVPixelBufferUnlockBaseAddress(buffer, [])
        guard unlockStatus == kCVReturnSuccess else {
            throw BenchError(
                description: String(
                    localized: "Pixel buffer unlock failed (\(unlockStatus)).",
                    comment: "Benchmark error with system status"))
        }
        guard
            adaptor.append(
                buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: Targets.clipFrameRate))
        else {
            throw writer.error
                ?? BenchError(description: String(localized: "Appending video failed.", comment: "Benchmark error"))
        }
        while !audio.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error
                    ?? BenchError(
                        description: String(localized: "The clip writer stopped.", comment: "Benchmark error"))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let firstAudioFrame = index * audioFramesPerVideoFrame
        var samples: [Float] = []
        samples.reserveCapacity(audioFramesPerVideoFrame * Targets.audioChannels)
        for offset in 0..<audioFramesPerVideoFrame {
            let phase =
                2 * Double.pi * Targets.audioToneHertz * Double(firstAudioFrame + offset)
                / Double(Targets.audioSampleRate)
            let sample = Float(sin(phase) * Targets.audioToneAmplitude)
            samples.append(sample)
            samples.append(sample)
        }
        let sample = try audioSampleBuffer(samples, format: format, position: firstAudioFrame)
        guard audio.append(sample) else {
            throw writer.error
                ?? BenchError(description: String(localized: "Appending audio failed.", comment: "Benchmark error"))
        }
    }
    video.markAsFinished()
    audio.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error
            ?? BenchError(description: String(localized: "The clip writer failed.", comment: "Benchmark error"))
    }
}

func audioSampleBuffer(_ samples: [Float], format: AVAudioFormat, position: Int) throws -> CMSampleBuffer {
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard status == noErr, let block else {
        throw BenchError(
            description: String(
                localized: "Audio block creation failed (\(status)).", comment: "Benchmark error with system status"))
    }
    status = samples.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadLengthParameterErr) }
        return CMBlockBufferReplaceDataBytes(
            with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
    }
    guard status == noErr else {
        throw BenchError(
            description: String(
                localized: "Copying audio samples failed (\(status)).", comment: "Benchmark error with system status"))
    }
    var sample: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format.formatDescription,
        sampleCount: samples.count / Targets.audioChannels,
        presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: CMTimeScale(Targets.audioSampleRate)),
        packetDescriptions: nil, sampleBufferOut: &sample)
    guard status == noErr, let sample else {
        throw BenchError(
            description: String(
                localized: "Audio sample creation failed (\(status)).", comment: "Benchmark error with system status"))
    }
    return sample
}

func verifyClip(at url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    guard video.count == 1, audio.count == 1 else {
        throw BenchError(
            description: String(
                localized: "The clip must contain one video and one audio track.", comment: "Benchmark input validation"
            ))
    }
    let videoDescriptions = try await video[0].load(.formatDescriptions)
    let audioDescriptions = try await audio[0].load(.formatDescriptions)
    guard
        videoDescriptions.count == 1,
        CMFormatDescriptionGetMediaSubType(videoDescriptions[0]) == kCMVideoCodecType_H264,
        audioDescriptions.count == 1,
        CMFormatDescriptionGetMediaSubType(audioDescriptions[0]) == kAudioFormatMPEG4AAC
    else {
        throw BenchError(
            description: String(
                localized: "The clip codecs must be H.264 and AAC.", comment: "Benchmark input validation"))
    }
    for track in [video[0], audio[0]] {
        let range = try await track.load(.timeRange)
        guard abs(CMTimeGetSeconds(range.duration) - Double(Targets.clipSeconds)) <= Targets.durationTolerance else {
            throw BenchError(
                description: String(
                    localized: "A clip track differs from \(Targets.clipSeconds) seconds.",
                    comment: "Benchmark input duration validation"))
        }
    }
}

func chipName() throws -> String {
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    command.arguments = ["SPHardwareDataType", "-json"]
    let output = Pipe()
    command.standardOutput = output
    try command.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    command.waitUntilExit()
    guard command.terminationStatus == 0,
        let hardware = try JSONSerialization.jsonObject(with: bytes) as? [String: [[String: Any]]],
        let chip = hardware["SPHardwareDataType"]?.first?["chip_type"] as? String
    else {
        throw BenchError(
            description: String(
                localized: "Could not identify the Apple Silicon chip.", comment: "Benchmark hardware detection error"))
    }
    return chip
}

func benchmarkMP3(chip: String, outputURL: URL) throws {
    #if DEBUG
        throw BenchError(
            description: String(
                localized: "The MP3 benchmark requires a Release build.", comment: "Benchmark configuration error"))
    #else
        let channels = Targets.audioChannels
        let rate = Targets.mp3SampleRate
        let frames = Targets.mp3Seconds * rate
        let beatFrames = Int(Targets.mp3BeatSeconds * Double(rate))
        var samples = [Float](repeating: 0, count: frames * channels)
        for index in 0..<frames {
            let chord = Targets.mp3Chords[(index / (beatFrames * Targets.mp3BeatsPerChord)) % Targets.mp3Chords.count]
            let beatTime = Double(index % beatFrames) / Double(rate)
            let envelope = exp(-beatTime * Targets.mp3DecayRate)
            let bass = sin(2 * Double.pi * chord[0] * beatTime / 2) * Targets.mp3BassGain
            let left =
                sin(2 * Double.pi * chord[0] * beatTime) * Targets.mp3StrongNoteGain
                + sin(2 * Double.pi * chord[1] * beatTime) * Targets.mp3WeakNoteGain
            let right =
                sin(2 * Double.pi * chord[1] * beatTime) * Targets.mp3WeakNoteGain
                + sin(2 * Double.pi * chord[2] * beatTime) * Targets.mp3StrongNoteGain
            samples[index * channels] = Float((left + bass) * envelope)
            samples[index * channels + 1] = Float((right + bass) * envelope)
        }
        let start = ContinuousClock.now
        let encoder = try MP3Encoder(
            options: MP3EncoderOptions(
                sampleRate: rate, channels: channels, mode: .constant(kilobits: Targets.mp3BitrateKilobits)))
        var encodedPackets: [Data] = []
        for offset in stride(from: 0, to: frames, by: Targets.mp3ChunkFrames) {
            let end = min(frames, offset + Targets.mp3ChunkFrames)
            encodedPackets.append(try encoder.encode(interleaved: Array(samples[offset * channels..<end * channels])))
        }
        encodedPackets.append(try encoder.finish().trailingBytes)
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        guard elapsed > 0 else {
            throw BenchError(
                description: String(localized: "MP3 elapsed time was zero.", comment: "Benchmark measurement error"))
        }
        let encoded = encodedPackets.reduce(into: Data()) { $0.append($1) }
        guard !encoded.isEmpty else {
            throw BenchError(
                description: String(
                    localized: "MP3 encoding produced no output.", comment: "Benchmark output validation"))
        }
        try encoded.write(to: outputURL)
        let mp3 = try AudioInput(url: outputURL)
        guard mp3.codec == .mp3, mp3.channels == channels, mp3.sampleRate == Double(rate) else {
            throw BenchError(
                description: String(
                    localized: "The MP3 output codec, channels, or sample rate differs.",
                    comment: "Benchmark output validation"))
        }
        let decoder = try mp3.open()
        var decodedFrames = 0
        while let decoded = try decoder.read() { decodedFrames += decoded.count / channels }
        let decodedSeconds = Double(decodedFrames) / Double(rate)
        guard abs(decodedSeconds - Double(Targets.mp3Seconds)) <= Targets.mp3DurationTolerance else {
            throw BenchError(
                description: String(
                    localized: "The MP3 decoded duration differs from \(Targets.mp3Seconds) seconds.",
                    comment: "Benchmark output duration validation"))
        }
        let factor = Double(Targets.mp3Seconds) / elapsed
        let verdict =
            chip == Targets.mp3ReferenceChip
            ? (factor >= Targets.mp3TargetFactor
                ? String(localized: "Target met", comment: "Benchmark result")
                : String(localized: "Below target", comment: "Benchmark result"))
            : String(localized: "M1 target not evaluated on this chip", comment: "Benchmark result on non-M1 hardware")
        let elapsedText = elapsed.formatted(.number.precision(.fractionLength(3)))
        let factorText = factor.formatted(.number.precision(.fractionLength(1)))
        print(
            String(
                localized:
                    "MP3 \(Targets.mp3Seconds) s, \(rate) Hz stereo, \(Targets.mp3BitrateKilobits) kbps: \(elapsedText) s, \(factorText)× real time. M1 target ≥\(Int(Targets.mp3TargetFactor))×. \(verdict)",
                comment: "MP3 benchmark measurement and M1 target"))
        fflush(stdout)
    #endif
}

func benchmark() async throws {
    let chip = try chipName()
    print(String(localized: "Benchmark hardware: \(chip)", comment: "Chip used for benchmark measurements"))
    try await withScratchVolume { volume in try await benchmark(chip: chip, volume: volume) }
}

func benchmark(chip: String, volume: URL) async throws {
    let titles = MenuTitles(operation: { $0.rawValue }, preset: { $1 }, kind: { $0.rawValue })
    let menu = MenuFile(
        token: String(repeating: "0", count: 64), hostAvailable: true, visibleOperations: OperationID.allCases,
        titles: titles)
    let selection = (0..<Targets.menuItems).map { volume.appending(path: "photo-\($0).heic") }
    try await measure("Menu for \(Targets.menuItems) items", target: Targets.menuSeconds) {
        _ = MenuLayout.nodes(for: menu, selection: selection)
    }

    let paths = (0..<Targets.transportPaths).map { "/Users/someone/Pictures/photo-\($0).heic" }
    let request = RunRequest(catalogVersion: menu.catalogVersion, entryIndex: 0, token: menu.token, paths: paths)
    try await measure("Parse \(Targets.transportPaths) paths", target: Targets.menuSeconds) {
        guard let url = request.url(scheme: "macease"), try RunRequest(url: url, scheme: "macease") == request else {
            throw BenchError(description: "transport round trip failed")
        }
    }

    let photo = volume.appending(path: "photo.heic")
    try writePhoto(to: photo)
    try await measure("12 MP HEIC to JPEG", target: Targets.heicSeconds) {
        try await run(.imageConvert, preset: "jpeg", on: photo)
    }
    try benchmarkMP3(chip: chip, outputURL: volume.appending(path: "benchmark.mp3"))

    let clip = volume.appending(path: "clip.mp4")
    try await writeClip(to: clip)
    try await verifyClip(at: clip)
    let clipBytes = try clip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    print("Clip to compress: \(clipBytes / 1_000_000) MB")
    try await measure("60 s 1080p to 20 MB (Discord)", target: Targets.videoSeconds) {
        try await run(.videoCompress, preset: "discord", on: clip)
    }
}

/// Run under `/usr/bin/time -l` for peak memory.
func benchmarkSingle(_ arguments: [String]) async throws {
    guard let op = OperationID(rawValue: arguments[0]) else {
        throw BenchError(description: "unknown operation \(arguments[0])")
    }
    let source = URL(fileURLWithPath: arguments[1])
    try await withScratchVolume { volume in
        let input = volume.appending(
            path: source.lastPathComponent, directoryHint: source.hasDirectoryPath ? .isDirectory : .notDirectory)
        try FileManager.default.copyItem(at: source, to: input)
        try await measure("\(op.rawValue) \(source.lastPathComponent)", target: .infinity) {
            try await run(op, preset: arguments.dropFirst(2).first, on: input)
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count >= 2 { try await benchmarkSingle(arguments) } else { try await benchmark() }
} catch {
    print("Benchmark stopped: \(error)")
    exit(1)
}
