import CoreGraphics
import CryptoKit
import Engine
import Formats
import Foundation
import ImageIO
import MenuCatalog
import UniformTypeIdentifiers

enum FeatureBenchmarks {
    private static let archiveBytes = 128 * 1_024 * 1_024
    private static let metadataEntries = 1_024
    private static let selectedText = Data("MacEase selected preview fixture.\n".utf8)

    private struct Measurement: Encodable {
        let operation: String
        var seconds: Double = 0
        var previewSeconds: Double? = nil
        var closeSeconds: Double? = nil
        var count: Int = 1
        var bytes: Int = 0
        var sha256: String = ""
        var colors: Int? = nil
        var detail: String? = nil
        var width: Int? = nil
        var height: Int? = nil
        var warnings: Int = 0
        var errors: Int = 0
    }

    static func run(_ arguments: [String]) async throws {
        #if DEBUG
            throw BenchError(description: "Feature benchmarks require a Release build")
        #else
            guard arguments.count >= 2 else { throw BenchError(description: "Missing feature benchmark path") }
            let source = URL(fileURLWithPath: arguments[1])
            switch arguments[0] {
            case "feature.fixtures":
                guard arguments.count == 2 else { throw BenchError(description: "Expected fixture directory") }
                try fixtures(at: source)
            case "feature.svg":
                guard arguments.count == 4, let colors = Int(arguments[2]),
                    let detail = SVGTraceDetail(rawValue: arguments[3])
                else { throw BenchError(description: "Expected PNG path, color count and less/standard/fine") }
                try await svg(source, options: SVGTraceOptions(colors: colors, detail: detail))
            case "feature.zip":
                guard arguments.count == 3 else { throw BenchError(description: "Expected ZIP path and selected path") }
                try await archive(source, selectedPath: arguments[2])
            case "feature.zip.export":
                guard arguments.count == 3 else { throw BenchError(description: "Expected ZIP path and member prefix") }
                try await archiveExport(source, prefix: arguments[2])
            default:
                throw BenchError(description: "Unknown feature benchmark")
            }
        #endif
    }

    private static func svg(_ source: URL, options: SVGTraceOptions) async throws {
        let start = ContinuousClock.now
        let prepared = try await SVGTrace.prepare(source, options: options, settings: Settings())
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        guard let content = String(data: prepared.svg, encoding: .utf8),
            content.contains("<path"), !content.contains("<image")
        else { throw BenchError(description: "SVG preparation produced no vector paths") }
        var result = Measurement(operation: "svg.prepare")
        result.seconds = elapsed
        result.bytes = prepared.svg.count
        result.sha256 = digest(prepared.svg)
        result.colors = options.colors
        result.detail = options.detail.rawValue
        result.width = prepared.width
        result.height = prepared.height
        result.warnings = prepared.warnings.count
        try printJSON(result)
    }

    private static func archive(_ source: URL, selectedPath: String) async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseFeatureBench-\(UUID())")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: support) }
        let session = ArchiveBrowserSession(source: source, staging: StagingArea(supportDirectory: support))
        do {
            let start = ContinuousClock.now
            let entries = try await session.entries()
            let listed = ContinuousClock.now
            guard try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty else {
                throw BenchError(description: "Listing materialized archive content")
            }
            guard let selected = entries.first(where: { $0.path == selectedPath && !$0.isDirectory }) else {
                throw BenchError(description: "Selected member is missing")
            }
            let previewStart = ContinuousClock.now
            let preview = try await session.preview(entryID: selected.id, password: nil)
            let previewed = ContinuousClock.now
            let bytes = try Data(contentsOf: preview)
            guard Int64(bytes.count) == selected.size else { throw BenchError(description: "Preview size differs") }
            let staged = try FileManager.default.contentsOfDirectory(
                at: preview.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            guard staged.map({ $0.resolvingSymlinksInPath() }) == [preview.resolvingSymlinksInPath()] else {
                throw BenchError(description: "Unselected members were staged")
            }
            let closeStart = ContinuousClock.now
            await session.close()
            let closed = ContinuousClock.now
            guard !FileManager.default.fileExists(atPath: preview.deletingLastPathComponent().path) else {
                throw BenchError(description: "Closing retained the preview directory")
            }
            do {
                _ = try await session.entries()
                throw BenchError(description: "Closed session accepted listing")
            } catch ArchiveBrowserError.closed {}
            var result = Measurement(operation: "zip.list-preview-close")
            result.seconds = (listed - start) / .seconds(1)
            result.previewSeconds = (previewed - previewStart) / .seconds(1)
            result.closeSeconds = (closed - closeStart) / .seconds(1)
            result.count = entries.count
            result.bytes = bytes.count
            result.sha256 = digest(bytes)
            try printJSON(result)
        } catch {
            await session.close()
            throw error
        }
    }

    private static func archiveExport(_ source: URL, prefix: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseExportBench-\(UUID())")
        let destination = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        do {
            let entries = try await session.entries().filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
            guard !entries.isEmpty else { throw BenchError(description: "No selected members") }
            let start = ContinuousClock.now
            let batch = try await session.batch(
                entryIDs: Set(entries.map(\.id)), password: nil, to: destination,
                operation: .archiveBrowse, exportsFolder: true)
            let outcome = await engine.run(batch, settings: Settings()) { _ in }
            let elapsed = (ContinuousClock.now - start) / .seconds(1)
            guard case .succeeded(let outputs, _) = outcome.outcomes.first, outputs.count == 1,
                let output = outputs.first, !outcome.historyFailed
            else { throw BenchError(description: "Selective export failed") }
            for entry in entries {
                let size = try output.appending(path: entry.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size.map(Int64.init) == entry.size else { throw BenchError(description: "Export size differs") }
            }
            let paths = try FileManager.default.subpathsOfDirectory(atPath: output.path)
            let expectedPaths = Set(
                entries.flatMap { entry in
                    let parts = entry.path.split(separator: "/")
                    return (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
                })
            guard Set(paths) == expectedPaths else { throw BenchError(description: "Export selection differs") }
            await session.close()
            var result = Measurement(operation: "zip.export")
            result.seconds = elapsed
            result.count = entries.count
            result.bytes = entries.reduce(0) { $0 + Int($1.size ?? 0) }
            try printJSON(result)
        } catch {
            await session.close()
            throw error
        }
    }

    private static func fixtures(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try image(at: directory.appending(path: "logo.png"), side: 256, shapes: false)
        try image(at: directory.appending(path: "shapes.png"), side: 1_024, shapes: true)
        let members = directory.appending(path: "members", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: members, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: members) }
        let large = members.appending(path: "large-unselected.bin")
        try Data().write(to: large)
        let writer = try FileHandle(forWritingTo: large)
        do {
            try writer.truncate(atOffset: UInt64(archiveBytes))
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
        try selectedText.write(to: members.appending(path: "selected.txt"))
        var names = ["large-unselected.bin", "selected.txt"]
        for index in 0..<metadataEntries {
            let name = String(format: "metadata-%04d.txt", index)
            try Data().write(to: members.appending(path: name))
            names.append(name)
        }
        let fixtureDate = Date(timeIntervalSince1970: 315_532_800)
        for name in names {
            try FileManager.default.setAttributes(
                [.modificationDate: fixtureDate], ofItemAtPath: members.appending(path: name).path)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = members
        zip.arguments = ["-q", "-0", "-X", directory.appending(path: "browser.zip").path] + names
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw BenchError(description: "ZIP fixture generation failed") }
        let entries = try ArchiveBrowserZIP.list(directory.appending(path: "browser.zip"))
        guard entries.count == names.count, entries.first?.size == Int64(archiveBytes) else {
            throw BenchError(description: "ZIP fixture validation failed")
        }
        print("Fixtures: logo.png 256x256, shapes.png 1024x1024, browser.zip \(entries.count) entries")
    }

    private static func image(at output: URL, side: Int, shapes: Bool) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw BenchError(description: "PNG fixture context unavailable") }
        context.setShouldAntialias(false)
        let unit = CGFloat(side) / 16
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.08, green: 0.19, blue: 0.31, alpha: 1))
        context.fillEllipse(in: CGRect(x: unit, y: unit, width: unit * 14, height: unit * 14))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: unit * 4, y: unit * 4, width: unit * 3, height: unit * 8))
        context.fill(CGRect(x: unit * 9, y: unit * 4, width: unit * 3, height: unit * 8))
        if shapes {
            context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.05, alpha: 1))
            for row in 0..<8 {
                for column in 0..<8 {
                    context.fillEllipse(
                        in: CGRect(x: CGFloat(column) * unit * 2, y: CGFloat(row) * unit * 2, width: unit, height: unit)
                    )
                }
            }
        }
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw BenchError(description: "PNG fixture encoder unavailable") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BenchError(description: "PNG fixture write failed") }
        print("Fixture: \(output.lastPathComponent) sha256=\(digest(try Data(contentsOf: output)))")
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func printJSON(_ result: Measurement) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(result)
        guard let line = String(data: encoded, encoding: .utf8) else {
            throw BenchError(description: "Benchmark JSON encoding failed")
        }
        print(line)
        fflush(stdout)
    }
}
