import Darwin
import Foundation

@MainActor
final class OrganizationWatcher {
    private let source: any DispatchSourceFileSystemObject

    init(root: URL, changed: @escaping @MainActor @Sendable () -> Void) throws {
        let descriptor = open(root.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke], queue: .main)
        source.setEventHandler { Task { @MainActor in changed() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }
}
