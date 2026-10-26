import Darwin
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine
@testable import Formats

@Suite(.serialized) struct SVGTraceTests {
    @Test func previewBytesExportWithCollisionAndUndo() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [ImageFixtures.disc(size: 80, background: nil)], as: .png,
            to: folder.appending(path: "logo.png"))
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = .replace
        settings.image.svgMode = .embeddedPNG
        let result = try await SVGTrace.prepare(source, options: SVGTraceOptions(colors: 2), settings: settings)
        #expect(result.settings.outputMode == .newFile)
        #expect(result.settings.image.svgMode == .trace)
        #expect(result.width == 80 && result.height == 80)
        #expect(result.sourceImage.width == 80)
        #expect(result.warnings.contains(.imageTransparencyFlattened))
        #expect(String(decoding: result.svg, as: UTF8.self).contains("<path"))
        let rendered = try await SVGRenderer.render(result.svg)
        #expect(rendered.width == 80 && rendered.height == 80)
        let destination = folder.appending(path: "logo.svg")
        try Data("occupied".utf8).write(to: destination)
        let engine = try ImageFixtures.engine()
        let outcome = await engine.run(
            result.batch(to: destination, operation: .imageConvert), settings: result.settings
        ) { _ in }
        let output = try ImageFixtures.output(of: outcome)
        #expect(output.lastPathComponent == "logo (2).svg")
        #expect(try Data(contentsOf: output) == result.svg)
        #expect(try Data(contentsOf: destination) == Data("occupied".utf8))
        #expect(try Data(contentsOf: source) == original)
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: result.warnings)])
        _ = try await engine.undo(outcome.batchID)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func changedSourceCannotExportPreparedBytes() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [ImageFixtures.disc(size: 48)], as: .png, to: folder.appending(path: "mark.png"))
        let result = try await SVGTrace.prepare(source, options: SVGTraceOptions(colors: 1), settings: Settings())
        try Data("changed".utf8).write(to: source)
        let destination = folder.appending(path: "mark.svg")
        let engine = try ImageFixtures.engine()
        let outcome = await engine.run(
            result.batch(to: destination, operation: .imageConvert), settings: result.settings
        ) { _ in }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func pngMetadataLossIsReportedWithoutChangingSource() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "tagged.png")
        let metadata = CGImageMetadataCreateMutable()
        try #require(
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel, "Trace Lens" as CFString))
        let writer = try #require(
            CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(writer, try ImageFixtures.disc(size: 32), metadata, nil)
        try #require(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let result = try await SVGTrace.prepare(source, options: SVGTraceOptions(colors: 1), settings: Settings())
        #expect(result.warnings == [.imageMetadataDropped([.exif])])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func malformedAndAnimatedInputsAreRejected() async throws {
        let folder = try TestVolume.makeFolder()
        let malformed = folder.appending(path: "broken.png")
        try Data("not a PNG".utf8).write(to: malformed)
        await #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try await SVGTrace.prepare(malformed, options: SVGTraceOptions(colors: 1), settings: Settings())
        }
        await #expect(throws: EngineError.invalidInput(.invalidNumericParameter)) {
            try await SVGTrace.prepare(malformed, options: SVGTraceOptions(colors: 9), settings: Settings())
        }
        let incomplete = try ImageFixtures.write(
            [ImageFixtures.disc(size: 24)], as: .png, to: folder.appending(path: "incomplete.png"))
        let completeBytes = try Data(contentsOf: incomplete)
        try Data(completeBytes.dropLast(12)).write(to: incomplete)
        await #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try await SVGTrace.prepare(incomplete, options: SVGTraceOptions(colors: 1), settings: Settings())
        }
        let animated = try ImageFixtures.write(
            [ImageFixtures.disc(size: 24), ImageFixtures.disc(size: 24)], as: .png,
            to: folder.appending(path: "animated.png"),
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]],
            frameProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]])
        await #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try await SVGTrace.prepare(animated, options: SVGTraceOptions(colors: 1), settings: Settings())
        }
    }

    @Test func singleFrameAPNGIsNotTreatedAsAStill() async throws {
        let folder = try TestVolume.makeFolder()
        let source = try ImageFixtures.write(
            [ImageFixtures.disc(size: 24)], as: .png, to: folder.appending(path: "still.png"))
        let original = try Data(contentsOf: source)
        let chunks = try PNGFile.chunks(in: original)
        let header = try #require(chunks.first)
        let frameControl = Data([
            0, 0, 0, 0, 0, 0, 0, 24, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 10, 0, 0,
        ])
        let animation =
            PNGFile.serialized(PNGChunk(type: "acTL", payload: Data([0, 0, 0, 1, 0, 0, 0, 0])))
            + PNGFile.serialized(PNGChunk(type: "fcTL", payload: frameControl))
        let headerEnd = PNGFile.signature.count + 12 + header.payload.count
        let apng = Data(original.prefix(headerEnd)) + animation + Data(original.dropFirst(headerEnd))
        let animated = folder.appending(path: "single-frame.png")
        try apng.write(to: animated)
        let imageSource = try ImageFixtures.source(animated)
        #expect(CGImageSourceGetCount(imageSource) == 1)
        #expect(CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil)
        await #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try await SVGTrace.prepare(animated, options: SVGTraceOptions(colors: 1), settings: Settings())
        }
    }

    @Test func nonregularInputReturnsWithoutWaitingForAWriter() async throws {
        let folder = try TestVolume.makeFolder()
        let fifo = folder.appending(path: "pipe.png")
        try #require(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        let start = ContinuousClock.now
        await #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try await SVGTrace.prepare(fifo, options: SVGTraceOptions(colors: 1), settings: Settings())
        }
        #expect(start.duration(to: .now) < .seconds(5))
        let symlink = folder.appending(path: "linked.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fifo)
        do {
            _ = try await SVGTrace.prepare(symlink, options: SVGTraceOptions(colors: 1), settings: Settings())
            Issue.record("Symbolic link was accepted")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(ELOOP))
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
