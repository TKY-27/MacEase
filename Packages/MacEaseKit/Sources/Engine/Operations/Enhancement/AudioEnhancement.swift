import AVFoundation
import Foundation
import MenuCatalog

public enum AudioEnhancementMode: String, CaseIterable, Codable, Sendable {
    case speech
    case stems

    public var maximumDuration: Double { self == .speech ? 600 : 300 }
    public var sampleRate: Double { self == .speech ? 16_000 : 44_100 }
    public var channels: Int { self == .speech ? 1 : 2 }
}

public struct AudioEnhancement: Sendable {
    private static let segmentSeconds = 10.0
    private static let contextSeconds = 1.0
    private static let paddingFrames: Int64 = 2_048
    private static let bufferFrames: AVAudioFrameCount = 8_192
    private let directory: URL
    private let tools: MediaDownloadTools

    public init(directory: URL? = nil, tools: MediaDownloadTools? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            guard let resources = Bundle.main.resourceURL else {
                throw EngineError.unsupportedCodec("Audio AI runtime is unavailable")
            }
            self.directory = resources.appending(path: "ai-audio")
        }
        self.tools = try tools ?? .bundled()
    }

    public func makeBatch(source: URL, mode: AudioEnhancementMode) throws -> Batch {
        try requireRuntime(mode)
        return Batch(
            operation: .audioEnhance,
            items: [
                OperationPlanner.validated(source, kind: .audio) { context in
                    try await enhance(source, mode: mode, context: context)
                }
            ])
    }

    private func requireRuntime(_ mode: AudioEnhancementMode) throws {
        let executable = mode == .speech ? "sherpa-onnx-offline-denoiser" : "sherpa-onnx-offline-source-separation"
        guard FileManager.default.isExecutableFile(atPath: directory.appending(path: "bin/" + executable).path) else {
            throw EngineError.unsupportedCodec("Install the bundled audio AI runtime")
        }
        let models = mode == .speech ? ["gtcrn.onnx"] : ["vocals.onnx", "accompaniment.onnx", "spleeter-verified.json"]
        for model in models {
            guard FileManager.default.isReadableFile(atPath: directory.appending(path: "models/" + model).path) else {
                throw EngineError.unsupportedCodec("The requested audio AI model is unavailable")
            }
        }
    }

    private func enhance(_ source: URL, mode: AudioEnhancementMode, context: ItemContext) async throws -> ItemResult {
        try Task.checkCancellation()
        let input = try AudioInput(url: source)
        guard let duration = input.duration, duration.isFinite, duration > 0 else {
            throw EngineError.decodeFailed("Audio duration is unavailable")
        }
        guard duration <= mode.maximumDuration else {
            throw EngineError.invalidInput(.tooLong(limitSeconds: mode.maximumDuration))
        }
        guard (1...2).contains(input.channels) else { throw EngineError.audioChannelLayoutUnsupported }
        let staging = try context.stagingDirectory(for: source)
        let labels = mode == .speech ? ["cleaned-speech"] : ["vocals", "instrumental"]
        let outputs = labels.map { staging.appending(path: $0 + ".wav") }
        let writers = try outputs.map { url in
            try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: mode.sampleRate,
                    AVNumberOfChannelsKey: mode.channels, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let totalFrames = Int64((duration * mode.sampleRate).rounded())
        let segmentFrames = Int64(Self.segmentSeconds * mode.sampleRate)
        let contextFrames = Int64(Self.contextSeconds * mode.sampleRate)
        for first in stride(from: Int64(0), to: totalFrames, by: Int(segmentFrames)) {
            try Task.checkCancellation()
            let start = max(0, first - contextFrames)
            let end = min(totalFrames, first + segmentFrames + contextFrames)
            let chunk = staging.appending(path: "input.wav")
            context.phase(.decoding)
            _ = try await MediaToolProcess().run(
                executable: tools.ffmpeg,
                arguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y", "-protocol_whitelist", "file,pipe",
                    "-ss", String(Double(start) / mode.sampleRate), "-i", source.path,
                    "-t", String(Double(end - start + Self.paddingFrames) / mode.sampleRate), "-map", "0:a:0",
                    "-vn", "-sn", "-dn", "-ac", String(mode.channels), "-ar", String(Int(mode.sampleRate)),
                    "-af",
                    "aresample=\(Int(mode.sampleRate)),atrim=end_sample=\(end - start),apad=pad_len=\(Self.paddingFrames)",
                    "-c:a", "pcm_s16le", chunk.path,
                ], directory: staging, tools: tools, captureOutput: false)
            context.phase(.optimizing)
            let enhanced = try await infer(chunk, mode: mode, staging: staging)
            let count = min(segmentFrames, totalFrames - first)
            for (index, url) in enhanced.enumerated() {
                try Self.append(url, to: writers[index], offset: first - start, frames: count)
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.removeItem(at: chunk)
            context.progress(Double(first + count) / Double(totalFrames))
        }
        try Task.checkCancellation()
        let base = source.deletingPathExtension().lastPathComponent
        return .derived(
            nextTo: source,
            outputs: zip(outputs, labels).map { url, label in
                StagedFile(url: url, name: base + "-" + label + ".wav", check: .audio)
            })
    }

    private func infer(_ input: URL, mode: AudioEnhancementMode, staging: URL) async throws -> [URL] {
        let outputs = (mode == .speech ? ["speech"] : ["voice", "music"]).map {
            staging.appending(path: "inferred-" + $0 + ".wav")
        }
        let models = directory.appending(path: "models")
        let executable: String
        var arguments: [String]
        if mode == .speech {
            executable = "sherpa-onnx-offline-denoiser"
            arguments = [
                "--speech-denoiser-gtcrn-model=" + models.appending(path: "gtcrn.onnx").path,
                "--output-wav=" + outputs[0].path,
            ]
        } else {
            executable = "sherpa-onnx-offline-source-separation"
            arguments = [
                "--spleeter-vocals=" + models.appending(path: "vocals.onnx").path,
                "--spleeter-accompaniment=" + models.appending(path: "accompaniment.onnx").path,
                "--output-vocals-wav=" + outputs[0].path,
                "--output-accompaniment-wav=" + outputs[1].path,
            ]
        }
        arguments += ["--num-threads=1", "--input-wav=" + input.path]
        _ = try await MediaToolProcess().run(
            executable: directory.appending(path: "bin/" + executable), arguments: arguments,
            directory: staging, tools: tools, captureOutput: false)
        return outputs
    }

    private static func append(_ url: URL, to writer: AVAudioFile, offset: Int64, frames: Int64) throws {
        let reader = try AVAudioFile(forReading: url)
        guard reader.processingFormat.sampleRate == writer.processingFormat.sampleRate,
            reader.processingFormat.channelCount == writer.processingFormat.channelCount,
            reader.length >= offset + frames,
            let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: bufferFrames)
        else { throw EngineError.decodeFailed("Audio AI output has invalid timing or channels") }
        reader.framePosition = offset
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(bufferFrames), remaining)))
            guard buffer.frameLength > 0 else { throw EngineError.decodeFailed("Audio AI output is truncated") }
            try writer.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }
}
