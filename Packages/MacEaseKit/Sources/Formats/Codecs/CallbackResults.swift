import Foundation

/// Lock-guarded; VideoToolbox handlers must be Sendable.
final class CallbackResults<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []
    private var failure: OSStatus?
    private let failureMessage: (OSStatus) -> FormatError

    init(failure message: @escaping (OSStatus) -> FormatError) {
        failureMessage = message
    }

    func append(_ element: Element) {
        lock.withLock { elements.append(element) }
    }

    func fail(_ status: OSStatus) {
        lock.withLock { failure = failure ?? status }
    }

    func take() throws -> [Element] {
        try lock.withLock {
            if let failure { throw failureMessage(failure) }
            defer { elements = [] }
            return elements
        }
    }
}
