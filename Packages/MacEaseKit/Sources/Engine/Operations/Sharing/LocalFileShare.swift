import Darwin
import Foundation
import Network
import Security
import SystemConfiguration

public enum LocalFileShareError: Error, LocalizedError {
    case noPrivateInterface
    case invalidSelection
    case changedFile
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .noPrivateInterface: "Choose an active private Wi-Fi or Ethernet network."
        case .invalidSelection: "Select one to twenty regular files."
        case .changedFile: "A selected file changed or became unavailable."
        case .unavailable: "Local sharing could not start."
        }
    }
}

public struct LocalShareInterface: Hashable, Sendable, Identifiable {
    public let name: String
    public let address: String
    public let kind: String

    public var id: String { "\(name):\(address)" }
}

public struct LocalSharedFile: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let size: Int64
}

struct ShareFileSnapshot: Sendable {
    let url: URL
    let file: LocalSharedFile
    let device: dev_t
    let inode: ino_t
    let modified: timespec

    func matches(_ status: stat) -> Bool {
        status.st_dev == device && status.st_ino == inode && status.st_size == file.size
            && status.st_mtimespec.tv_sec == modified.tv_sec
            && status.st_mtimespec.tv_nsec == modified.tv_nsec
            && (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    func openVerified() throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalFileShareError.changedFile }
        var status = stat()
        guard fstat(descriptor, &status) == 0, matches(status) else {
            close(descriptor)
            throw LocalFileShareError.changedFile
        }
        return descriptor
    }

    func stillCurrent(_ descriptor: Int32) -> Bool {
        var opened = stat()
        var linked = stat()
        return fstat(descriptor, &opened) == 0 && lstat(url.path, &linked) == 0
            && matches(opened) && matches(linked)
    }
}

struct LocalShareRequest {
    static let maximumBytes = 8_192
    private static let maximumLineBytes = 1_024
    let method: String
    let path: String

    init(_ bytes: Data) throws {
        guard bytes.count <= Self.maximumBytes, let text = String(data: bytes, encoding: .utf8),
            text.hasSuffix("\r\n\r\n"), !text.contains("\0")
        else { throw LocalFileShareError.unavailable }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw LocalFileShareError.unavailable }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1", parts[0] == "GET" || parts[0] == "HEAD",
            parts[1].first == "/", !parts[1].contains("%"), !parts[1].contains("?"),
            lines.dropFirst().dropLast(2).allSatisfy({ line in
                !line.isEmpty && line.utf8.count <= Self.maximumLineBytes && line.contains(":")
                    && !line.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 })
            })
        else { throw LocalFileShareError.unavailable }
        method = String(parts[0])
        path = String(parts[1])
    }
}

public final class LocalFileShare: @unchecked Sendable {
    public static let lifetime: TimeInterval = 15 * 60
    public static let maximumFiles = 20

    public let files: [LocalSharedFile]
    public let expiresAt: Date
    private let onStop: @Sendable () -> Void

    private let networkInterface: LocalShareInterface
    private let snapshots: [String: ShareFileSnapshot]
    private let token: String
    private let queue = DispatchQueue(label: "MacEase.LocalFileShare")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var active = false
    private var expiry: DispatchWorkItem?
    private var pendingStart: CheckedContinuation<URL, any Error>?
    private var pendingRequests: Set<UUID> = []
    private static let chunkSize = 64 * 1_024
    private static let maximumConnections = 8
    private static let requestTimeout: TimeInterval = 5
    private static let tokenBytes = 32

    public static func availableInterfaces() -> [LocalShareInterface] {
        let supported = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap {
            entry -> (String, String)? in
            guard let name = SCNetworkInterfaceGetBSDName(entry) as String?,
                let type = SCNetworkInterfaceGetInterfaceType(entry) as String?
            else { return nil }
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return (name, "Wi-Fi") }
            if type == (kSCNetworkInterfaceTypeEthernet as String) { return (name, "Ethernet") }
            return nil
        }
        var cursor: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&cursor) == 0 else { return [] }
        defer { freeifaddrs(cursor) }
        var result: [LocalShareInterface] = []
        var current = cursor
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                (entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING)
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard let kind = supported.first(where: { $0.0 == name })?.1 else { continue }
            var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            guard inet_ntop(AF_INET, &address, &storage, socklen_t(storage.count)) != nil else { continue }
            let host = String(decoding: storage.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPrivateIPv4(host) else { continue }
            result.append(LocalShareInterface(name: name, address: host, kind: kind))
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    public init(
        files urls: [URL], on interface: LocalShareInterface, onStop: @escaping @Sendable () -> Void = {}
    ) throws {
        guard Self.availableInterfaces().contains(interface) else { throw LocalFileShareError.noPrivateInterface }
        guard !urls.isEmpty, urls.count <= Self.maximumFiles else { throw LocalFileShareError.invalidSelection }
        var snapshots: [String: ShareFileSnapshot] = [:]
        var listed: [LocalSharedFile] = []
        for url in urls {
            guard url.isFileURL else { throw LocalFileShareError.invalidSelection }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw LocalFileShareError.invalidSelection }
            var status = stat()
            let valid = fstat(descriptor, &status) == 0 && (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            close(descriptor)
            guard valid else { throw LocalFileShareError.invalidSelection }
            let file = LocalSharedFile(
                id: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                name: url.lastPathComponent, size: status.st_size)
            snapshots[file.id] = ShareFileSnapshot(
                url: url, file: file, device: status.st_dev,
                inode: status.st_ino, modified: status.st_mtimespec)
            listed.append(file)
        }
        var random = [UInt8](repeating: 0, count: Self.tokenBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw LocalFileShareError.unavailable
        }
        token = random.map { String(format: "%02x", $0) }.joined()
        files = listed
        self.snapshots = snapshots
        networkInterface = interface
        self.onStop = onStop
        expiresAt = Date().addingTimeInterval(Self.lifetime)
    }

    public func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.active, Date() < self.expiresAt else {
                    continuation.resume(throwing: LocalFileShareError.unavailable)
                    return
                }
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = self.networkInterface.kind == "Wi-Fi" ? .wifi : .wiredEthernet
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(self.networkInterface.address), port: .any)
                parameters.allowLocalEndpointReuse = false
                do {
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.active = true
                    self.pendingStart = continuation
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port, self.active, let waiting = self.pendingStart,
                                let url = URL(
                                    string: "http://\(self.networkInterface.address):\(port.rawValue)/\(self.token)/")
                            else { return }
                            self.pendingStart = nil
                            waiting.resume(returning: url)
                            let timeout = DispatchWorkItem { [weak self] in self?.stopOnQueue() }
                            self.expiry = timeout
                            self.queue.asyncAfter(
                                deadline: .now() + max(0, self.expiresAt.timeIntervalSinceNow), execute: timeout)
                        case .failed(let error):
                            self.stopOnQueue(error)
                        default: break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    self.active = false
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue(_ failure: any Error = LocalFileShareError.unavailable) {
        guard active else { return }
        active = false
        pendingStart?.resume(throwing: failure)
        pendingStart = nil
        expiry?.cancel()
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        pendingRequests.removeAll()
        onStop()
    }

    private func accept(_ connection: NWConnection) {
        guard permitsRequests(at: Date()), connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        pendingRequests.insert(id)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive(connection, id: id, bytes: Data()) }
            if case .failed = state { self?.finish(connection, id: id) }
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            if self?.pendingRequests.contains(id) == true { self?.finish(connection, id: id) }
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LocalShareRequest.maximumBytes - bytes.count) {
            [weak self] chunk, _, _, error in
            guard let self, self.active, self.connections[id] != nil else { return }
            guard error == nil, let chunk, !chunk.isEmpty else { self.finish(connection, id: id); return }
            let requestBytes = bytes + chunk
            if requestBytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, id: id, bytes: requestBytes)
            } else if requestBytes.count < LocalShareRequest.maximumBytes {
                self.receive(connection, id: id, bytes: requestBytes)
            } else {
                self.sendError(400, connection: connection, id: id)
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, bytes: Data) {
        pendingRequests.remove(id)
        guard let request = try? LocalShareRequest(bytes), permitsRequests(at: Date()) else {
            sendError(400, connection: connection, id: id)
            return
        }
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0].isEmpty,
            Self.constantTimeEqual(String(segments[1]), token)
        else { sendError(404, head: request.method == "HEAD", connection: connection, id: id); return }
        if segments[2].isEmpty {
            let rows = files.map { file in
                let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
                return "<li><a href=\"\(file.id)\">\(Self.escape(file.name))<small>\(size) · Download</small></a></li>"
            }.joined()
            let html = """
                <!doctype html><html lang="en"><meta charset="utf-8">
                <meta name="viewport" content="width=device-width,initial-scale=1">
                <title>MacEase — Shared files</title>
                <style>
                body{font:17px system-ui,sans-serif;max-width:42rem;margin:3rem auto;padding:0 1.25rem;color:#161616;background:#fff}
                h1{font-size:1.5rem}p,small{color:#555}ul{list-style:none;padding:0}
                li{border-bottom:1px solid #ddd}a{display:block;padding:1.1rem 0;color:#0066cc;text-decoration:none;overflow-wrap:anywhere}
                small{display:block;font-size:.85rem;margin-top:.35rem}a:focus-visible{outline:3px solid #0066cc}
                </style><h1>Shared files</h1><p>Tap a file to save it to your device.</p>
                <ul>\(rows)</ul><p>This link expires when sharing stops.</p></html>
                """
            sendResponse(
                200, headers: ["Content-Type: text/html; charset=utf-8"], body: Data(html.utf8),
                head: request.method == "HEAD", connection: connection, id: id)
            return
        }
        guard let snapshot = snapshots[String(segments[2])], let descriptor = try? snapshot.openVerified() else {
            sendError(404, head: request.method == "HEAD", connection: connection, id: id)
            return
        }
        let encoded = snapshot.file.name.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95].contains(byte)
            {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
        let disposition = "attachment; filename=\"download\"; filename*=UTF-8''\(encoded)"
        let headers = ["Content-Type: application/octet-stream", "Content-Disposition: \(disposition)"]
        let prefix = Self.response(200, headers: headers, length: snapshot.file.size)
        connection.send(
            content: Data(prefix.utf8),
            completion: .contentProcessed { [weak self] error in
                guard let self else { close(descriptor); return }
                if error != nil || request.method == "HEAD" {
                    close(descriptor)
                    self.finish(connection, id: id)
                } else {
                    self.stream(snapshot, descriptor: descriptor, offset: 0, connection: connection, id: id)
                }
            })
    }

    private func stream(
        _ snapshot: ShareFileSnapshot, descriptor: Int32, offset: Int64,
        connection: NWConnection, id: UUID
    ) {
        guard permitsRequests(at: Date()), connections[id] != nil, snapshot.stillCurrent(descriptor) else {
            close(descriptor)
            finish(connection, id: id)
            return
        }
        if offset == snapshot.file.size {
            close(descriptor)
            finish(connection, id: id)
            return
        }
        let count = Int(min(Int64(Self.chunkSize), snapshot.file.size - offset))
        var buffer = [UInt8](repeating: 0, count: count)
        let readCount = pread(descriptor, &buffer, count, off_t(offset))
        guard readCount == count else { close(descriptor); finish(connection, id: id); return }
        connection.send(
            content: Data(buffer),
            completion: .contentProcessed { [weak self] error in
                guard let self else { close(descriptor); return }
                if error == nil {
                    self.stream(
                        snapshot, descriptor: descriptor, offset: offset + Int64(count), connection: connection, id: id)
                } else {
                    close(descriptor); self.finish(connection, id: id)
                }
            })
    }

    private func sendError(_ status: Int, head: Bool = false, connection: NWConnection, id: UUID) {
        sendResponse(
            status, headers: ["Content-Type: text/plain; charset=utf-8"],
            body: Data("Unavailable\n".utf8), head: head, connection: connection, id: id)
    }

    private func sendResponse(
        _ status: Int, headers: [String], body: Data, head: Bool,
        connection: NWConnection, id: UUID
    ) {
        let prefix = Self.response(status, headers: headers, length: Int64(body.count))
        connection.send(
            content: Data(prefix.utf8) + (head ? Data() : body),
            completion: .contentProcessed { [weak self] _ in
                self?.finish(connection, id: id)
            })
    }

    private static func response(_ status: Int, headers: [String], length: Int64) -> String {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
        return
            ([
                "HTTP/1.1 \(status) \(reason)", "Content-Length: \(length)",
                "Connection: close", "Cache-Control: no-store", "Referrer-Policy: no-referrer",
                "X-Content-Type-Options: nosniff",
                "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            ]
            + headers).joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func constantTimeEqual(_ candidate: String, _ expected: String) -> Bool {
        let supplied = Array(candidate.utf8)
        let secret = Array(expected.utf8)
        var difference = supplied.count ^ secret.count
        for index in secret.indices {
            difference |= Int(secret[index] ^ (index < supplied.count ? supplied[index] : 0))
        }
        return difference == 0
    }

    func permitsRequests(at date: Date) -> Bool { active && date < expiresAt }

    private func finish(_ connection: NWConnection, id: UUID) {
        pendingRequests.remove(id)
        connections.removeValue(forKey: id)
        connection.cancel()
    }
}
