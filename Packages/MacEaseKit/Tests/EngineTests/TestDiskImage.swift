import Darwin
import Foundation
import Synchronization

final class TestDiskImage: Sendable {
    static let familyPrefix = "MacEaseTests-Engine-"
    static let staleAge: TimeInterval = 15 * 60
    static let defaultLockURL = FileManager.default.temporaryDirectory.appending(
        path: "MacEaseTests-Engine-images.lock")
    private static let lockTimeout: TimeInterval = 90
    private static let lockPollInterval: TimeInterval = 0.05
    private static let detachBusyRetries = 5
    private static let detachBackoffStep: TimeInterval = 0.2
    private static let busyExitStatus: Int32 = 16
    private static let commandTimeout: TimeInterval = 60
    private static let terminationTimeout: TimeInterval = 5
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    private static let exitState = Mutex(ExitState())
    private static let capability = Mutex<Result<Bool, any Error>?>(nil)

    private struct ExitState {
        var roots: Set<URL> = []
        var installed = false
    }

    private struct Snapshot: Decodable {
        let images: [Image]

        struct Image: Decodable {
            let imagePath: String?
            let entities: [Entity]?

            enum CodingKeys: String, CodingKey {
                case imagePath = "image-path"
                case entities = "system-entities"
            }
        }

        struct Entity: Decodable {
            let device: String?

            enum CodingKeys: String, CodingKey {
                case device = "dev-entry"
            }
        }
    }

    private struct CommandFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let exitStatus: Int32?
        let diagnostic: String

        var description: String { "hdiutil \(arguments.joined(separator: " ")): \(diagnostic)" }
    }

    let directory: URL
    let mount: URL
    private let image: URL
    private let closed = Mutex(false)

    init(
        filesystem: String = "APFS", lockTimeout: TimeInterval = TestDiskImage.lockTimeout,
        lockURL: URL = TestDiskImage.defaultLockURL
    ) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "\(Self.familyPrefix)\(getpid())-\(UUID().uuidString)")
        mount = directory.appending(path: "mount")
        image = directory.appending(path: "volume.sparseimage")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        Self.register(directory)
        do {
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            let deadline = Date().addingTimeInterval(lockTimeout)
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
                Thread.sleep(forTimeInterval: Self.lockPollInterval)
            }
            try Self.removeStale(using: directory)
            let label = "MACEASE\(UUID().uuidString.prefix(4))"
            _ = try Self.run(
                [
                    "create", "-size", "512m", "-fs", filesystem, "-type", "SPARSE", "-volname", label,
                    image.path,
                ], in: directory)
            try attach()
        } catch {
            let creationFailure = error
            do { try Self.clean(directory) } catch {
                Self.log(creationFailure)
                throw error
            }
            throw creationFailure
        }
    }

    deinit {
        do { try close() } catch { Self.log(error) }
    }

    static func probe() throws -> Bool {
        try capability.withLock { cached in
            if let cached { return try cached.get() }
            let result = Result {
                let volume: TestDiskImage
                do {
                    volume = try TestDiskImage()
                } catch let failure as CommandFailure
                    where failure.arguments.first == "create" && failure.exitStatus != nil
                {
                    log(failure)
                    return false
                }
                try volume.close()
                return true
            }
            cached = result
            return try result.get()
        }
    }

    func attach(readOnly: Bool = false) throws {
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let options = readOnly ? ["-readonly"] : []
        _ = try Self.run(
            ["attach", "-nobrowse", "-noautoopen"] + options + ["-mountpoint", mount.path, image.path], in: directory)
    }

    func unmount() throws {
        try Self.detachTarget(mount.path, in: directory, forceOnBusy: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    }

    func close() throws {
        try closed.withLock { closed in
            guard !closed else { return }
            try Self.clean(directory)
            closed = true
        }
    }

    static func removeStale(using directory: URL) throws {
        let snapshot = try snapshot(in: directory)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        for attached in snapshot.images {
            guard let path = attached.imagePath else { continue }
            let backing = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let root = backing.deletingLastPathComponent()
            guard backing.lastPathComponent == "volume.sparseimage",
                root.deletingLastPathComponent() == temporary,
                let owner = owner(of: root), owner != getpid(),
                kill(owner, 0) != 0, errno == ESRCH
            else { continue }
            let created: Date?
            do { created = try root.resourceValues(forKeys: [.creationDateKey]).creationDate } catch let error
                as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
            { continue } catch let error as POSIXError where error.code == .ENOENT {
                continue
            }
            guard let created, Date().timeIntervalSince(created) >= staleAge else { continue }
            do {
                try detach(attached, in: directory, forceOnBusy: false)
            } catch { log(error) }
        }
    }

    private static func owner(of root: URL) -> pid_t? {
        guard root.lastPathComponent.hasPrefix(familyPrefix) else { return nil }
        let suffix = root.lastPathComponent.dropFirst(familyPrefix.count)
        guard let digits = suffix.split(separator: "-").first, let owner = pid_t(digits), owner > 0 else { return nil }
        return owner
    }

    private static func register(_ root: URL) {
        let install = exitState.withLock { state in
            state.roots.insert(root)
            guard !state.installed else { return false }
            state.installed = true
            return true
        }
        if install {
            atexit {
                for root in TestDiskImage.exitState.withLock({ $0.roots })
                where TestDiskImage.owner(of: root) == getpid() {
                    do { try TestDiskImage.clean(root) } catch { TestDiskImage.log(error) }
                }
            }
        }
    }

    private static func clean(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            exitState.withLock { _ = $0.roots.remove(root) }
            return
        }
        let backing = root.appending(path: "volume.sparseimage").resolvingSymlinksInPath()
        let attached = try snapshot(in: root).images.first {
            $0.imagePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == backing } == true
        }
        if let attached { try detach(attached, in: root, forceOnBusy: true) }
        try FileManager.default.removeItem(at: root)
        exitState.withLock { _ = $0.roots.remove(root) }
    }

    private static func detach(_ attached: Snapshot.Image, in directory: URL, forceOnBusy: Bool) throws {
        guard let device = attached.entities?.compactMap(\.device).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try detachTarget(device, in: directory, forceOnBusy: forceOnBusy)
    }

    private static func isBusyDetach(_ failure: CommandFailure) -> Bool {
        failure.exitStatus == busyExitStatus
            || failure.diagnostic.localizedCaseInsensitiveContains("busy")
    }

    private static func detachTarget(_ target: String, in directory: URL, forceOnBusy: Bool) throws {
        var attempt = 0
        while true {
            do {
                _ = try run(["detach", target], in: directory)
                return
            } catch let failure as CommandFailure where isBusyDetach(failure) {
                attempt += 1
                if attempt <= detachBusyRetries {
                    Thread.sleep(forTimeInterval: detachBackoffStep * Double(attempt))
                    continue
                }
                guard forceOnBusy else { throw failure }
                _ = try run(["detach", "-force", target], in: directory)
                return
            }
        }
    }

    private static func snapshot(in directory: URL) throws -> Snapshot {
        try PropertyListDecoder().decode(Snapshot.self, from: run(["info", "-plist"], in: directory))
    }

    private static func run(_ arguments: [String], in directory: URL) throws -> Data {
        let token = UUID().uuidString
        let output = directory.appending(path: "\(token).stdout")
        let diagnostic = directory.appending(path: "\(token).stderr")
        for url in [output, diagnostic] {
            guard
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let stdout = try FileHandle(forWritingTo: output)
        defer { stdout.closeFile() }
        let stderr = try FileHandle(forWritingTo: diagnostic)
        defer { stderr.closeFile() }
        let completed = DispatchSemaphore(value: 0)
        let command = Process()
        command.executableURL = hdiutil
        command.arguments = arguments
        command.standardOutput = stdout
        command.standardError = stderr
        command.terminationHandler = { _ in completed.signal() }
        try command.run()
        if completed.wait(timeout: .now() + commandTimeout) == .timedOut {
            command.terminate()
            if completed.wait(timeout: .now() + terminationTimeout) == .timedOut {
                guard Darwin.kill(command.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            throw CommandFailure(arguments: arguments, exitStatus: nil, diagnostic: "timed out")
        }
        guard command.terminationReason == .exit, command.terminationStatus == 0 else {
            throw CommandFailure(
                arguments: arguments,
                exitStatus: command.terminationReason == .exit ? command.terminationStatus : nil,
                diagnostic: String(decoding: try Data(contentsOf: diagnostic), as: UTF8.self))
        }
        return try Data(contentsOf: output)
    }

    private static func log(_ error: any Error) {
        FileHandle.standardError.write(Data("Test disk-image cleanup: \(error)\n".utf8))
    }
}
