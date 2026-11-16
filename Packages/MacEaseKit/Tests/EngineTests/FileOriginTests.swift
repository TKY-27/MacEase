import Foundation
import Testing

@testable import Engine

@Suite struct FileOriginTests {
    @Test func recordsOriginWithoutChangingFileContents() throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: source)
        let link = try #require(URL(string: "https://example.com/gallery"))
        try FileOrigin.record(link, onStagedFile: source)
        let attribute = try FinderAttributes.extendedAttribute("com.apple.metadata:kMDItemWhereFroms", of: source)
        let encoded = try #require(attribute)
        let links = try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String]
        #expect(links == [link.absoluteString])
        #expect(try String(contentsOf: source, encoding: .utf8) == "hello")
    }
}
