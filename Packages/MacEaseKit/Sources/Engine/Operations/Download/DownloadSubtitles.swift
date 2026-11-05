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
