import Foundation
import ImageIO

struct GalleryDownloader: Sendable {
    let tools: MediaDownloadTools
    private static let maximumImages = 512
    private static let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "tif", "tiff", "bmp"]

    func analyze(_ page: URL) async throws -> MediaSource {
        _ = try MediaDownloader.validateURL(page.absoluteString)
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reply = try await invoke(["--dump-json", "--", page.absoluteString], directory: scratch)
        return try Self.source(from: reply.stdout, page: page)
    }

    static func source(from encoded: Data, page: URL) throws -> MediaSource {
        let records = try JSONDecoder().decode([Record].self, from: encoded)
        guard !records.contains(where: { $0.kind == -1 || $0.kind == 6 }) else {
            throw EngineError.decodeFailed("Use a direct post or album URL containing up to 512 images")
        }
        let images = records.filter { $0.kind == 3 }
        guard !images.isEmpty, images.count <= maximumImages else {
            throw EngineError.decodeFailed("Choose a gallery containing 1 to 512 images")
        }
        for record in images {
            guard let address = record.address, let suffix = record.attributes?.suffix,
                imageExtensions.contains(suffix.lowercased())
            else { throw EngineError.decodeFailed("The gallery contains an unsupported image") }
            _ = try MediaDownloader.validateURL(address)
        }
        let proposed = records.compactMap { $0.attributes?.title }.first { !$0.isEmpty }
        let title = proposed ?? page.host() ?? "Images"
        let thumbnail = images.first?.address.flatMap(URL.init(string:))
        return MediaSource(
            id: page.absoluteString + "#gallery", webpageURL: page, title: MediaDownloader.safeName(title),
            duration: nil, resolutions: [], subtitles: [], isPlaylistEntry: true,
            thumbnailURL: thumbnail.flatMap { MediaDownloader.isThumbnailURL($0) ? $0 : nil },
            galleryCount: images.count)
    }

    func download(_ source: MediaSource, destination: URL, context: ItemContext) async throws -> ItemResult {
        let fresh = try await analyze(source.webpageURL)
        guard fresh.galleryCount == source.galleryCount else {
            throw EngineError.decodeFailed("The gallery changed. Analyze it again before downloading")
        }
        let staging = try context.stagingDirectory(for: destination)
        let output = staging.appending(path: "gallery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        context.phase(.downloading)
        _ = try await invoke(
            [
                "--directory", output.path, "--filename", "image.{extension}", "-o", "skip=enumerate",
                "--child-filter", "False",
                "--", source.webpageURL.absoluteString,
            ], directory: staging, captureOutput: false)
        context.phase(.verifying)
        let images = try await Self.verifyImages(in: output, expectedCount: fresh.galleryCount ?? 0)
        let record = GalleryProvenance(
            source: source.webpageURL, retrieved: Date(), tool: "gallery-dl", files: images.map(\.lastPathComponent))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: output.appending(path: GalleryProvenance.filename), options: .withoutOverwriting)
        return .created(
            in: destination,
            outputs: [StagedFile(url: output, name: MediaDownloader.safeName(fresh.title), check: .folder)])
    }

    static func verifyImages(in directory: URL, expectedCount: Int) async throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard files.count == expectedCount, expectedCount > 0, expectedCount <= maximumImages else {
            throw EngineError.decodeFailed("The gallery download is incomplete")
        }
        for file in files {
            try Task.checkCancellation()
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                imageExtensions.contains(file.pathExtension.lowercased())
            else { throw EngineError.decodeFailed("The gallery produced an unexpected file") }
            try await OutputVerifier.verify(StagedFile(url: file, name: file.lastPathComponent, check: .image))
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func invoke(_ arguments: [String], directory: URL, captureOutput: Bool = true) async throws
        -> MediaToolResult
    {
        let filter = "extension in (" + Self.imageExtensions.map { "'" + $0 + "'" }.joined(separator: ",") + ")"
        return try await MediaToolProcess().run(
            executable: tools.python,
            arguments: [
                "-I", "-B", "-m", "gallery_dl", "--config-ignore", "--no-input", "--no-postprocessors",
                "--no-colors", "--retries", "2", "--http-timeout", "30", "--cache-file", ":memory:",
                "--range", "1-\(Self.maximumImages + 1)", "--child-range", "1-\(Self.maximumImages + 1)",
                "--post-range", "1-\(Self.maximumImages + 1)",
                "--filter", filter, "--restrict-filenames", "windows", "-o", "downloader.ytdl.enabled=false",
                "-o", "extractor.netrc=false",
            ] + arguments,
            directory: directory, tools: tools, captureOutput: captureOutput)
    }

    private struct Record: Decodable {
        let kind: Int
        let address: String?
        let attributes: Attributes?

        init(from decoder: any Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            kind = try fields.decode(Int.self)
            if kind == 3 || kind == 6 {
                address = try fields.decode(String.self)
                attributes = try fields.decode(Attributes.self)
            } else {
                address = nil
                attributes = kind == 2 ? try fields.decode(Attributes.self) : nil
            }
        }
    }

    private struct Attributes: Decodable {
        let title: String?
        let suffix: String?

        enum CodingKeys: String, CodingKey {
            case title
            case suffix = "extension"
        }
    }
}
