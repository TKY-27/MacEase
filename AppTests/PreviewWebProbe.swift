import AppKit
import Network
import SwiftUI
import WebKit
import XCTest

@testable import MacEase

// Proves WebKit stayed offline over TCP.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "preview-loopback-tcp")
    private let lock = NSLock()
    private var connections = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.connections += 1 }
            connection.cancel()
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var connectionCount: Int { lock.withLock { connections } }

    func stop() { listener.cancel() }
}

// Proves WebKit stayed offline over UDP.
final class LoopbackUDPListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "preview-loopback-udp")
    private let lock = NSLock()
    private var datagrams = 0

    init() throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let listenerSelf = self else { return }
            connection.start(queue: listenerSelf.queue)
            connection.receiveMessage { data, _, _, _ in
                if let data, !data.isEmpty {
                    listenerSelf.lock.withLock { listenerSelf.datagrams += 1 }
                }
                connection.cancel()
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var datagramCount: Int { lock.withLock { datagrams } }

    func stop() { listener.cancel() }
}

@MainActor
final class PreviewWebProbe {
    private static let loadTimeout: Duration = .seconds(10)
    private let browser: WKWebView
    private let delegate: PreviewWebDelegate
    private var finished: CheckedContinuation<Void, any Error>?
    private(set) var didFail = false

    private init(page: PreviewWebViewer.Page, configuration: WKWebViewConfiguration) {
        var failed = false
        let binding = Binding(get: { failed }, set: { failed = $0 })
        delegate = PreviewWebDelegate(page: page, failed: binding)
        browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        browser.navigationDelegate = delegate
        browser.uiDelegate = delegate
        browser.allowsBackForwardNavigationGestures = false
        browser.allowsLinkPreview = false
        delegate.onFinishNavigation = { [weak self] in self?.resume() }
        delegate.onFailNavigation = { [weak self] error in
            self?.didFail = true
            self?.resume(throwing: error)
        }
    }

    // Uses production configuration, delegates and load path.
    static func loading(_ page: PreviewWebViewer.Page) async throws -> PreviewWebProbe {
        let probe = PreviewWebProbe(page: page, configuration: try await PreviewWebConfiguration.make(for: page))
        try await probe.waitForLoad { PreviewWebConfiguration.load(page, in: $0) }
        return probe
    }

    var currentURL: URL? { browser.url }

    // App-injected; works with page scripts off.
    func evaluate(_ script: String) async throws -> Any? {
        try await browser.evaluateJavaScript(script)
    }

    // Lets late subresource requests reach the listener.
    func settle(_ duration: Duration = .milliseconds(500)) async throws {
        try await Task.sleep(for: duration)
    }

    private func waitForLoad(_ start: (WKWebView) -> Void) async throws {
        let timeout = Task { [weak self] in
            try await Task.sleep(for: Self.loadTimeout)
            self?.resume(throwing: URLError(.timedOut))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            start(browser)
        }
    }

    private func resume(throwing error: (any Error)? = nil) {
        guard let finished else { return }
        self.finished = nil
        if let error { finished.resume(throwing: error) } else { finished.resume() }
    }
}

enum PreviewFixtures {
    static func directory(_ test: XCTestCase) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        test.addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    static func png(width: Int = 8, height: Int = 6) throws -> Data {
        let image = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    static func quarantine(_ url: URL) throws {
        let value = Array("0083;00000000;Safari;".utf8)
        let status = setxattr(url.path, "com.apple.quarantine", value, value.count, 0, 0)
        XCTAssertEqual(status, 0, "setxattr failed with errno \(errno)")
    }
}
