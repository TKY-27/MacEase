import Foundation
import Testing

@testable import Engine

@Suite struct StagedMediaFallbackCrashTests {
    @Test func unsupportedAudioCodecInMOVThrowsTypedErrorInsteadOfCrashing() async throws {
        let tools = try mediaFixtureTools()
        let folder = try TestVolume.makeFolder()
        let intermediate = folder.appending(path: "source.mkv")
        let movie = folder.appending(path: "h264_vorbis.mov")
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-v", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=128x128:rate=24:duration=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                "-c:v", "mpeg4", "-c:a", "vorbis", "-ac", "2", "-strict", "-2",
                intermediate.path,
            ],
            directory: folder, tools: tools)
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-v", "error", "-nostdin", "-y", "-i", intermediate.path,
                "-c:v", "h264_videotoolbox", "-b:v", "400k", "-c:a", "copy", "-strict", "-2",
                movie.path,
            ],
            directory: folder, tools: tools)
        var thrown: EngineError?
        do {
            let input = try AudioInput(url: movie)
            let reader = try input.open()
            _ = try reader.read()
        } catch let error as EngineError {
            thrown = error
        }
        let error = try #require(thrown)
        switch error {
        case .decodeFailed, .unsupportedCodec:
            break
        default:
            Issue.record("expected decodeFailed or unsupportedCodec, got \(error)")
        }
    }
}
