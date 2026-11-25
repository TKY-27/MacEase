import Foundation

struct BaselineDownloadSubtitles {
    private static let maximumBytes = 8 * 1_024 * 1_024
    private static let maximumCues = 100_000

    static func validate(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= maximumBytes else { throw invalid() }
        let bytes = try Data(contentsOf: url)
        guard let decoded = String(data: bytes, encoding: .utf8) else { throw invalid() }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingPrefix("\u{FEFF}")
        guard
            !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
            })
        else {
            throw invalid()
        }
        let vtt = url.pathExtension == "vtt"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if vtt {
            guard let header = lines.first, header == "WEBVTT" || header.hasPrefix("WEBVTT ") else { throw invalid() }
            while !lines.isEmpty && !lines[0].isEmpty { lines.removeFirst() }
        }
        let expression = try NSRegularExpression(
            pattern:
                #"^(?:(\d{2,4}):)?([0-5]\d):([0-5]\d)[.,](\d{3}) --> (?:(\d{2,4}):)?([0-5]\d):([0-5]\d)[.,](\d{3})(?:[ \t].*)?$"#
        )
        var count = 0
        var cursor = 0
        while cursor < lines.count {
            while cursor < lines.count && lines[cursor].isEmpty { cursor += 1 }
            guard cursor < lines.count else { break }
            let start = cursor
            while cursor < lines.count && !lines[cursor].isEmpty { cursor += 1 }
            let block = Array(lines[start..<cursor])
            if vtt, block[0] == "STYLE" || block[0] == "REGION" || block[0].hasPrefix("NOTE") { continue }
            let timingIndex = block[0].contains(" --> ") ? 0 : 1
            guard block.count > timingIndex + 1 else { throw invalid() }
            let timing = block[timingIndex]
            let range = NSRange(timing.startIndex..., in: timing)
            guard let match = expression.firstMatch(in: timing, range: range) else { throw invalid() }
            func milliseconds(_ offset: Int) throws -> Int {
                var components: [Int] = []
                for index in offset..<(offset + 4) {
                    if let range = Range(match.range(at: index), in: timing), let value = Int(timing[range]) {
                        components.append(value)
                    } else if index == offset {
                        components.append(0)
                    } else {
                        throw invalid()
                    }
                }
                return ((components[0] * 60 + components[1]) * 60 + components[2]) * 1_000 + components[3]
            }
            guard try milliseconds(5) > milliseconds(1) else { throw invalid() }
            count += 1
            guard count <= maximumCues else { throw invalid() }
        }
        guard count > 0 else { throw invalid() }
    }

    private static func invalid() -> EngineError { .decodeFailed("Subtitle encoding or timing is invalid") }
}

import Foundation

struct DownloadSubtitles {
    private static let maximumBytes = 8 * 1_024 * 1_024
    private static let maximumCues = 100_000

    static func validate(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= maximumBytes else { throw invalid() }
        let bytes = try Data(contentsOf: url)
        guard let decoded = String(data: bytes, encoding: .utf8) else { throw invalid() }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingPrefix("\u{FEFF}")
        guard
            !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
            })
        else {
            throw invalid()
        }
        let vtt = url.pathExtension == "vtt"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cursor = 0
        if vtt {
            guard let header = lines.first, header == "WEBVTT" || header.hasPrefix("WEBVTT ") else { throw invalid() }
            while cursor < lines.count && !lines[cursor].isEmpty { cursor += 1 }
        }
        let expression = try NSRegularExpression(
            pattern:
                #"^(?:(\d{2,4}):)?([0-5]\d):([0-5]\d)[.,](\d{3}) --> (?:(\d{2,4}):)?([0-5]\d):([0-5]\d)[.,](\d{3})(?:[ \t].*)?$"#
        )
        var count = 0
        while cursor < lines.count {
            while cursor < lines.count && lines[cursor].isEmpty { cursor += 1 }
            guard cursor < lines.count else { break }
            let start = cursor
            while cursor < lines.count && !lines[cursor].isEmpty { cursor += 1 }
            let block = Array(lines[start..<cursor])
            if vtt, block[0] == "STYLE" || block[0] == "REGION" || block[0].hasPrefix("NOTE") { continue }
            let timingIndex = block[0].contains(" --> ") ? 0 : 1
            guard block.count > timingIndex + 1 else { throw invalid() }
            let timing = block[timingIndex]
            let range = NSRange(timing.startIndex..., in: timing)
            guard let match = expression.firstMatch(in: timing, range: range) else { throw invalid() }
            func milliseconds(_ offset: Int) throws -> Int {
                var components: [Int] = []
                for index in offset..<(offset + 4) {
                    if let range = Range(match.range(at: index), in: timing), let value = Int(timing[range]) {
                        components.append(value)
                    } else if index == offset {
                        components.append(0)
                    } else {
                        throw invalid()
                    }
                }
                return ((components[0] * 60 + components[1]) * 60 + components[2]) * 1_000 + components[3]
            }
            guard try milliseconds(5) > milliseconds(1) else { throw invalid() }
            count += 1
            guard count <= maximumCues else { throw invalid() }
        }
        guard count > 0 else { throw invalid() }
    }

    private static func invalid() -> EngineError { .decodeFailed("Subtitle encoding or timing is invalid") }
}


import Foundation

enum EngineError: Error { case decodeFailed(String) }

let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("macease-subtitle-" + UUID().uuidString)
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureRoot) }
let cue = "00:00:01.000 --> 00:00:02.000\nCaption\n"
let longHeader = "WEBVTT\n" + String(repeating: "Metadata\n", count: 32_768)
let fixtures: [(String, String, Bool)] = [
    ("vtt", "WEBVTT\n\n" + cue, true),
    ("vtt", "WEBVTT description\n\n" + cue, true),
    ("vtt", "\u{FEFF}WEBVTT\r\n\r\n" + cue.replacingOccurrences(of: "\n", with: "\r\n"), true),
    ("vtt", longHeader + "\n" + cue, true),
    ("vtt", longHeader, false),
    ("vtt", longHeader + cue, false),
    ("vtt", "WEBVTT\n\n", false),
    ("vtt", "WEBVTTbad\n\n" + cue, false),
    ("vtt", "WEBVTT\n\n00:00:02.000 --> 00:00:01.000\nBackwards\n", false),
    ("vtt", "WEBVTT\n\nNOTE comment\nignored\n\n" + cue + "\n" + cue, true),
    ("srt", "1\n00:00:01,000 --> 00:00:02,000\nCaption\n", true),
    ("srt", "1\n00:00:01,000 --> 00:00:02,000\n", false),
]
func accepts(_ url: URL, baseline: Bool) -> Bool {
    do {
        if baseline { try BaselineDownloadSubtitles.validate(url) }
        else { try DownloadSubtitles.validate(url) }
        return true
    } catch { return false }
}
for (index, fixture) in fixtures.enumerated() {
    let url = fixtureRoot.appendingPathComponent("fixture-\(index).\(fixture.0)")
    try fixture.1.write(to: url, atomically: false, encoding: .utf8)
    let oldResult = accepts(url, baseline: true)
    let newResult = accepts(url, baseline: false)
    precondition(oldResult == fixture.2 && newResult == fixture.2, "fixture \(index) baseline=\(oldResult) current=\(newResult)")
}
print("Behavior fixtures: \(fixtures.count) passed for baseline and current")
func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
let url = fixtureRoot.appendingPathComponent("benchmark.vtt")
for headerLines in [2_000, 8_000, 32_000, 100_000] {
    let text = "WEBVTT\n" + String(repeating: "X\n", count: headerLines) + "\n" + cue
    try text.write(to: url, atomically: false, encoding: .utf8)
    try BaselineDownloadSubtitles.validate(url)
    try DownloadSubtitles.validate(url)
    var oldSamples: [Double] = []
    var newSamples: [Double] = []
    for iteration in 0..<5 {
        let order = iteration.isMultiple(of: 2) ? [true, false] : [false, true]
        for baseline in order {
            let started = ContinuousClock.now
            if baseline { try BaselineDownloadSubtitles.validate(url) }
            else { try DownloadSubtitles.validate(url) }
            let elapsed = seconds(started.duration(to: .now))
            if baseline { oldSamples.append(elapsed) } else { newSamples.append(elapsed) }
        }
    }
    let oldMedian = oldSamples.sorted()[2]
    let newMedian = newSamples.sorted()[2]
    print("header_lines=\(headerLines) bytes=\(text.utf8.count) baseline_median_s=\(oldMedian) current_median_s=\(newMedian) speedup=\(oldMedian / newMedian)")
}
