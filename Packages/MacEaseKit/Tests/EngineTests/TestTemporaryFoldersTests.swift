import Darwin
import Foundation
import Testing

@Suite struct TestTemporaryFoldersTests {
    @Test func registeredSupportFoldersAreRemovedWhenTheTestProcessExits() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "MacEaseCleanup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            TestTemporaryFolders.register(directory)
            TestTemporaryFolders.register(directory)
            try Data("support".utf8).write(to: directory.appending(path: "settings.json"))
            FileHandle.standardOutput.write(Data(directory.path.utf8))
            exit(EXIT_SUCCESS)
        }
        let path = String(decoding: result.standardOutputContent, as: UTF8.self)
        try #require(!path.isEmpty)
        defer {
            if FileManager.default.fileExists(atPath: path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(atPath: path) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
