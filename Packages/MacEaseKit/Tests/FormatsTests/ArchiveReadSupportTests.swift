import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite struct ArchiveReadSupportTests {
    @Test func externalCompressionIsRefusedBareAndInsideGzip() throws {
        let folder = URL(fileURLWithPath: "/private/tmp").appending(
            path: "archive-filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        TestTemporaryFolders.register(folder)
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c",
            """
            import gzip, pathlib, sys
            root = pathlib.Path(sys.argv[1])
            signatures = {
                'lz4': bytes.fromhex('04 22 4d 18 60 40 82'),
                'lz4-legacy': bytes.fromhex('02 21 4c 18'),
                'lzop': bytes.fromhex('89 4c 5a 4f 00 0d 0a 1a 0a'),
                'lrzip': bytes.fromhex('4c 52 5a 49 00 06'),
                'grzip': bytes.fromhex('47 52 5a 69 70 49 49 00 02 04 3a 29'),
            }
            for name, signature in signatures.items():
                payload = signature + bytes(64)
                (root / name).write_bytes(payload)
                (root / (name + '.gz')).write_bytes(gzip.compress(payload))
            """, folder.path,
        ]
        try python.run()
        python.waitUntilExit()
        try #require(python.terminationStatus == 0)
        for source in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let output = folder.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            #expect(throws: FormatError.self) {
                try ArchiveExtractor.extract(source, into: output, rawName: "payload", password: nil) { _ in }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            #expect(throws: FormatError.self) { try ArchiveListing.verify(source) }
            let document = folder.appending(path: "\(UUID().uuidString).docx")
            try FileManager.default.copyItem(at: source, to: document)
            #expect(throws: EngineError.decodeFailed("Document archive cannot be opened")) {
                try AttributedDocument.convert(document, toPDF: false)
            }
        }
    }

    @Test func tarZstdRetainsInProcessExtractionAndVerification() throws {
        let folder = URL(fileURLWithPath: "/private/tmp").appending(
            path: "archive-zstd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        TestTemporaryFolders.register(folder)
        let payload = folder.appending(path: "payload.txt")
        try Data("archive codec fixture".utf8).write(to: payload)
        let source = folder.appending(path: "sample.tar.zst")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--zstd", "-cf", source.path, "-C", folder.path, payload.lastPathComponent]
        try tar.run()
        tar.waitUntilExit()
        try #require(tar.terminationStatus == 0)
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try ArchiveListing.verify(source)
        let layout = try ArchiveExtractor.extract(source, into: output, rawName: "sample", password: nil) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: "payload.txt")) == Data("archive codec fixture".utf8))
    }

    @Test func mtreeCannotReadFilesOutsideAnArchive() throws {
        let folder = URL(fileURLWithPath: "/private/tmp").appending(
            path: "archive-mtree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        TestTemporaryFolders.register(folder)
        let source = folder.appending(path: "external.mtree")
        try Data("#mtree\nexternal type=file contents=/etc/hosts\n".utf8).write(to: source)
        #expect(throws: FormatError.self) { try ArchiveListing.verify(source) }
        #expect(throws: FormatError.self) {
            try ArchiveExtractor.extract(source, into: folder, rawName: "external", password: nil) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "external").path))
    }

    @Test(arguments: [4, 5])
    func libarchiveRARFixturesKeepTheirNamesAndContents(_ version: Int) throws {
        let encoded: String
        let name: String
        let expected: String
        if version == 4 {
            encoded =
                "UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dto+t3baPnRlc3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3faPhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQgZG9jdW1lbnQNCqHIdOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAAAAAAAAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA"
            name = "test.txt"
            expected = "test text document\r\n"
        } else {
            encoded =
                "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAA4MAZjLAIDC50ABJ0ApIMCtEOglYAAAQ5oZWxsb3dvcmxkLnR4dAoDE34Oq1tW6Q4aaGVsbG8gbGliYXJjaGl2ZSB0ZXN0IHN1aXRlIQodd1ZRAwUEAA=="
            name = "helloworld.txt"
            expected = "hello libarchive test suite!\n"
        }
        let folder = URL(fileURLWithPath: "/private/tmp").appending(path: "archive-rar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        TestTemporaryFolders.register(folder)
        let source = folder.appending(path: "sample.rar")
        try #require(Data(base64Encoded: encoded)).write(to: source)
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try ArchiveListing.verify(source)
        let layout = try ArchiveExtractor.extract(source, into: output, rawName: "sample", password: nil) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: output.appending(path: name)) == Data(expected.utf8))
    }

}
