import Foundation
import Testing

@testable import Engine

@Suite struct DuplicateScannerTests {
    @Test func largeEmptyGroupKeepsEveryPathInOrder() throws {
        let root = try TestVolume.makeFolder()
        let files = (0..<1_024).map { root.appending(path: "copy-\($0)") }
        for file in files { try Data().write(to: file) }
        var settings = FolderSettings()
        settings.duplicatesIgnoreEmpty = false

        let groups = try DuplicateScanner.groups(in: [root, root], settings: settings) { _ in }

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.files == files.sorted { $0.path < $1.path })
        #expect(group.bytesPerFile == 0)
        #expect(group.reclaimableBytes == 0)
    }

    @Test func changedFilesSplitIntoByteIdenticalGroupsAfterHashing() throws {
        let root = try TestVolume.makeFolder()
        let files = ["a", "b", "c", "d", "e", "f"].map { root.appending(path: $0) }
        for file in files { try Data("equal".utf8).write(to: file) }
        var changed = false
        var mutationError: (any Error)?

        let groups = try DuplicateScanner.groups(in: [root], settings: FolderSettings()) { fraction in
            guard fraction == 1, !changed else { return }
            changed = true
            do {
                for index in [1, 3] { try Data("other".utf8).write(to: files[index]) }
                try Data("alone".utf8).write(to: files[5])
            } catch {
                mutationError = error
            }
        }

        if let mutationError { throw mutationError }
        #expect(changed)
        #expect(groups.map(\.files) == [[files[0], files[2], files[4]], [files[1], files[3]]])
        #expect(groups.map(\.reclaimableBytes) == [10, 5])
        #expect(try Data(contentsOf: files[5]) == Data("alone".utf8))
    }
}
