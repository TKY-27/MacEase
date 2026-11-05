import Foundation
import MenuCatalog

public struct MediaDownloader: Sendable {
    private let tools: MediaDownloadTools

    public init(tools: MediaDownloadTools? = nil) throws {
        self.tools = try tools ?? .bundled()
    }

    public static func validateURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8_192, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            let components = URLComponents(string: text),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
            let url = components.url
        else { throw EngineError.invalidInput(.malformed("Enter a public HTTP or HTTPS URL without credentials")) }
        return url
    }

    public func analyze(urls: [URL]) async throws -> MediaAnalysis {
        guard !urls.isEmpty, urls.count <= 100 else { throw EngineError.invalidInput(.emptyInput) }
        var sources: [MediaSource] = []
        var failures: [MediaAnalysisFailure] = []
        for url in urls {
            try Task.checkCancellation()
            do {
                sources += try await metadata(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(MediaAnalysisFailure(url: url, message: Self.failureMessage(error)))
            }
        }
        var seen = Set<String>()
        return MediaAnalysis(sources: sources.filter { seen.insert($0.id).inserted }, failures: failures)
    }

    public func makeBatch(_ request: MediaDownloadRequest) throws -> Batch {
        guard request.destination.isFileURL, !request.selections.isEmpty, request.selections.count <= 512 else {
            throw EngineError.invalidInput(.emptyInput)
        }
        let values = try request.destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw EngineError.invalidInput(.unsupportedFileType)
        }
        let selections = try request.selections.map { selection in
            _ = try Self.validateURL(selection.source.webpageURL.absoluteString)
            if let height = selection.resolution {
                guard height > 0, selection.source.resolutions.contains(height) else {
                    throw EngineError.invalidInput(.invalidNumericParameter)
                }
            }
            if let subtitle = selection.subtitle {
                guard selection.source.subtitles.contains(subtitle), Self.safeLanguage(subtitle.language) else {
                    throw EngineError.invalidInput(.malformed("Subtitle language is unavailable"))
                }
            }
            return WorkItem(inputs: [], lane: .download) { context in
                try await download(selection, destination: request.destination, context: context)
            }
        }
        return Batch(operation: .folderDownloadMedia, items: selections)
    }

    private func metadata(_ page: URL) async throws -> [MediaSource] {
        _ = try Self.validateURL(page.absoluteString)
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await invoke(
            [
                "--dump-single-json", "--skip-download", "--no-flat-playlist", "--playlist-end", "512", "--",
                page.absoluteString,
            ],
            directory: directory)
        let decoded = try JSONDecoder().decode(Metadata.self, from: result.stdout)
        return try decoded.sources(fallback: page)
    }

    private func download(_ selection: MediaDownloadSelection, destination: URL, context: ItemContext) async throws
        -> ItemResult
    {
        let fresh = try await metadata(selection.source.webpageURL)
        guard let source = fresh.first(where: { $0.id == selection.source.id }) else {
            throw EngineError.decodeFailed("The selected media is no longer available")
        }
        if let height = selection.resolution, !source.resolutions.contains(height) {
            throw EngineError.decodeFailed("The selected resolution is no longer available")
        }
        if let subtitle = selection.subtitle, !source.subtitles.contains(subtitle) {
            throw EngineError.decodeFailed("The selected subtitles are no longer available")
        }
        let directory = try context.stagingDirectory(for: destination)
        context.phase(.downloading)
        var arguments = [
            "--no-playlist", "--no-simulate", "--no-overwrites", "--no-continue", "--newline", "--progress",
            "--progress-template", "download:MACEASE:%(progress.downloaded_bytes)s:%(progress.total_bytes)s",
            "--progress-template", "postprocess:MACEASE:POST",
            "--output", directory.appending(path: "download.%(ext)s").path,
            "--format", formatSelector(selection),
        ]
        if selection.format == .audio { arguments += ["--extract-audio", "--audio-format", "best"] }
        if let subtitle = selection.subtitle {
            arguments += [
                subtitle.automatic ? "--write-auto-subs" : "--write-subs",
                "--sub-langs", "^" + NSRegularExpression.escapedPattern(for: subtitle.language) + "$",
                "--sub-format", "vtt/srt/best",
            ]
        }
        arguments += ["--", source.webpageURL.absoluteString]
        _ = try await invoke(arguments, directory: directory, captureOutput: false) { line in
            if line == "MACEASE:POST" { context.phase(.converting) }
            let components = line.split(separator: ":")
            if components.count == 3, components[0] == "MACEASE", let bytes = Double(components[1]),
                let total = Double(components[2]), total > 0, bytes >= 0
            {
                context.progress(bytes / total)
            }
        }
        let downloaded = try outputs(in: directory)
        let subtitles = downloaded.filter { ["srt", "vtt"].contains($0.pathExtension) }
        let media = downloaded.filter { !["srt", "vtt"].contains($0.pathExtension) }
        guard media.count == 1 else { throw EngineError.decodeFailed("Download did not produce one media file") }
        var output = media[0]
        if selection.format != .source && selection.format != .audio {
            context.phase(.converting)
            output = try await convert(output, selection: selection, directory: directory)
        }
        context.phase(.verifying)
        let base = Self.safeName(source.title)
        var staged = [StagedFile(url: output, name: base + "." + output.pathExtension, check: .downloadedMedia(tools))]
        if let requested = selection.subtitle {
            guard subtitles.count == 1 else { throw EngineError.decodeFailed("Requested subtitle was not downloaded") }
            let subtitle = subtitles[0]
            try DownloadSubtitles.validate(subtitle)
            let sidecar: URL
            if subtitle.pathExtension == selection.subtitleFormat.rawValue {
                sidecar = subtitle
            } else {
                sidecar = directory.appending(path: "subtitle." + selection.subtitleFormat.rawValue)
                _ = try await MediaToolProcess().run(
                    executable: tools.ffmpeg,
                    arguments: ["-nostdin", "-v", "error", "-n", "-i", subtitle.path, "-map", "0:s:0", sidecar.path],
                    directory: directory, tools: tools, captureOutput: false)
                try DownloadSubtitles.validate(sidecar)
            }
            staged.append(
                StagedFile(
                    url: sidecar, name: base + "." + requested.language + "." + selection.subtitleFormat.rawValue,
                    check: .text(.utf8)))
        }
        return .created(in: destination, outputs: staged)
    }

    private func formatSelector(_ selection: MediaDownloadSelection) -> String {
        if selection.format.audioOnly { return "bestaudio/best" }
        if let height = selection.resolution { return "bestvideo[height=\(height)]+bestaudio/best[height=\(height)]" }
        return "bestvideo+bestaudio/best"
    }

    private func convert(_ input: URL, selection: MediaDownloadSelection, directory: URL) async throws -> URL {
        let output = directory.appending(path: "converted." + selection.format.rawValue)
        let probe = try await Self.probe(input, tools: tools)
        let video = probe.streams.first { $0.codecType == "video" }?.codecName
        let audio = probe.streams.first { $0.codecType == "audio" }?.codecName
        var arguments = ["-nostdin", "-v", "error", "-n", "-i", input.path]
        switch selection.format {
        case .mp4:
            arguments += [
                "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "h264_videotoolbox", "-b:v", "0", "-q:v", "65", "-c:a",
                "aac", "-movflags", "+faststart",
            ]
        case .mkv: arguments += ["-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy"]
        case .webm:
            arguments += [
                "-map", "0:v:0", "-map", "0:a:0?", "-c:v",
                ["vp8", "vp9", "av1"].contains(video ?? "") ? "copy" : "libvpx-vp9",
                "-c:a", ["opus", "vorbis"].contains(audio ?? "") ? "copy" : "libopus",
            ]
        case .m4a: arguments += ["-vn", "-c:a", ["aac", "alac"].contains(audio ?? "") ? "copy" : "aac"]
        case .mp3: arguments += ["-vn", "-c:a", audio == "mp3" ? "copy" : "libmp3lame"]
        case .wav: arguments += ["-vn", "-c:a", audio?.hasPrefix("pcm_") == true ? "copy" : "pcm_s24le"]
        case .flac: arguments += ["-vn", "-c:a", audio == "flac" ? "copy" : "flac"]
        case .source, .audio: break
        }
        arguments.append(output.path)
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg, arguments: arguments, directory: directory, tools: tools, captureOutput: false)
        return output
    }

    static func verify(_ output: URL, tools: MediaDownloadTools) async throws {
        let probe = try await probe(output, tools: tools)
        let streams = probe.streams.filter { ["video", "audio"].contains($0.codecType) }
        guard !streams.isEmpty, streams.allSatisfy({ (Int($0.packets ?? "") ?? 0) > 0 }) else {
            throw EngineError.decodeFailed("Downloaded media has no valid packets")
        }
    }

    private static func probe(_ output: URL, tools: MediaDownloadTools) async throws -> Probe {
        let result = try await MediaToolProcess().run(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-count_packets", "-show_entries", "stream=codec_type,codec_name,nb_read_packets", "-of",
                "json",
                output.path,
            ],
            directory: output.deletingLastPathComponent(), tools: tools)
        return try JSONDecoder().decode(Probe.self, from: result.stdout)
    }

    private func outputs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter {
            guard $0.lastPathComponent.hasPrefix("download.") else { return false }
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                $0.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
                !$0.lastPathComponent.contains(".part"), !$0.lastPathComponent.contains(".ytdl")
            else {
                throw EngineError.decodeFailed("Download output is unsafe or incomplete")
            }
            return true
        }
    }

    private func invoke(
        _ arguments: [String], directory: URL, captureOutput: Bool = true,
        line: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MediaToolResult {
        let launcher =
            "import os,runpy,sys; os.setsid(); sys.argv=['yt-dlp']+sys.argv[1:]; runpy.run_module('yt_dlp',run_name='__main__')"
        return try await MediaToolProcess().run(
            executable: tools.python,
            arguments: [
                "-I", "-c", launcher, "--ignore-config", "--no-plugin-dirs", "--no-update", "--no-cache-dir",
                "--no-remote-components", "--no-js-runtimes", "--js-runtimes", "deno:" + tools.deno.path,
                "--ffmpeg-location", tools.directory.path, "--socket-timeout", "30",
            ] + arguments,
            directory: directory, tools: tools, captureOutput: captureOutput, line: line)
    }

    private static func safeName(_ title: String) -> String {
        let scalars = title.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar)
                ? "_" : String(scalar)
        }.joined()
        let trimmed = scalars.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var bounded = ""
        for character in trimmed {
            guard bounded.utf8.count + String(character).utf8.count <= 170 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Media" : bounded
    }

    private static func safeLanguage(_ language: String) -> Bool {
        !language.isEmpty && language.count <= 64
            && language.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
            }
    }

    private static func failureMessage(_ error: any Error) -> String {
        if case EngineError.invalidInput(.malformed(let message)) = error { return message }
        if case EngineError.decodeFailed(let message) = error { return message }
        return "Media could not be analyzed. The site may require login or be unsupported."
    }

    private struct Probe: Decodable {
        let streams: [Stream]
        struct Stream: Decodable {
            let codecType: String
            let codecName: String?
            let packets: String?
            enum CodingKeys: String, CodingKey {
                case codecType = "codec_type", codecName = "codec_name", packets = "nb_read_packets"
            }
        }
    }

    private struct Metadata: Decodable {
        let id: String?
        let title: String?
        let webpageURL: String?
        let duration: Double?
        let entries: [Metadata?]?
        let formats: [Format]?
        let subtitles: [String: [Track]]?
        let automaticCaptions: [String: [Track]]?
        let isLive: Bool?
        let liveStatus: String?
        let hasDRM: Bool?
        enum CodingKeys: String, CodingKey {
            case id, title, duration, entries, formats, subtitles
            case webpageURL = "webpage_url", automaticCaptions = "automatic_captions"
            case isLive = "is_live", liveStatus = "live_status", hasDRM = "has_drm"
        }
        struct Track: Decodable {}
        struct Format: Decodable {
            let height: Double?
            let ext: String?
            let hasDRM: Bool?
            enum CodingKeys: String, CodingKey { case height, ext, hasDRM = "has_drm" }
        }

        func sources(fallback: URL, playlist: Bool = false, depth: Int = 0) throws -> [MediaSource] {
            guard depth < 8 else { throw EngineError.decodeFailed("Playlist nesting exceeds limit") }
            if let entries {
                guard entries.count <= 512 else { throw EngineError.decodeFailed("Playlist exceeds 512 entries") }
                return try entries.compactMap { $0 }.flatMap {
                    try $0.sources(fallback: fallback, playlist: true, depth: depth + 1)
                }
            }
            guard isLive != true, liveStatus != "is_live", liveStatus != "is_upcoming", hasDRM != true else {
                throw EngineError.decodeFailed("Live, upcoming and DRM-protected media are unsupported")
            }
            let page = try MediaDownloader.validateURL(webpageURL ?? fallback.absoluteString)
            guard let id, !id.isEmpty, id.utf8.count <= 1_024, let title, !title.isEmpty, title.utf8.count <= 16_384
            else {
                throw EngineError.decodeFailed("Media metadata is incomplete")
            }
            let usable = (formats ?? []).filter { $0.hasDRM != true }
            if let formats, !formats.isEmpty, usable.isEmpty {
                throw EngineError.decodeFailed("DRM-protected media is unsupported")
            }
            let heights = Set(
                usable.compactMap(\.height).filter { $0.isFinite && $0 > 0 && $0 <= 16_384 }.map(Int.init))
            let authored = (subtitles ?? [:]).keys.filter(MediaDownloader.safeLanguage).map {
                MediaSubtitle(language: $0, automatic: false)
            }
            let automatic = (automaticCaptions ?? [:]).keys.filter(MediaDownloader.safeLanguage).map {
                MediaSubtitle(language: $0, automatic: true)
            }
            let extensions = Set(
                usable.compactMap(\.ext).filter {
                    $0.count <= 16 && $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
                })
            return [
                MediaSource(
                    id: page.absoluteString + "#" + id, webpageURL: page, title: title,
                    duration: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                    resolutions: heights.sorted(by: >),
                    subtitles: (authored + automatic).sorted {
                        ($0.language, $0.automatic ? 1 : 0) < ($1.language, $1.automatic ? 1 : 0)
                    }, isPlaylistEntry: playlist, availableFormats: extensions.sorted())
            ]
        }
    }
}
