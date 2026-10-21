import Foundation

enum SubtitleConversion {
    private static let maximumInputBytes = 8 * 1_024 * 1_024
    private static let maximumCueCount = 100_000
    private static let maximumLineLength = 65_536
    private static let millisecondsPerSecond = 1_000
    private static let secondsPerMinute = 60
    private static let maximumHours = 9_999

    static func convert(_ text: String, fromVTT: Bool) throws -> String {
        guard text.utf8.count <= maximumInputBytes else {
            throw malformed("subtitle input exceeds 8 MiB")
        }
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else {
            throw malformed("bare carriage return is not supported")
        }
        var lineLength = 0
        for character in normalized {
            if character == "\n" {
                lineLength = 0
            } else {
                lineLength += 1
                guard lineLength <= maximumLineLength else {
                    throw malformed("subtitle line exceeds 65536 characters")
                }
            }
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let cues = try fromVTT ? parseVTT(lines) : parseSRT(lines)
        if fromVTT { return try Subtitles.srt(cues) }
        let escaped = cues.map { cue in
            SubtitleCue(start: cue.start, end: cue.end, lines: cue.lines.map(escapeVTT))
        }
        return try Subtitles.vtt(escaped)
    }

    private static func parseSRT(_ lines: [Substring]) throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var cursor = 0
        while cursor < lines.count {
            while cursor < lines.count, lines[cursor].isEmpty { cursor += 1 }
            guard cursor < lines.count else { break }
            guard lines[cursor] == Substring(String(cues.count + 1)) else {
                throw malformed("unsupported SRT cue identifier")
            }
            cursor += 1
            guard cursor < lines.count else { throw malformed("missing SRT cue timing") }
            let timing = try parseTiming(lines[cursor], separator: ",")
            cursor += 1
            var payload: [String] = []
            while cursor < lines.count, !lines[cursor].isEmpty {
                payload.append(try plainText(lines[cursor], fromVTT: false))
                cursor += 1
            }
            guard !payload.isEmpty else { throw malformed("SRT cue has no text") }
            cues.append(
                SubtitleCue(
                    start: Double(timing.0) / Double(millisecondsPerSecond),
                    end: Double(timing.1) / Double(millisecondsPerSecond), lines: payload))
            guard cues.count <= maximumCueCount else { throw malformed("subtitle exceeds 100000 cues") }
        }
        guard !cues.isEmpty else { throw malformed("subtitle contains no cues") }
        return cues
    }

    private static func parseVTT(_ lines: [Substring]) throws -> [SubtitleCue] {
        guard lines.first == "WEBVTT", lines.count >= 2, lines[1].isEmpty else {
            throw malformed("missing WebVTT header")
        }
        var cues: [SubtitleCue] = []
        var cursor = 1
        while cursor < lines.count {
            while cursor < lines.count, lines[cursor].isEmpty { cursor += 1 }
            guard cursor < lines.count else { break }
            let line = lines[cursor]
            guard !line.hasPrefix("NOTE"), !line.hasPrefix("STYLE"), !line.hasPrefix("REGION") else {
                throw malformed("WebVTT metadata is not supported")
            }
            guard line.contains(" --> ") else {
                throw malformed("WebVTT cue identifiers are not supported")
            }
            let timing = try parseTiming(line, separator: ".")
            cursor += 1
            var payload: [String] = []
            while cursor < lines.count, !lines[cursor].isEmpty {
                payload.append(try plainText(lines[cursor], fromVTT: true))
                cursor += 1
            }
            guard !payload.isEmpty else { throw malformed("WebVTT cue has no text") }
            cues.append(
                SubtitleCue(
                    start: Double(timing.0) / Double(millisecondsPerSecond),
                    end: Double(timing.1) / Double(millisecondsPerSecond), lines: payload))
            guard cues.count <= maximumCueCount else { throw malformed("subtitle exceeds 100000 cues") }
        }
        guard !cues.isEmpty else { throw malformed("subtitle contains no cues") }
        return cues
    }

    private static func parseTiming(_ line: Substring, separator: String) throws -> (Int, Int) {
        let fields = line.components(separatedBy: " --> ")
        guard fields.count == 2, let start = timestamp(fields[0], separator: separator),
            let end = timestamp(fields[1], separator: separator), end > start
        else { throw malformed("invalid subtitle timing") }
        return (start, end)
    }

    private static func timestamp(_ value: String, separator: String) -> Int? {
        let fraction = value.split(separator: Character(separator), omittingEmptySubsequences: false)
        guard fraction.count == 2, fraction[1].utf8.count == 3 else { return nil }
        var clock = fraction[0].split(separator: ":", omittingEmptySubsequences: false)
        if separator == ".", clock.count == 2 { clock.insert("00", at: 0) }
        guard clock.count == 3, clock[0].count >= 2,
            clock[1].count == 2, clock[2].count == 2,
            (clock + [fraction[1]]).allSatisfy({
                $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
            }),
            let hours = Int(clock[0]), hours <= maximumHours,
            let minutes = Int(clock[1]), minutes < secondsPerMinute,
            let seconds = Int(clock[2]), seconds < secondsPerMinute,
            let milliseconds = Int(fraction[1])
        else { return nil }
        return ((hours * secondsPerMinute + minutes) * secondsPerMinute + seconds) * millisecondsPerSecond
            + milliseconds
    }

    private static func plainText(_ line: Substring, fromVTT: Bool) throws -> String {
        let value = String(line)
        if !fromVTT {
            guard !containsTag(value) else {
                throw malformed("subtitle styling and markup are not supported")
            }
            return value
        }
        guard !line.contains("<") else {
            throw malformed("subtitle styling and markup are not supported")
        }
        var decoded = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let replacement: (String, String)? =
                if value[cursor...].hasPrefix("&amp;") {
                    ("&amp;", "&")
                } else if value[cursor...].hasPrefix("&lt;") {
                    ("&lt;", "<")
                } else if value[cursor...].hasPrefix("&gt;") {
                    ("&gt;", ">")
                } else if value[cursor...].hasPrefix("&nbsp;") {
                    ("&nbsp;", "\u{00A0}")
                } else if value[cursor...].hasPrefix("&lrm;") {
                    ("&lrm;", "\u{200E}")
                } else if value[cursor...].hasPrefix("&rlm;") {
                    ("&rlm;", "\u{200F}")
                } else {
                    nil
                }
            if let replacement {
                decoded += replacement.1
                cursor = value.index(cursor, offsetBy: replacement.0.count)
            } else {
                decoded.append(value[cursor])
                cursor = value.index(after: cursor)
            }
        }
        guard !containsTag(decoded) else {
            throw malformed("decoded subtitle text would become SRT styling")
        }
        return decoded
    }

    private static func containsTag(_ text: String) -> Bool {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "<" else {
                cursor = text.index(after: cursor)
                continue
            }
            let next = text.index(after: cursor)
            guard next < text.endIndex else { return false }
            let character = text[next]
            if character == "/" || character == "!" || character == "?" || character.isLetter {
                return true
            }
            cursor = next
        }
        return false
    }

    private static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func malformed(_ reason: String) -> EngineError {
        .invalidInput(.malformed(reason))
    }
}
