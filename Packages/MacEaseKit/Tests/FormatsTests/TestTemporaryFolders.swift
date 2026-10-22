import Foundation
import Synchronization

enum TestTemporaryFolders {
    private struct State: Sendable {
        var paths: [String] = []
        var cleanupInstalled = false
    }

    private static let state = Mutex(State())

    static func register(_ folder: URL) {
        let installCleanup = state.withLock { state in
            state.paths.append(folder.path)
            guard !state.cleanupInstalled else { return false }
            state.cleanupInstalled = true
            return true
        }
        guard installCleanup else { return }
        atexit { TestTemporaryFolders.cleanUp() }
    }

    private static func cleanUp() {
        let paths = state.withLock { $0.paths }
        for path in paths {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                FileHandle.standardError.write(Data("Failed to remove test folder at \(path): \(error)\n".utf8))
            }
        }
    }
}
