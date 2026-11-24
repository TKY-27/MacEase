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
private final class ProbeNavigationObserver: NSObject, WKNavigationDelegate {
    let production: PreviewWebDelegate
    var onFinish: (() -> Void)?
    var onFail: ((any Error) -> Void)?
    private(set) var requestedURLs: [URL] = []

    init(production: PreviewWebDelegate) {
        self.production = production
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        if let url = navigationAction.request.url { requestedURLs.append(url) }
        return await production.webView(webView, decidePolicyFor: navigationAction)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        await production.webView(webView, decidePolicyFor: navigationResponse)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        production.webView(webView, didFail: navigation, withError: error)
        if production.failed.wrappedValue { onFail?(error) }
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
    ) {
        production.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        if production.failed.wrappedValue { onFail?(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        production.webViewWebContentProcessDidTerminate(webView)
    }
}

@MainActor
final class PreviewWebProbe {
    private static let loadTimeout: Duration = .seconds(10)
    let window: NSWindow
    let container: PreviewWebContainerView
    private var browser: PreviewWKWebView { container.webView }
    private let delegate: PreviewWebDelegate
    private let observer: ProbeNavigationObserver
    private var finished: CheckedContinuation<Void, any Error>?
    private(set) var didFail = false

    private init(page: PreviewWebViewer.Page, configuration: WKWebViewConfiguration) {
        var failed = false
        let binding = Binding(get: { failed }, set: { failed = $0 })
        delegate = PreviewWebDelegate(page: page, failed: binding)
        observer = ProbeNavigationObserver(production: delegate)
        let rect = NSRect(x: -1000, y: -1000, width: 400, height: 300)
        window = NSWindow(
            contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        container = PreviewWebContainerView(
            frame: NSRect(origin: .zero, size: rect.size), configuration: configuration,
            interactive: page.allowsInteractive
        )
        window.contentView = container
        window.orderBack(nil)
        window.layoutIfNeeded()
        browser.navigationDelegate = observer
        browser.uiDelegate = delegate
        observer.onFinish = { [weak self] in self?.resume() }
        observer.onFail = { [weak self] error in
            self?.didFail = true
            self?.resume(throwing: error)
        }
    }

    var requestedNavigationURLs: [URL] { observer.requestedURLs }

    deinit {
        MainActor.assumeIsolated {
            container.tearDown()
            window.orderOut(nil)
        }
    }

    // Uses production configuration, AppKit hierarchy and load.
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

    func attemptFocusWebView() -> Bool {
        guard browser.acceptsFirstResponder else {
            _ = window.makeFirstResponder(browser)
            return window.firstResponder === browser
        }
        return window.makeFirstResponder(browser) && window.firstResponder === browser
    }

    func hitTest(webPoint: NSPoint) -> NSView? {
        let windowPoint = windowPoint(fromWebPoint: webPoint)
        return window.contentView?.hitTest(windowPoint)
    }

    func accessibilityHitTest(webPoint: NSPoint) -> AnyObject? {
        let screenPoint = window.convertPoint(toScreen: windowPoint(fromWebPoint: webPoint))
        return window.accessibilityHitTest(screenPoint) as AnyObject?
    }

    func webViewAccessibilityHitTest(webPoint: NSPoint) -> AnyObject? {
        let screenPoint = window.convertPoint(toScreen: windowPoint(fromWebPoint: webPoint))
        return container.webView.accessibilityHitTest(screenPoint) as AnyObject?
    }

    func shieldAccessibilityHitTest(webPoint: NSPoint) -> AnyObject? {
        let screenPoint = window.convertPoint(toScreen: windowPoint(fromWebPoint: webPoint))
        return container.inputShield.accessibilityHitTest(screenPoint) as AnyObject?
    }

    func click(webPoint: NSPoint) throws {
        let point = windowPoint(fromWebPoint: webPoint)
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(down)
        window.sendEvent(up)
    }

    func rightClick(webPoint: NSPoint) throws {
        let point = windowPoint(fromWebPoint: webPoint)
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
        window.sendEvent(down)
        window.sendEvent(up)
    }

    func drag(from startWebPoint: NSPoint, to endWebPoint: NSPoint) throws {
        let start = windowPoint(fromWebPoint: startWebPoint)
        let end = windowPoint(fromWebPoint: endWebPoint)
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: start, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 1))
        let dragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged, location: end, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 6, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: end, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 7, clickCount: 1, pressure: 0))
        window.sendEvent(down)
        window.sendEvent(dragged)
        window.sendEvent(up)
    }

    func pressKey(_ characters: String, keyCode: UInt16) throws {
        let down = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        let up = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        window.sendEvent(down)
        window.sendEvent(up)
    }

    func scroll(deltaY: Int32, at webPoint: NSPoint = NSPoint(x: 100, y: 100)) throws {
        let cgEvent = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        let target = hitTest(webPoint: webPoint)
        target?.scrollWheel(with: event)
    }

    private func windowPoint(fromWebPoint webPoint: NSPoint) -> NSPoint {
        NSPoint(x: webPoint.x, y: container.bounds.height - webPoint.y)
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
