import AVFoundation
import CoreMedia
import Foundation
import Speech
import Translation

public struct SubtitleCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    /// At most two lines.
    public var lines: [String]
}

struct TimedWord: Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum Subtitles {
    static let maximumLineLength = 42
    static let maximumLines = 2
    /// Silence long enough to end a cue.
    private static let pauseSeconds = 1.0
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "。", "！", "？"]

    static func transcribe(audioFile url: URL, locale: Locale) async throws -> [TimedWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.missingCapability(.speechAssets)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil else {
            throw EngineError.missingCapability(.speechAssets)
        }
        let collector = Task {
            var words: [TimedWord] = []
            for try await result in transcriber.results { words += timedWords(in: result.text) }
            return words
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: url), finishAfterFile: true)
        return try await collector.value
    }

    private static func timedWords(in text: AttributedString) -> [TimedWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let word = String(text[run.range].characters)
            return TimedWord(text: word, start: range.start.seconds, end: range.end.seconds)
        }
    }

    /// Sentences wrapped to 42 by two.
    static func cues(from words: [TimedWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var pending: [TimedWord] = []
        func flush() {
            cues += split(pending)
            pending = []
        }
        for word in words {
            if let last = pending.last, word.start - last.end > pauseSeconds { flush() }
            pending.append(word)
            if let final = word.text.trimmingCharacters(in: .whitespaces).last, sentenceEnds.contains(final) { flush() }
        }
        flush()
        return cues
    }

    /// Greedy fill; over-long sentences span cues.
    private static func split(_ words: [TimedWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var lines: [String] = []
        var line = ""
        var start = words.first?.start ?? 0
        var end = start
        for word in words {
            let candidate = line + word.text
            if candidate.trimmingCharacters(in: .whitespaces).count > maximumLineLength, !line.isEmpty {
                lines.append(line.trimmingCharacters(in: .whitespaces))
                line = ""
                if lines.count == maximumLines {
                    cues.append(SubtitleCue(start: start, end: end, lines: lines))
                    lines = []
                    start = word.start
                }
            }
            line += word.text
            end = word.end
        }
        let last = line.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { lines.append(last) }
        if !lines.isEmpty { cues.append(SubtitleCue(start: start, end: end, lines: lines)) }
        return cues
    }

    static func translated(_ cues: [SubtitleCue], from source: Locale.Language, to target: Locale.Language)
        async throws -> [SubtitleCue]
    {
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { throw EngineError.missingCapability(.translationModel) }
        let session = TranslationSession(installedSource: source, target: target)
        let requests = cues.map { TranslationSession.Request(sourceText: $0.lines.joined(separator: " ")) }
        let responses = try await session.translations(from: requests)
        return zip(cues, responses).flatMap { cue, response in
            split(spread(response.targetText, from: cue.start, to: cue.end))
        }
    }

    /// Times follow character position; CJK breaks anywhere.
    static func spread(_ text: String, from start: Double, to end: Double) -> [TimedWord] {
        let tokens: [String] =
            text.contains(" ") ? text.split(separator: " ").map { $0 + " " } : text.map { String($0) }
        let total = Double(max(text.count, 1))
        var offset = 0.0
        return tokens.map { token in
            defer { offset += Double(token.count) }
            let tokenStart = start + (end - start) * offset / total
            let tokenEnd = start + (end - start) * (offset + Double(token.count)) / total
            return TimedWord(text: token, start: tokenStart, end: tokenEnd)
        }
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
                + cue.lines.joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n"
            + cues.map { cue in
                "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n"
                    + cue.lines.joined(separator: "\n") + "\n"
            }.joined(separator: "\n")
    }

    static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { $0.lines.joined(separator: " ") }.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: Double, separator: String) -> String {
        let millisecondsPerSecond = 1_000
        let secondsPerMinute = 60
        let total = Int((seconds * Double(millisecondsPerSecond)).rounded())
        let (wholeSeconds, milliseconds) = total.quotientAndRemainder(dividingBy: millisecondsPerSecond)
        let (wholeMinutes, secondsPart) = wholeSeconds.quotientAndRemainder(dividingBy: secondsPerMinute)
        let (hours, minutes) = wholeMinutes.quotientAndRemainder(dividingBy: secondsPerMinute)
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secondsPart, separator, milliseconds)
    }
}
