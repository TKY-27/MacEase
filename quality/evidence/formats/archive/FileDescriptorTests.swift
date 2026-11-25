import Foundation
import Testing
@testable import Formats
@Suite struct FileDescriptorTests {
    @Test func failedArchivesReleaseDescriptors() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "archive-fds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source")
        let output = folder.appending(path: "output")
        let before = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
        for _ in 0..<64 {
            try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: source)
            let writer = try FileHandle(forWritingTo: source)
            var changed = false
            var mutationError: (any Error)?
            #expect(throws: FormatError.io("archive source changed: source")) {
                try ArchiveWriter.write([source], to: output, format: .tar, progress: { _ in
                    guard !changed else { return }
                    changed = true
                    do { try writer.truncate(atOffset: 0) } catch { mutationError = error }
                }, skipping: { _ in false })
            }
            try writer.close()
            if let mutationError { throw mutationError }
            try #require(changed)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
        print("Archive FD probe: before=\(before), after=\(after), failures=64")
        #expect(after == before)
    }
}
