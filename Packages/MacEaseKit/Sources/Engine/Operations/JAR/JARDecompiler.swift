import Foundation
import MenuCatalog

public enum JAROperation: Codable, Hashable, Sendable {
    /// `cfr` is the bundled decompiler jar.
    case decompile(cfr: URL)
}

public enum JavaRuntime {
    private static let javaHome = URL(fileURLWithPath: "/usr/libexec/java_home")

    /// `nil` when `java_home` finds no installed runtime.
    public static func executable() throws -> URL? {
        let probe = Process()
        let output = Pipe()
        probe.executableURL = javaHome
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        let home = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        let path = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.terminationStatus == 0, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).appending(path: "bin/java")
    }
}

enum JARDecompiler {
    private static let stderrTailLines = 3
    private static let logName = "cfr-stderr.log"
    private static let progressPrefix = "Processing "
    private static let noSourceMessage = "CFR produced no Java source"

    static var bundledOperation: JAROperation? {
        Bundle.main.resourceURL.map { .decompile(cfr: $0.appending(path: "cfr.jar")) }
    }

    static func batch(_ operation: JAROperation, op: OperationID, inputs: [URL]) -> Batch {
        switch operation {
        case .decompile(let cfr):
            let items = inputs.map { url in
                OperationPlanner.validated(url, kind: .jar) { context in
                    try await decompile(url, cfr: cfr, context: context)
                }
            }
            return Batch(operation: op, items: items)
        }
    }

    private static func decompile(_ jar: URL, cfr: URL, context: ItemContext) async throws -> ItemResult {
        guard let java = try JavaRuntime.executable() else { throw EngineError.missingCapability(.java) }
        guard FileManager.default.fileExists(atPath: cfr.path) else { throw EngineError.unexpected("cfr.jar missing") }
        let staging = try context.stagingDirectory(for: jar)
        let name = jar.deletingPathExtension().lastPathComponent
        let output = staging.appending(path: name, directoryHint: .isDirectory)
        let log = staging.appending(path: logName)
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw EngineError.unexpected("CFR log not writable")
        }
        let process = Process()
        process.executableURL = java
        process.arguments = ["-jar", cfr.path, jar.path, "--outputdir", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: log)
        try await run(process)
        // CFR exits 0 even on unreadable jars.
        guard process.terminationStatus == 0, containsJavaSource(output) else {
            throw EngineError.invalidInput(.malformed(try stderrTail(log)))
        }
        return .derived(nextTo: jar, outputs: [StagedFile(url: output, name: name, check: .folder)])
    }

    private static func run(_ process: Process) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
    }

    private static func containsJavaSource(_ folder: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return false
        }
        return files.contains { ($0 as? URL)?.pathExtension == "java" }
    }

    /// Progress and stack frames hide the cause.
    private static func stderrTail(_ log: URL) throws -> String {
        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let isStackFrame = line.hasSuffix(")") && line.contains(".java:")
                return !line.isEmpty && !line.hasPrefix(progressPrefix) && !isStackFrame
            }
        return lines.isEmpty ? noSourceMessage : lines.suffix(stderrTailLines).joined(separator: "\n")
    }
}
