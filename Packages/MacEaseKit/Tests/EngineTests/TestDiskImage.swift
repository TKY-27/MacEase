import Darwin
import Foundation
import Synchronization

final class TestDiskImage: Sendable {
    static let familyPrefix = "MacEaseTests-Engine-"
    static let staleAge: TimeInterval = 15 * 60
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

    init(filesystem: String = "APFS") throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "\(Self.familyPrefix)\(getpid())-\(UUID().uuidString)")
        mount = directory.appending(path: "mount")
        image = directory.appending(path: "volume.sparseimage")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        Self.register(directory)
        do {
            let lock = FileManager.default.temporaryDirectory.appending(path: "MacEaseTests-Engine-images.lock")
            let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

    func attach() throws {
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try Self.run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path], in: directory)
    }

    func unmount() throws {
        _ = try Self.run(["detach", mount.path], in: directory)
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
            let created = try root.resourceValues(forKeys: [.creationDateKey]).creationDate
            guard let created, Date().timeIntervalSince(created) >= staleAge else { continue }
            do {
                try detach(attached, in: directory)
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
        if let attached { try detach(attached, in: root) }
        try FileManager.default.removeItem(at: root)
        exitState.withLock { _ = $0.roots.remove(root) }
    }

    private static func detach(_ attached: Snapshot.Image, in directory: URL) throws {
        guard let device = attached.entities?.compactMap(\.device).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try run(["detach", device], in: directory)
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
