import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Engine

@Suite(.serialized) struct RelatedFilesTests {
    @Test func findsExactContentAndExcludesSourceAndDifferentBytes() throws {
        let root = try TestVolume.makeFolder()
        let source = root.appending(path: "source.bin")
        try Data("same bytes".utf8).write(to: source)
        try Data("same bytes".utf8).write(to: root.appending(path: "copy.bin"))
        try Data("other bytes".utf8).write(to: root.appending(path: "different.bin"))

        let report = try RelatedFilesScanner.scan(source: source)

        #expect(report.matches.count == 1)
        #expect(report.matches.first?.url.lastPathComponent == "copy.bin")
        guard case .exact? = report.matches.first?.kind else {
            Issue.record("expected an exact-content match")
            return
        }
    }

    @Test func scansOnlyChosenFolderAndSkipsHiddenAndPackageDescendants() throws {
        let root = try TestVolume.makeFolder()
        let chosen = root.appending(path: "chosen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let source = chosen.appending(path: "source")
        try Data("match".utf8).write(to: source)
        try Data("match".utf8).write(to: chosen.appending(path: "copy"))
        try Data("match".utf8).write(to: root.appending(path: "outside"))
        try Data("match".utf8).write(to: chosen.appending(path: ".hidden"))
        let package = chosen.appending(path: "Example.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("match".utf8).write(to: package.appending(path: "payload"))
        try FileManager.default.createSymbolicLink(at: chosen.appending(path: "linked"), withDestinationURL: root)

        let report = try RelatedFilesScanner.scan(source: source, in: chosen)

        #expect(report.matches.map { $0.url.lastPathComponent } == ["copy"])
    }

    @Test func distinguishesPhotographicNearMatchFromIndependentScene() throws {
        let root = try TestVolume.makeFolder()
        let source = try makeImage(in: root, name: "source.png", seed: 1)
        let near = try makeImage(in: root, name: "near.png", seed: 1, tint: true)
        _ = try makeImage(in: root, name: "distinct.png", seed: 9)

        let report = try RelatedFilesScanner.scan(source: source)

        #expect(
            report.matches.contains {
                $0.url.standardizedFileURL == near.standardizedFileURL && isSimilar($0.kind)
            })
        #expect(!report.matches.contains { $0.url.lastPathComponent == "distinct.png" })
    }

    private func isSimilar(_ kind: RelatedFileKind) -> Bool {
        if case .visuallySimilar = kind { return true }
        return false
    }

    private func makeImage(in folder: URL, name: String, seed: UInt32, tint: Bool = false) throws -> URL {
        let url = folder.appending(path: name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let background =
            seed == 1
            ? CGColor(red: 0.1, green: 0.35, blue: 0.7, alpha: 1) : CGColor(red: 0.9, green: 0.1, blue: 0.15, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        context.setFillColor(CGColor(red: tint ? 0.88 : 0.9, green: tint ? 0.82 : 0.8, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 24, y: 24, width: seed == 1 ? 48 : 20, height: seed == 1 ? 48 : 20))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }
}
