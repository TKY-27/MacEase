import Darwin
import Foundation
import Synchronization

struct MediaToolResult: Sendable {
    let stdout: Data
}

final class MediaToolProcess: Sendable {
    struct Monitor: Sendable {
        let interval: Duration
        let tick: @Sendable () -> Void
    }

    struct WatchdogReset: Sendable {
        let matches: @Sendable (String) -> Bool
    }

    enum Failure: Error, Equatable, Sendable {
        case timedOut
        case outputLimitExceeded
        case diskFull(String)
        case permissionDenied(String)
        case signalled(Int32)
        case exited(status: Int32, reason: String)

        func engineError(path: String) -> EngineError {
            switch self {
            case .timedOut:
                .decodeFailed(MediaToolProcess.timedOutMessage)
            case .outputLimitExceeded:
                .decodeFailed("Media metadata exceeds limit")
            case .diskFull(let detail):
                .commitFailed(detail)
            case .permissionDenied:
                .permissionDenied(PermissionLocation(path: path))
            case .signalled(let signal):
                .unexpected("Media tool terminated by signal \(signal)")
            case .exited(_, let reason):
                .decodeFailed(reason)
            }
        }

        // Legacy callers expect decodeFailed with specific messages.
        var legacyEngineError: EngineError {
            switch self {
            case .timedOut:
                .decodeFailed(MediaToolProcess.timedOutMessage)
            case .outputLimitExceeded:
                .decodeFailed("Media metadata exceeds limit")
            case .diskFull(let detail), .permissionDenied(let detail), .exited(_, let detail):
                .decodeFailed(detail)
            case .signalled(let signal):
                .decodeFailed("Media tool failed (exit \(signal))")
            }
        }
    }

    private struct State {
        var child: Process?
        var cancelled = false
        var timedOut = false
    }
    private let state = Mutex(State())
    static let timedOutMessage = "Media tool timed out without progress"
    private static let captureLimit = 32 * 1_024 * 1_024
    private static let lineLimit = 65_536
    private static let minimumMonitorInterval = Duration.milliseconds(50)
    private static let timeoutCheckDivisor: Int64 = 4

    func run(
        executable: URL, arguments: [String], directory: URL, tools: MediaDownloadTools,
        captureOutput: Bool = true, input: FileHandle? = nil, includeTLSCertificate: Bool = true,
        noProgressTimeout: Duration? = nil, watchdogReset: WatchdogReset? = nil,
        monitor: Monitor? = nil,
        line: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MediaToolResult {
        do {
            return try await runTyped(
                executable: executable, arguments: arguments, directory: directory, tools: tools,
                captureOutput: captureOutput, input: input, includeTLSCertificate: includeTLSCertificate,
                noProgressTimeout: noProgressTimeout, watchdogReset: watchdogReset, monitor: monitor, line: line)
        } catch let failure as Failure {
            throw failure.legacyEngineError
        }
    }

    func runTyped(
        executable: URL, arguments: [String], directory: URL, tools: MediaDownloadTools,
        captureOutput: Bool = true, input: FileHandle? = nil, includeTLSCertificate: Bool = true,
        noProgressTimeout: Duration? = nil, watchdogReset: WatchdogReset? = nil,
        monitor: Monitor? = nil,
        line: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MediaToolResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        with: Result {
                            try self.execute(
                                executable: executable, arguments: arguments, directory: directory, tools: tools,
                                captureOutput: captureOutput, input: input,
                                includeTLSCertificate: includeTLSCertificate, noProgressTimeout: noProgressTimeout,
                                watchdogReset: watchdogReset, monitor: monitor, line: line)
                        })
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            if let child = $0.child, child.isRunning {
                Self.stop(child)
            }
        }
    }

    private func timeout() {
        state.withLock {
            $0.timedOut = true
            if let child = $0.child, child.isRunning {
                Self.stop(child)
            }
        }
    }

    private static func stop(_ child: Process) {
        let identifier = child.processIdentifier
        if getpgid(identifier) == identifier { kill(-identifier, SIGKILL) }
        kill(identifier, SIGKILL)
    }

    private static func timerInterval(timeout: Duration?, monitor: Duration?) -> Duration {
        var chosen = monitor ?? Duration.seconds(1)
        if let timeout {
            let quarter = timeout / timeoutCheckDivisor
            chosen = min(chosen, quarter)
        }
        return max(minimumMonitorInterval, chosen)
    }

    private func execute(
        executable: URL, arguments: [String], directory: URL, tools: MediaDownloadTools,
        captureOutput: Bool, input: FileHandle?, includeTLSCertificate: Bool,
        noProgressTimeout: Duration?, watchdogReset: WatchdogReset?, monitor: Monitor?,
        line: @escaping @Sendable (String) -> Void
    ) throws -> MediaToolResult {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = input ?? FileHandle.nullDevice
        child.currentDirectoryURL = directory
        var environment = [
            "HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "PATH": includeTLSCertificate ? tools.directory.path + ":/usr/bin:/bin" : "/usr/bin:/bin",
        ]
        if includeTLSCertificate {
            environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        child.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.standardOutput = standardOutput
        child.standardError = standardError
        defer { try? input?.close() }
        try state.withLock {
            guard !$0.cancelled else { throw CancellationError() }
            $0.child = child
            try child.run()
        }
        try input?.close()
        let lastActivity = Mutex(ContinuousClock.now)
        var monitorTimer: DispatchSourceTimer?
        if noProgressTimeout != nil || monitor != nil {
            let interval = Self.timerInterval(timeout: noProgressTimeout, monitor: monitor?.interval)
            let intervalMilliseconds = max(
                1, Int(interval.components.seconds * 1_000 + interval.components.attoseconds / 1_000_000_000_000_000))
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(
                deadline: .now() + .milliseconds(intervalMilliseconds),
                repeating: .milliseconds(intervalMilliseconds))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let noProgressTimeout, ContinuousClock.now - lastActivity.withLock({ $0 }) >= noProgressTimeout {
                    self.timeout()
                    return
                }
                monitor?.tick()
            }
            timer.resume()
            monitorTimer = timer
        }
        defer { monitorTimer?.cancel() }
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
                                Self.stop(child)
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
                                let text = String(decoding: pending[..<newline], as: UTF8.self)
                                if captures, let watchdogReset, watchdogReset.matches(text) {
                                    lastActivity.withLock { $0 = ContinuousClock.now }
                                }
                                line(text)
                            }
                            pending.removeSubrange(...newline)
                        }
                        if pending.count > Self.lineLimit { pending.removeAll(keepingCapacity: true) }
                    }
                }
            }
        }
        child.waitUntilExit()
        monitorTimer?.cancel()
        readers.wait()
        if state.withLock({ $0.timedOut }) { throw Failure.timedOut }
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        guard !overflow.withLock({ $0 }) else { throw Failure.outputLimitExceeded }
        guard child.terminationReason == .exit else {
            throw Failure.signalled(child.terminationStatus)
        }
        guard child.terminationStatus == 0 else {
            let diagnosticsText = String(decoding: diagnostics.withLock { $0 }, as: UTF8.self)
            throw Self.classifyExitFailure(diagnostics: diagnosticsText, status: child.terminationStatus)
        }
        return MediaToolResult(stdout: capture.withLock { $0 })
    }

    // Match errno suffixes only; never filenames.
    static func classifyExitFailure(diagnostics: String, status: Int32) -> Failure {
        let reasons = errorLineReasons(in: diagnostics)
        if reasons.contains(where: { isDiskFullReason($0) }) {
            return .diskFull("There is not enough disk space for this operation")
        }
        if reasons.contains(where: { isPermissionDeniedReason($0) }) {
            return .permissionDenied("The destination or media tool is not accessible")
        }
        let message = diagnostics.lowercased()
        let reason: String
        if message.contains("sign in") || message.contains("login") || message.contains("private video") {
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
            reason = "Media tool failed (exit \(status))"
        }
        return .exited(status: status, reason: reason)
    }

    private static func errorLineReasons(in diagnostics: String) -> [String] {
        var collected: [String] = []
        for rawLine in diagnostics.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if let lastSeparator = trimmed.range(of: ": ", options: .backwards) {
                let tail = String(trimmed[lastSeparator.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { collected.append(tail) }
                // Handle Python "[Errno N] Message: '/path'" format.
                if !trimmed.hasPrefix("file:"), !trimmed.hasPrefix("/") {
                    let prefix = trimmed[..<lastSeparator.lowerBound]
                    if let previous = prefix.range(of: ": ", options: .backwards) {
                        let candidate = String(prefix[previous.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if candidate.hasPrefix("[errno ") { collected.append(candidate) }
                    } else if prefix.hasPrefix("[errno ") {
                        collected.append(String(prefix))
                    }
                }
            } else {
                collected.append(trimmed)
            }
        }
        return collected
    }

    private static func isDiskFullReason(_ reason: String) -> Bool {
        let normalized = strippingErrnoPrefix(reason)
        return normalized == "no space left on device" || normalized == "no space left"
    }

    private static func isPermissionDeniedReason(_ reason: String) -> Bool {
        let normalized = strippingErrnoPrefix(reason)
        return normalized == "permission denied" || normalized == "operation not permitted"
    }

    private static func strippingErrnoPrefix(_ reason: String) -> String {
        guard reason.hasPrefix("[errno "), let close = reason.firstIndex(of: "]") else { return reason }
        return reason[reason.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }
}
