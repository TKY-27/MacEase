import Darwin
import Foundation
import MenuCatalog
import Synchronization

public struct FileProtection: Sendable {
    private enum BridgeFailure: String, Sendable {
        case authentication = "MACEASE_AGE_ERROR:authentication"
        case diskFull = "MACEASE_AGE_ERROR:disk-full"
        case permission = "MACEASE_AGE_ERROR:permission"
        case integrity = "MACEASE_AGE_ERROR:integrity"
        case io = "MACEASE_AGE_ERROR:io"
    }

    private let executable: URL
    private let tools: MediaDownloadTools
    private static let maximumPassphraseBytes = 4_096
    private static let minimumPassphraseLength = 12

    public init() throws {
        guard let resources = Bundle.main.resourceURL else {
            throw EngineError.unsupportedCodec("Bundled age bridge is unavailable")
        }
        try self.init(helperURL: resources.appending(path: "macease-age"), tools: MediaDownloadTools.bundled())
    }

    public init(helperURL: URL, tools: MediaDownloadTools) throws {
        guard helperURL.isFileURL, helperURL.lastPathComponent == "macease-age",
            FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            throw EngineError.unsupportedCodec("Bundled age bridge is unavailable")
        }
        executable = helperURL
        self.tools = tools
    }

    public func batch(source: URL, password: String, decrypt: Bool) throws -> Batch {
        let length = password.utf8.count
        guard !password.isEmpty, (decrypt || password.count >= Self.minimumPassphraseLength),
            length <= Self.maximumPassphraseBytes
        else {
            throw EngineError.invalidInput(
                .malformed("New passwords need at least 12 characters; all passwords are limited to 4096 bytes"))
        }
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw EngineError.invalidInput(.malformed("Select one regular file"))
        }
        guard !decrypt || source.pathExtension.lowercased() == "age" else {
            throw EngineError.invalidInput(.malformed("Select an .age file to decrypt"))
        }
        let name = decrypt ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent + ".age"
        guard !name.isEmpty, name != "." else {
            throw EngineError.invalidInput(.malformed("The output file needs a name"))
        }
        var workItem = WorkItem(inputs: [source]) { context in
            let staged = try context.stagingURL(for: source, name: name)
            let mode = decrypt ? "decrypt" : "encrypt"
            try await execute(mode: mode, source: source, output: staged, password: password)
            if !decrypt {
                try await execute(mode: "verify", source: staged, output: source, password: password)
            }
            try Task.checkCancellation()
            let check: OutputCheck = decrypt ? .ageAuthenticatedPlaintext(AgeAuthenticationProof()) : .decompressed
            return .derived(nextTo: source, outputs: [StagedFile(url: staged, name: name, check: check)])
        }
        workItem.requiredInputStamps = [source: try FileStamp(of: source, includingIdentity: true)]
        return Batch(operation: .anyProtect, items: [workItem])
    }

    private func execute(mode: String, source: URL, output: URL, password: String) async throws {
        let pipe = Pipe()
        var frame = Data()
        let encoded = Data(password.utf8)
        var length = UInt32(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(encoded)
        let framedPassword = frame
        let writer = pipe.fileHandleForWriting
        let writerTask = Task.detached(priority: .utility) {
            let writeResult = Result { try writer.write(contentsOf: framedPassword) }
            let closeResult = Result { try writer.close() }
            try writeResult.get()
            try closeResult.get()
        }
        let bridgeFailure = Mutex<BridgeFailure?>(nil)
        let childResult: Result<MediaToolResult, any Error>
        do {
            childResult = .success(
                try await MediaToolProcess().run(
                    executable: executable,
                    arguments: [mode, source.path, output.path],
                    directory: source.deletingLastPathComponent(),
                    tools: tools,
                    captureOutput: false,
                    input: pipe.fileHandleForReading,
                    line: { line in
                        guard let category = BridgeFailure(rawValue: line) else { return }
                        bridgeFailure.withLock { if $0 == nil { $0 = category } }
                    }))
        } catch {
            childResult = .failure(error)
        }
        switch (childResult, await writerTask.result) {
        case (.success, .success): return
        case (.failure(let childError), .success):
            throw mappedFailure(bridgeFailure.withLock { $0 }, mode: mode, source: source, fallback: childError)
        case (.success, .failure(let pipeError)): throw pipeError
        case (.failure(let childError), .failure(let pipeError)):
            if childError is CancellationError { throw childError }
            if let category = bridgeFailure.withLock({ $0 }) {
                throw mappedFailure(category, mode: mode, source: source, fallback: childError)
            }
            throw EngineError.decodeFailed(
                "Age bridge failed: \(childError.localizedDescription); passphrase pipe failed: \(pipeError.localizedDescription)"
            )
        }
    }

    private func mappedFailure(
        _ category: BridgeFailure?, mode: String, source: URL, fallback: any Error
    ) -> any Error {
        guard let category else { return fallback }
        switch category {
        case .authentication:
            return mode == "decrypt"
                ? EngineError.protectionAuthenticationFailed
                : EngineError.encodeFailed("Age output verification failed")
        case .diskFull:
            return EngineError.protectionDiskFull
        case .permission:
            return EngineError.permissionDenied(PermissionLocation(path: source.path))
        case .integrity:
            return EngineError.encodeFailed("Age output verification failed")
        case .io:
            return mode == "encrypt"
                ? EngineError.encodeFailed("Age bridge I/O failed")
                : EngineError.decodeFailed("Age bridge I/O failed")
        }
    }
}
