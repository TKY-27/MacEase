import Darwin
import Foundation
import Testing

@testable import Engine

struct LocalFileShareTests {
    @Test func requestParserRejectsTraversalAndBodies() throws {
        #expect(try LocalShareRequest(Data("GET /abc/file HTTP/1.1\r\nHost: local\r\n\r\n".utf8)).path == "/abc/file")
        for request in [
            "POST /abc/file HTTP/1.1\r\nHost: local\r\n\r\n",
            "GET /abc/%2e%2e/file HTTP/1.1\r\nHost: local\r\n\r\n",
            "GET /abc/file?path=../ HTTP/1.1\r\nHost: local\r\n\r\n",
            "GET /abc/file HTTP/1.1\r\nHost: local\r\n\r\nbody",
        ] {
            #expect(throws: LocalFileShareError.self) { try LocalShareRequest(Data(request.utf8)) }
        }
    }

    @Test(.enabled(if: !LocalFileShare.availableInterfaces().isEmpty))
    func rejectsSymlinksAndExcessiveSelections() throws {
        let network = try #require(LocalFileShare.availableInterfaces().first)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "original.txt")
        let symlink = folder.appending(path: "link.txt")
        try Data("secret".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        #expect(throws: LocalFileShareError.invalidSelection) { try LocalFileShare(files: [symlink], on: network) }
        #expect(throws: LocalFileShareError.invalidSelection) {
            try LocalFileShare(files: Array(repeating: original, count: LocalFileShare.maximumFiles + 1), on: network)
        }
    }

    @Test(.enabled(if: !LocalFileShare.availableInterfaces().isEmpty))
    func servesOnlyAuthorizedUnchangedFilesUntilStopped() async throws {
        let network = try #require(LocalFileShare.availableInterfaces().first)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let selected = folder.appending(path: "a<&\".txt")
        let unselected = folder.appending(path: "private.txt")
        let contents = String(repeating: "selected bytes\n", count: 12_000)
        try Data(contents.utf8).write(to: selected)
        try Data("private bytes".utf8).write(to: unselected)
        let share = try LocalFileShare(files: [selected], on: network)
        let url = try await share.start()
        defer { share.stop() }
        #expect(share.permitsRequests(at: share.expiresAt.addingTimeInterval(-1)))
        #expect(!share.permitsRequests(at: share.expiresAt))
        let root = url.path + "/"
        let index = try response(url, path: root)
        #expect(index.contains("200 OK"))
        #expect(index.contains("a&lt;&amp;&quot;.txt"))
        #expect(index.contains("Cache-Control: no-store"))
        #expect(index.contains("Referrer-Policy: no-referrer"))
        #expect(!index.contains("private.txt"))
        let filePath = root + share.files[0].id
        let download = try response(url, path: filePath)
        #expect(download.hasSuffix(contents))
        #expect(download.contains("filename*=UTF-8''a%3C%26%22.txt"))
        #expect(try response(url, path: filePath, method: "HEAD").hasSuffix("\r\n\r\n"))
        #expect(try response(url, path: "/" + String(repeating: "0", count: 64) + "/").contains("404 Not Found"))
        #expect(
            try response(url, path: "/" + String(repeating: "0", count: 64) + "/", method: "HEAD")
                .hasSuffix("\r\n\r\n"))
        #expect(try response(url, path: root + "../private.txt").contains("404 Not Found"))
        try Data("changed".utf8).write(to: selected)
        #expect(try response(url, path: filePath).contains("404 Not Found"))
        share.stop()
        #expect(throws: (any Error).self) { try response(url, path: filePath) }
    }

    private func response(_ url: URL, path: String, method: String = "GET") throws -> String {
        guard let host = url.host, let port = url.port else { throw LocalFileShareError.unavailable }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalFileShareError.unavailable }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1,
            withUnsafePointer(
                to: &address,
                { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }) == 0
        else { throw LocalFileShareError.unavailable }
        let request = Data("\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ send(descriptor, $0.baseAddress, request.count, 0) }) == request.count else {
            throw LocalFileShareError.unavailable
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw LocalFileShareError.unavailable }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: result, encoding: .utf8), !text.isEmpty else {
            throw LocalFileShareError.unavailable
        }
        return text
    }
}
