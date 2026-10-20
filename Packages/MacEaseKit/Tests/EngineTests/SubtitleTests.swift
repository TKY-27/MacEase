import Foundation
import Speech
import Testing

@testable import Engine

@Suite struct SubtitleTests {
    private func words(_ text: String, every seconds: Double = 0.3) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: word + " ", start: Double(index) * seconds, end: Double(index + 1) * seconds)
        }
    }

    @Test func cuesBreakAtSentencesAndWrapToTwoLines() {
        let cues = Subtitles.cues(from: words("Short one. " + String(repeating: "longer words keep coming ", count: 6)))
        #expect(cues.first?.lines == ["Short one."])
        #expect(cues.dropFirst().allSatisfy { $0.lines.count <= Subtitles.maximumLines })
        #expect(cues.flatMap(\.lines).allSatisfy { $0.count <= Subtitles.maximumLineLength })
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
    }

    @Test func pausesEndCues() {
        var spoken = words("hello there")
        spoken.append(TimedWord(text: "again ", start: 5, end: 5.4))
        #expect(Subtitles.cues(from: spoken).map(\.lines) == [["hello there"], ["again"]])
    }

    @Test func japaneseWrapsByCharacter() {
        let text = String(repeating: "字幕のテストです", count: 12)
        let cues = Subtitles.cues(from: Subtitles.spread(text, from: 0, to: 10))
        #expect(cues.flatMap(\.lines).allSatisfy { $0.count <= Subtitles.maximumLineLength })
        #expect(cues.flatMap(\.lines).joined() == text)
    }

    @Test func spreadTimingEndsWithTheCue() {
        let words = Subtitles.spread("Hi all", from: 0, to: 6)
        #expect(words.first?.start == 0)
        #expect(words.last?.end == 6)
    }

    @Test func writesSRTAndVTT() {
        let cues = [SubtitleCue(start: 3661.5, end: 3662.25, lines: ["a", "b"])]
        #expect(Subtitles.srt(cues) == "1\n01:01:01,500 --> 01:01:02,250\na\nb\n")
        #expect(Subtitles.vtt(cues) == "WEBVTT\n\n01:01:01.500 --> 01:01:02.250\na\nb\n")
    }

    @Test(
        .requires(.speechAssets) {
            SpeechTranscriber.isAvailable
        })
    func transcribesSpeech() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "The weather is nice today. Let us go outside."]
        try say.run()
        say.waitUntilExit()
        let spoken = try await Subtitles.transcribe(audioFile: url, locale: Locale(identifier: "en-US"))
        let text = spoken.map(\.text).joined().lowercased()
        #expect(text.contains("weather"))
        #expect(spoken.map(\.start) == spoken.map(\.start).sorted())
    }
}
