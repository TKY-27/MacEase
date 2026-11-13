import Darwin
import Foundation
import Testing

@testable import Engine

@Suite struct FileOriginTests {
    @Test func readsStoredOriginWithoutChangingFileContents() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: source)
        let link = "https://example.com/gallery"
        let encoded = try PropertyListSerialization.data(fromPropertyList: [link], format: .binary, options: 0)
        let result = encoded.withUnsafeBytes {
            setxattr(source.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0)
        }
        try #require(result == 0)
        let origin = try FileOrigin.inspect(source)
        #expect(origin.links.map(\.absoluteString) == [link])
        #expect(origin.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(try String(contentsOf: source, encoding: .utf8) == "hello")
    }

    @Test func galleryRecordAppliesOnlyToNamedFiles() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "listed.txt")
        let other = folder.appending(path: "unlisted.txt")
        for file in [source, other] { try Data("hello".utf8).write(to: file) }
        let record =
            #"{"source":"https://example.com/gallery","retrieved":"2026-11-05T00:00:00Z","tool":"gallery-dl","files":["listed.txt"]}"#
        try Data(record.utf8).write(to: folder.appending(path: GalleryProvenance.filename))
        #expect(try FileOrigin.inspect(source).links.map(\.absoluteString) == ["https://example.com/gallery"])
        #expect(try FileOrigin.inspect(other).links.isEmpty)
        try Data(record.replacingOccurrences(of: "https://example.com/gallery", with: "file:///etc/passwd").utf8)
            .write(to: folder.appending(path: GalleryProvenance.filename))
        #expect(throws: EngineError.self) { try FileOrigin.inspect(source) }
    }
}
