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
        guard SpeechTranscriber.isAvailable else { throw EngineError.missingCapability(.speechAssets) }
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
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: url), finishAfterFile: true)
                return try await collector.value
            } catch {
                collector.cancel()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    static func export(_ request: SubtitleRequest, audioFile: URL, nextTo url: URL, context: ItemContext)
        async throws -> ItemResult
    {
        let locale = request.language.isEmpty ? Locale.current : Locale(identifier: request.language)
        var cues = cues(from: try await transcribe(audioFile: audioFile, locale: locale))
        guard !cues.isEmpty else { return .skipped(.noTextFound) }
        var suffix = ""
        if let target = request.translation {
            cues = try await translated(cues, from: locale.language, to: Locale.Language(identifier: target))
            suffix = "." + target
        }
        let text: String =
            switch request.format {
            case .srt: try srt(cues)
            case .vtt: try vtt(cues)
            case .txt: plainText(cues)
            }
        let name = url.deletingPathExtension().lastPathComponent + suffix + "." + request.format.rawValue
        let output = try context.stagingURL(for: url, name: name)
        try Data(text.utf8).write(to: output)
        return .derived(nextTo: url, outputs: [StagedFile(url: output, name: name, check: .text(.utf8))])
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
        let timedFragments = words.flatMap { word -> [TimedWord] in
            guard word.text.count > maximumLineLength else { return [word] }
            let characters = Array(word.text)
            return stride(from: 0, to: characters.count, by: maximumLineLength).map { offset in
                let limit = min(offset + maximumLineLength, characters.count)
                let duration = word.end - word.start
                return TimedWord(
                    text: String(characters[offset..<limit]),
                    start: word.start + duration * Double(offset) / Double(characters.count),
                    end: word.start + duration * Double(limit) / Double(characters.count))
            }
        }
        for word in timedFragments {
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
        let total = Double(max(tokens.reduce(0) { $0 + $1.count }, 1))
        var offset = 0.0
        return tokens.map { token in
            defer { offset += Double(token.count) }
            let tokenStart = start + (end - start) * offset / total
            let tokenEnd = start + (end - start) * (offset + Double(token.count)) / total
            return TimedWord(text: token, start: tokenStart, end: tokenEnd)
        }
    }

    static func srt(_ cues: [SubtitleCue]) throws -> String {
        try cues.enumerated().map { index, cue in
            "\(index + 1)\n\(try timestamp(cue.start, separator: ",")) --> \(try timestamp(cue.end, separator: ","))\n"
                + cue.lines.joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) throws -> String {
        "WEBVTT\n\n"
            + (try cues.map { cue in
                "\(try timestamp(cue.start, separator: ".")) --> \(try timestamp(cue.end, separator: "."))\n"
                    + cue.lines.joined(separator: "\n") + "\n"
            }.joined(separator: "\n"))
    }

    static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { $0.lines.joined(separator: " ") }.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: Double, separator: String) throws -> String {
        let millisecondsPerSecond = 1_000
        let secondsPerMinute = 60
        guard seconds.isFinite, seconds >= 0,
            let total = Int(exactly: (seconds * Double(millisecondsPerSecond)).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let (wholeSeconds, milliseconds) = total.quotientAndRemainder(dividingBy: millisecondsPerSecond)
        let (wholeMinutes, secondsPart) = wholeSeconds.quotientAndRemainder(dividingBy: secondsPerMinute)
        let (hours, minutes) = wholeMinutes.quotientAndRemainder(dividingBy: secondsPerMinute)
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secondsPart, separator, milliseconds)
    }
}
