import Darwin
import Foundation
import Synchronization

struct MediaToolResult: Sendable {
    let stdout: Data
}

final class MediaToolProcess: Sendable {
    private struct State {
        var child: Process?
        var cancelled = false
    }
    private let state = Mutex(State())
    private static let captureLimit = 32 * 1_024 * 1_024
    private static let lineLimit = 65_536

    func run(
        executable: URL, arguments: [String], directory: URL, tools: MediaDownloadTools,
        captureOutput: Bool = true, line: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MediaToolResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        with: Result {
                            try self.execute(
                                executable: executable, arguments: arguments, directory: directory, tools: tools,
                                captureOutput: captureOutput, line: line)
                        })
                }
            }
        } onCancel: {
            self.state.withLock {
                $0.cancelled = true
                if let child = $0.child, child.isRunning {
                    kill(-child.processIdentifier, SIGKILL)
                    kill(child.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func execute(
        executable: URL, arguments: [String], directory: URL, tools: MediaDownloadTools,
        captureOutput: Bool, line: @escaping @Sendable (String) -> Void
    ) throws -> MediaToolResult {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = [
            "HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8",
            "PATH": tools.directory.path + ":/usr/bin:/bin", "SSL_CERT_FILE": "/etc/ssl/cert.pem",
        ]
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.standardOutput = standardOutput
        child.standardError = standardError
        try state.withLock {
            guard !$0.cancelled else { throw CancellationError() }
            $0.child = child
            try child.run()
        }
        let capture = Mutex(Data())
        let overflow = Mutex(false)
        let diagnostics = Mutex(Data())
        let readers = DispatchGroup()
        for (pipe, captures) in [(standardOutput, true), (standardError, false)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                var pending = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if captures && captureOutput {
                        capture.withLock {
                            if $0.count + chunk.count <= Self.captureLimit {
                                $0.append(chunk)
                            } else {
                                overflow.withLock { $0 = true }
                                kill(-child.processIdentifier, SIGKILL)
                                kill(child.processIdentifier, SIGKILL)
                            }
                        }
                    }
                    if !captures {
                        diagnostics.withLock { $0.append(chunk.prefix(max(0, Self.lineLimit - $0.count))) }
                    }
                    do {
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 10) {
                            if newline <= Self.lineLimit {
                                line(String(decoding: pending[..<newline], as: UTF8.self))
                            }
                            pending.removeSubrange(...newline)
                        }
                        if pending.count > Self.lineLimit { pending.removeAll(keepingCapacity: true) }
                    }
                }
            }
        }
        child.waitUntilExit()
        readers.wait()
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        guard !overflow.withLock({ $0 }) else { throw EngineError.decodeFailed("Media metadata exceeds limit") }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            let message = String(decoding: diagnostics.withLock { $0 }, as: UTF8.self).lowercased()
            let reason: String
            if message.contains("no space left") {
                reason = "There is not enough disk space for this download"
            } else if message.contains("permission denied") {
                reason = "The destination or media tool is not accessible"
            } else if message.contains("sign in") || message.contains("login") || message.contains("private video") {
                reason = "This media requires login; only public media is supported"
            } else if message.contains("403") || message.contains("429") {
                reason = "The website refused the request or applied a rate limit"
            } else if message.contains("unsupported url") {
                reason = "This website or URL is unsupported"
            } else if message.contains("timed out") || message.contains("unable to download") {
                reason = "The network transfer failed; retry when the connection is available"
            } else if message.contains("requested format") {
                reason = "The selected format or resolution is unavailable"
            } else {
                reason = "Media tool failed (exit \(child.terminationStatus))"
            }
            throw EngineError.decodeFailed(reason)
        }
        return MediaToolResult(stdout: capture.withLock { $0 })
    }
}
