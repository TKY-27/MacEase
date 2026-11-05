import Darwin
import Formats
import Foundation

final class LameAudioSink: AudioSink {
    private static let encoderVersion = "LAME3.100"
    private let input: FileHandle
    private let encoding: Task<MediaToolResult, Error>
    private let artworkURL: URL?
    private let outputURL: URL
    private let channels: Int
    private var inputFrames: Int64 = 0
    private var finished = false

    init(url: URL, sampleRate: Int, channels: Int, kilobits: Int, quality: Int?, tags: AudioTags) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.encodeFailed("MP3 output already exists")
        }
        guard quality.map({ (0...9).contains($0) }) ?? true else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        self.channels = channels
        outputURL = url
        let tools: MediaDownloadTools
        if let directory = ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"],
            Bundle.main.bundleIdentifier?.hasPrefix("io.github.tky27.MacEase") != true
        {
            tools = try MediaDownloadTools(directory: URL(filePath: directory))
        } else {
            tools = try MediaDownloadTools.bundled()
        }
        var arguments = [
            "-hide_banner", "-nostdin", "-v", "error", "-n", "-protocol_whitelist", "file,pipe",
            "-f", "f32le", "-ar", String(sampleRate), "-ac", String(channels), "-i", "pipe:0",
        ]
        if let artwork = tags.artwork {
            let cover = url.deletingLastPathComponent().appending(path: ".cover-\(UUID().uuidString)")
            try artwork.data.write(to: cover, options: .withoutOverwriting)
            artworkURL = cover
            arguments += ["-protocol_whitelist", "file,pipe", "-i", cover.path]
        } else {
            artworkURL = nil
        }
        arguments += ["-map", "0:a:0", "-c:a", "libmp3lame"]
        if let quality {
            arguments += ["-q:a", String(quality)]
        } else {
            arguments += ["-b:a", "\(kilobits)k"]
        }
        if artworkURL != nil {
            arguments += ["-map", "1:v:0", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        arguments += ["-map_metadata", "-1", "-id3v2_version", "3", "-write_xing", "1"]
        // Apple recognizes LAME gapless headers.
        arguments += ["-metadata:s:a", "encoder=\(Self.encoderVersion)"]
        for (name, value) in [("title", tags.title), ("artist", tags.artist), ("album", tags.album)] {
            if let value { arguments += ["-metadata", "\(name)=\(value)"] }
        }
        arguments += ["-f", "mp3", url.path]
        let pipe = Pipe()
        input = pipe.fileHandleForWriting
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            if let artworkURL { try FileManager.default.removeItem(at: artworkURL) }
            throw EngineError.encodeFailed("MP3 input pipe could not be configured")
        }
        let runner = MediaToolProcess()
        let command = arguments
        encoding = Task.detached(priority: .utility) {
            try await runner.run(
                executable: tools.ffmpeg, arguments: command, directory: url.deletingLastPathComponent(),
                tools: tools, captureOutput: false, input: pipe.fileHandleForReading)
        }
    }

    deinit {
        encoding.cancel()
        try? input.close()
        if let artworkURL { try? FileManager.default.removeItem(at: artworkURL) }
    }

    func write(_ interleaved: [Float]) async throws {
        guard !finished else { throw EngineError.encodeFailed("MP3 encoder already finished") }
        guard interleaved.count.isMultiple(of: channels) else {
            throw EngineError.encodeFailed("interleaved samples must cover every channel")
        }
        guard interleaved.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
        let (followingFrames, overflow) = inputFrames.addingReportingOverflow(Int64(interleaved.count / channels))
        guard !overflow else { throw EngineError.encodeFailed("MP3 frame count out of range") }
        try Task.checkCancellation()
        let bytes = interleaved.withUnsafeBytes { Data($0) }
        let input = input
        let encoding = encoding
        try await withTaskCancellationHandler {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result { try input.write(contentsOf: bytes) })
                    }
                }
                inputFrames = followingFrames
            } catch {
                if Task.isCancelled { throw CancellationError() }
                try input.close()
                _ = try await encoding.value
                throw EngineError.encodeFailed("MP3 encoder stopped accepting audio")
            }
        } onCancel: {
            encoding.cancel()
        }
    }

    func finish() async throws {
        guard !finished else { throw EngineError.encodeFailed("MP3 encoder already finished") }
        finished = true
        try input.close()
        let encoding = encoding
        _ = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: {
            encoding.cancel()
        }
        try Task.checkCancellation()
        try MP3GaplessHeader.preserveFrameCount(inputFrames, in: outputURL)
        if let artworkURL { try FileManager.default.removeItem(at: artworkURL) }
    }
}

private enum MP3GaplessHeader {
    private static let headerBytes = 192
    private static let samplesPerFrame: Int64 = 1_152
    private static let xingFlagsOffset = 4
    private static let frameCountOffset = 8
    private static let encoderNameOffset = 120
    private static let delayOffset = 141
    private static let checksumOffset = 154
    private static let maximumPadding: Int64 = 4_095
    private static let crcPolynomial: UInt16 = 0xA001

    static func preserveFrameCount(_ inputFrames: Int64, in url: URL) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: ID3Tag.headerLength) ?? Data()
        let audioStart = ID3Tag.length(prefix: Array(prefix)) ?? 0
        try file.seek(toOffset: UInt64(audioStart))
        var frame = [UInt8](try file.read(upToCount: headerBytes) ?? Data())
        guard frame.count == headerBytes, frame[0] == 0xFF, frame[1] == 0xFB else {
            throw EngineError.encodeFailed("MP3 gapless header is unavailable")
        }
        let xing = frame[3] >> 6 == 3 ? 21 : 36
        let marker = String(decoding: frame[xing..<xing + 4], as: UTF8.self)
        guard marker == "Xing" || marker == "Info",
            integer(frame, at: xing + xingFlagsOffset) == 15,
            String(decoding: frame[xing + encoderNameOffset..<xing + encoderNameOffset + 4], as: UTF8.self) == "LAME"
        else { throw EngineError.encodeFailed("MP3 gapless header is unavailable") }
        let delayStart = xing + delayOffset
        let delay = Int64(frame[delayStart]) << 4 | Int64(frame[delayStart + 1] >> 4)
        let encodedFrames = Int64(integer(frame, at: xing + frameCountOffset)) * samplesPerFrame
        guard inputFrames > 0, encodedFrames >= delay, inputFrames <= encodedFrames - delay else {
            throw EngineError.encodeFailed("MP3 gapless frame count is inconsistent")
        }
        let padding = encodedFrames - delay - inputFrames
        guard (0...maximumPadding).contains(padding) else {
            throw EngineError.encodeFailed("MP3 gapless frame count is inconsistent")
        }
        // FFmpeg can omit multi-packet padding.
        frame[delayStart + 1] = frame[delayStart + 1] & 0xF0 | UInt8(padding >> 8)
        frame[delayStart + 2] = UInt8(padding & 0xFF)
        let checksumStart = xing + checksumOffset
        var checksum: UInt16 = 0
        for byte in frame[..<checksumStart] {
            checksum ^= UInt16(byte)
            for _ in 0..<8 {
                checksum = checksum & 1 == 0 ? checksum >> 1 : (checksum >> 1) ^ crcPolynomial
            }
        }
        frame[checksumStart] = UInt8(checksum >> 8)
        frame[checksumStart + 1] = UInt8(checksum & 0xFF)
        try file.seek(toOffset: UInt64(audioStart))
        try file.write(contentsOf: Data(frame))
        try file.close()
    }

    private static func integer(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
