import FileProvider
import Foundation
import MenuCatalog
import Synchronization

public struct HatchExtractionSession: Identifiable, Sendable {
    public let id: UUID
    public let input: URL
    public let output: URL
    public let state: String
}

public struct HatchExtractionResult: Sendable {
    public let sessionID: UUID
    public let output: URL
    public let paused: Bool
}

public final class HatchExtractionStore: Sendable {
    public let directory: URL
    private let executableURL: URL?

    public init(
        supportDirectory: URL,
        executableURL: URL? = Bundle.main.url(forResource: "macease-hatchzip", withExtension: nil)
    ) {
        directory = supportDirectory.appending(path: "HatchExtractions", directoryHint: .isDirectory)
        self.executableURL = executableURL
    }

    public func sessions() throws -> [HatchExtractionSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { folder in
                guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
                let manifestURL = folder.appending(path: "manifest.json")
                guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
                return HatchExtractionSession(
                    id: id, input: URL(fileURLWithPath: manifest.input), output: URL(fileURLWithPath: manifest.output),
                    state: manifest.state)
            }
    }

    func extract(
        input: URL?, resuming id: UUID? = nil, password: String? = nil, progress: @escaping @Sendable (Double) -> Void
    ) async throws
        -> HatchExtractionResult
    {
        guard let executableURL else { throw EngineError.unexpected("The HatchZip executable is missing") }
        let sessionID = id ?? UUID()
        try await Self.validateLocation(input ?? self.input(for: sessionID))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = directory.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        let request = Request(
            action: id == nil ? "start" : "resume", directory: folder.path, input: input?.path, password: password)
        let requestBytes = try JSONEncoder().encode(request) + Data([10])
        let execution = HatchExecution()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try Self.coordinate(input: input ?? self.input(for: sessionID)) {
                    try execution.run(
                        executable: executableURL, request: requestBytes, sessionID: sessionID, progress: progress)
                }
            }.value
        } onCancel: {
            execution.pause()
        }
    }

    private static func validateLocation(_ source: URL) async throws {
        var path = source.resolvingSymlinksInPath().standardizedFileURL.path
        while true {
            let candidate = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let resources = try candidate.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
                let providerFolder = candidate.pathComponents.contains {
                    $0 == "CloudStorage" || $0 == "Mobile Documents"
                }
                guard resources.isUbiquitousItem != true, resources.volumeIsLocal == true, !providerFolder else {
                    throw EngineError.unexpected("Cloud and network locations cannot be extracted in place")
                }
                let _: Void = try await withCheckedThrowingContinuation { continuation in
                    NSFileProviderManager.getIdentifierForUserVisibleFile(at: candidate) { identifier, domain, error in
                        if identifier != nil || domain != nil {
                            continuation.resume(
                                throwing: EngineError.unexpected("File provider locations cannot be extracted in place")
                            )
                        } else if let error = error as NSError? {
                            if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: error)
                            }
                        } else {
                            continuation.resume(
                                throwing: EngineError.unexpected("The file location could not be verified"))
                        }
                    }
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return }
            path = parent
        }
    }

    private func input(for id: UUID) throws -> URL {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: directory.appending(path: id.uuidString).appending(path: "manifest.json")))
        return URL(fileURLWithPath: manifest.input)
    }

    private static func coordinate<Result>(input: URL, _ work: () throws -> Result) throws -> Result {
        let coordinator = NSFileCoordinator()
        var failure: NSError?
        var result: Swift.Result<Result, any Error>?
        coordinator.coordinate(writingItemAt: input.deletingLastPathComponent(), options: [], error: &failure) { _ in
            result = Swift.Result { try work() }
        }
        if let failure { throw failure }
        guard let result else { throw EngineError.unexpected("File coordination did not run") }
        return try result.get()
    }

    private struct Manifest: Decodable {
        let input: String
        let output: String
        let state: String
    }

    private struct Request: Encodable {
        let action: String
        let directory: String
        let input: String?
        let password: String?
    }
}

private final class HatchExecution: Sendable {
    private struct State {
        var input: FileHandle?
        var paused = false
        var pauseFailure: (any Error)?
    }
    private let state = Mutex(State())

    func pause() {
        state.withLock { state in
            state.paused = true
            do { try state.input?.write(contentsOf: Data("pause\n".utf8)) } catch { state.pauseFailure = error }
        }
    }

    func run(
        executable: URL, request: Data, sessionID: UUID, progress: @escaping @Sendable (Double) -> Void
    ) throws -> HatchExtractionResult {
        let subprocess = Process()
        let input = Pipe()
        let output = Pipe()
        subprocess.executableURL = executable
        subprocess.standardInput = input
        subprocess.standardOutput = output
        subprocess.standardError = FileHandle.nullDevice
        try subprocess.run()
        defer {
            input.fileHandleForWriting.closeFile()
            subprocess.waitUntilExit()
        }
        try input.fileHandleForWriting.write(contentsOf: request)
        state.withLock { state in
            state.input = input.fileHandleForWriting
            if state.paused {
                do { try state.input?.write(contentsOf: Data("pause\n".utf8)) } catch { state.pauseFailure = error }
            }
        }
        defer { state.withLock { $0.input = nil } }
        var pending = Data()
        var result: HatchExtractionResult?
        var failure: EngineError?
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let bytes = pending.prefix(upTo: newline)
                let event = try JSONDecoder().decode(Event.self, from: bytes)
                pending.removeSubrange(...newline)
                switch event.event {
                case "progress": progress(event.fraction ?? 0)
                case "finished", "paused":
                    guard let path = event.output else { throw EngineError.unexpected("Missing extraction output") }
                    result = HatchExtractionResult(
                        sessionID: sessionID, output: URL(fileURLWithPath: path), paused: event.event == "paused")
                case "passwordRequired": failure = .invalidInput(.passwordRequired)
                case "wrongPassword": failure = .invalidInput(.wrongPassword)
                case "error": failure = .unexpected(event.message ?? "Extraction failed")
                case "verifying": break
                default: throw EngineError.unexpected("Unsupported extraction response")
                }
            }
        }
        subprocess.waitUntilExit()
        if let failure { throw failure }
        guard subprocess.terminationStatus == 0, let result else {
            if let pauseFailure = state.withLock({ $0.pauseFailure }) { throw pauseFailure }
            throw EngineError.unexpected("HatchZip stopped. Resume the saved extraction from Activity.")
        }
        return result
    }

    private struct Event: Decodable {
        let event: String
        let fraction: Double?
        let output: String?
        let message: String?
    }
}
