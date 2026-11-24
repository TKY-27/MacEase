import AppKit
import ApplicationServices
import Engine
import os

@MainActor
final class FinderWindowTracker: NSObject {
    struct Target: Equatable {
        let element: AXUIElement
        let windowID: CGWindowID
        let frame: CGRect
        let screen: CGRect
        let visible: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.windowID == rhs.windowID && lhs.frame == rhs.frame && lhs.screen == rhs.screen
                && lhs.visible == rhs.visible && CFEqual(lhs.element, rhs.element)
        }
    }

    private let logger = Logger(category: "finder-preview")
    private var application: AXUIElement?
    private var observer: AXObserver?
    private var window: AXUIElement?
    private var finder: NSRunningApplication?
    private var refreshTask: Task<Void, Never>?
    private var visibilityTimer: Timer?
    private var lastFailure: AXError?
    private(set) var target: Target?
    var changed: (() -> Void)?
    var focused: (() -> Void)?
    private var focusPending = false
    private var announcePending = false
    var ended: (() -> Void)?
    var failed: (() -> Void)?

    var finderIsFrontmost: Bool { finder?.isActive == true }

    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    func start() throws {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { throw TrackingError.finderUnavailable }
        self.finder = finder
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        self.application = application
        var created: AXObserver?
        let status = AXObserverCreate(
            finder.processIdentifier,
            { _, element, notification, context in
                guard let context else { return }
                let tracker = Unmanaged<FinderWindowTracker>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    tracker.received(element, notification: notification as String)
                }
            }, &created)
        guard status == .success, let created else { throw TrackingError.accessibility(status) }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        for notification in Self.appNotifications { try observe(application, notification) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didTerminateApplicationNotification,
        ] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(announce: false) }
        }
        try retarget()
        announcePending = true
        refresh()
    }

    func stop() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let application {
                for notification in Self.appNotifications {
                    AXObserverRemoveNotification(observer, application, notification as CFString)
                }
            }
            removeWindowNotifications(observer)
        }
        observer = nil
        application = nil
        window = nil
        target = nil
        finder = nil
    }

    func frontWindowMatchesTarget() -> Bool {
        guard let application, let window else { return false }
        do {
            let focused = try Self.element(application, attribute: kAXFocusedWindowAttribute)
            return CFEqual(focused, window)
        } catch TrackingError.accessibility(.noValue) {
            scheduleRefresh(announce: false)
            return false
        } catch {
            report(error)
            return false
        }
    }

    private func received(_ element: AXUIElement, notification: String) {
        if notification == kAXUIElementDestroyedNotification, let window, CFEqual(element, window) {
            windowClosed()
            return
        }
        if Self.appNotifications.contains(notification) {
            focusPending = true
            do { try retarget() } catch { report(error) }
        }
        scheduleRefresh(announce: true)
    }

    // Another Finder window may take focus.
    private func windowClosed() {
        if let observer { removeWindowNotifications(observer) }
        window = nil
        target = nil
        focusPending = true
        do { try retarget() } catch { report(error) }
        scheduleRefresh(announce: true)
    }

    @objc private func workspaceChanged() {
        guard finder?.isTerminated == false else {
            ended?()
            return
        }
        if finderIsFrontmost {
            focusPending = true
            do { try retarget() } catch { report(error) }
        }
        scheduleRefresh(announce: true)
    }

    // Unannounced refreshes report only changed targets.
    private func scheduleRefresh(announce: Bool) {
        announcePending = announcePending || announce
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard let self else { return }
            refreshTask = nil
            refresh()
        }
    }

    private func retarget() throws {
        guard let application else { return }
        let focused: AXUIElement
        do {
            focused = try Self.element(application, attribute: kAXFocusedWindowAttribute)
        } catch TrackingError.accessibility(.noValue) {
            return
        }
        if let window, CFEqual(window, focused) { return }
        if let observer { removeWindowNotifications(observer) }
        window = focused
        target = nil
        for notification in Self.windowNotifications { try observe(focused, notification) }
    }

    private func observe(_ element: AXUIElement, _ notification: String) throws {
        guard let observer else { return }
        let status = AXObserverAddNotification(
            observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        guard status == .success || status == .notificationAlreadyRegistered else {
            throw TrackingError.accessibility(status)
        }
    }

    private func removeWindowNotifications(_ observer: AXObserver) {
        guard let window else { return }
        for notification in Self.windowNotifications {
            AXObserverRemoveNotification(observer, window, notification as CFString)
        }
    }

    private func refresh() {
        let announce = announcePending
        announcePending = false
        guard let finder, let primary = NSScreen.screens.first else { return }
        if finder.isTerminated {
            ended?()
            return
        }
        guard let window else {
            if announce { changed?() }
            return
        }
        do {
            let axFrame = try Self.bounds(window)
            let frame = FinderPreviewGeometry.appKitFrame(axFrame: axFrame, primaryScreenTop: primary.frame.maxY)
            guard
                let screen = NSScreen.screens.max(by: {
                    Self.overlap($0.frame, frame) < Self.overlap($1.frame, frame)
                })
            else { return }
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            else { throw TrackingError.invalidAttribute }
            let matching = windows.first { record in
                guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == finder.processIdentifier,
                    (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                    let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                    let rect = CGRect(dictionaryRepresentation: bounds)
                else { return false }
                return abs(rect.minX - axFrame.minX) < 2 && abs(rect.minY - axFrame.minY) < 2
                    && abs(rect.width - axFrame.width) < 2 && abs(rect.height - axFrame.height) < 2
            }
            let minimized = try Self.attribute(window, kAXMinimizedAttribute) as? Bool == true
            let windowID = (matching?[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? target?.windowID
            let previous = target
            target = windowID.map {
                Target(
                    element: window, windowID: $0, frame: frame, screen: screen.visibleFrame,
                    visible: matching != nil && !minimized && !finder.isHidden)
            }
            lastFailure = nil
            if announce || target != previous { changed?() }
            if focusPending {
                focusPending = false
                focused?()
            }
        } catch { report(error) }
    }

    private func report(_ error: any Error) {
        if case TrackingError.accessibility(.invalidUIElement) = error, window != nil {
            windowClosed()
            return
        }
        if case TrackingError.accessibility(let status) = error {
            if status != lastFailure {
                logger.error("Finder accessibility failed: \(status.rawValue)")
                lastFailure = status
            }
        } else {
            logger.error("Finder window tracking failed: \(error.localizedDescription, privacy: .private)")
        }
        target = nil
        failed?()
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success, let value else { throw TrackingError.accessibility(status) }
        return value
    }

    private static func element(_ application: AXUIElement, attribute name: String) throws -> AXUIElement {
        let value = try attribute(application, name)
        guard CFGetTypeID(value) == AXUIElementGetTypeID(), let elements = [value] as? [AXUIElement],
            let element = elements.first
        else { throw TrackingError.invalidAttribute }
        return element
    }

    private static func bounds(_ window: AXUIElement) throws -> CGRect {
        let position = try attribute(window, kAXPositionAttribute)
        let size = try attribute(window, kAXSizeAttribute)
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            let values = [position, size] as? [AXValue], values.count == 2
        else { throw TrackingError.invalidAttribute }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(values[0], .cgPoint, &origin), AXValueGetValue(values[1], .cgSize, &dimensions) else {
            throw TrackingError.invalidAttribute
        }
        return CGRect(origin: origin, size: dimensions)
    }

    private enum TrackingError: Error {
        case finderUnavailable, invalidAttribute
        case accessibility(AXError)
    }
}
