import Foundation
import ImageIO
import Testing

@testable import Engine
@testable import Formats

@Suite struct ArchiveExtractionRefusalTests {
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp").appending(path: "archive-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        TestTemporaryFolders.register(folder)
        return folder
    }

    @Test(arguments: ["txt", "png"])
    func plainFilesAreUnsupportedAndNeverCopied(_ extensionName: String) throws {
        let root = try folder()
        let source = root.appending(path: "plain.\(extensionName)")
        if extensionName == "txt" {
            try Data("plain non-archive text".utf8).write(to: source)
        } else {
            let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l1sAAAAASUVORK5CYII="
            try #require(Data(base64Encoded: encoded)).write(to: source)
            let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
            #expect(CGImageSourceGetCount(image) == 1)
        }
        let original = try Data(contentsOf: source)
        let output = root.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        #expect(throws: FormatError.unsupportedArchive) {
            try ArchiveExtractor.extract(source, into: output, rawName: source.lastPathComponent, password: nil) { _ in
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(
            EngineError.wrapping(FormatError.unsupportedArchive, path: source.path)
                == .invalidInput(.unsupportedArchive))
    }

    @Test func wrappedZIPHasAnAccurateRefusalWithoutOutput() throws {
        let root = try folder()
        let source = root.appending(path: "bundle.zip.gz")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c",
            "import gzip, io, pathlib, sys, zipfile\nbuffer = io.BytesIO()\nwith zipfile.ZipFile(buffer, 'w') as archive:\n    archive.writestr('file.txt', b'payload')\npathlib.Path(sys.argv[1]).write_bytes(gzip.compress(buffer.getvalue()))",
            source.path,
        ]
        try python.run()
        python.waitUntilExit()
        try #require(python.terminationStatus == 0)
        let original = try Data(contentsOf: source)
        let output = root.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        #expect(throws: ArchiveError.wrappedZIPContainer) {
            try ArchiveExtractor.extract(source, into: output, rawName: "bundle.zip", password: nil) { _ in }
        }
        #expect(throws: ArchiveError.wrappedZIPContainer) { try ArchiveNameInspection.inspect(source) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(
            EngineError.wrapping(ArchiveError.wrappedZIPContainer, path: source.path)
                == .invalidInput(.wrappedZIPArchive))
    }
}
