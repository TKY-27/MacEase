import Foundation
import Testing

@testable import Formats

@Suite struct ArchiveListingTests {
    @Test func acceptsARealZipAndRejectsGarbage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "archive-\(UUID().uuidString)")
        let content = folder.appending(path: "content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: content.appending(path: "a.txt"))
        let zip = folder.appending(path: "a.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        try ArchiveListing.verify(zip)
        let garbage = folder.appending(path: "bad.zip")
        try Data("not an archive".utf8).write(to: garbage)
        #expect(throws: FormatError.self) { try ArchiveListing.verify(garbage) }
    }
}
