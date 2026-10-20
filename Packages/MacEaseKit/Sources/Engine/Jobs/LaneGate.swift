import Foundation

/// Async semaphore; cancellation releases waiters.
actor LaneGate {
    private var width: Int
    private var inUse = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(width: Int) {
        self.width = width
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if inUse < width {
            inUse += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await waitForSlot(id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func waitForSlot(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((id, continuation))
            }
        }
    }

    func release() {
        inUse -= 1
        wakeWaiters()
    }

    func setWidth(_ newWidth: Int) {
        width = max(1, newWidth)
        wakeWaiters()
    }

    private func wakeWaiters() {
        while inUse < width, !waiters.isEmpty {
            inUse += 1
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
