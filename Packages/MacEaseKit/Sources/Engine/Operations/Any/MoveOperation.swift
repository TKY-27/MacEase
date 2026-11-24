import Foundation
import MenuCatalog

public struct MoveItem: Codable, Hashable, Sendable {
    public let url: URL
    public let stamp: FileStamp

    public init(url: URL, stamp: FileStamp) {
        self.url = url
        self.stamp = stamp
    }

    public static func capture(_ url: URL) throws -> MoveItem {
        MoveItem(url: url, stamp: try FileStamp(of: url, includingIdentity: true, checkCancellation: true))
    }
}

public struct MovePlan: Codable, Hashable, Sendable {
    public let items: [MoveItem]
    public let destination: URL

    public init(items: [MoveItem], destination: URL) {
        self.items = items
        self.destination = destination
    }
}

enum MovePlanner {
    static func batch(_ plan: MovePlan, op: OperationID) -> Batch {
        guard !plan.items.isEmpty else {
            let rejected = WorkItem(inputs: [], managesInputStamps: true) { _ in
                throw EngineError.invalidInput(.tooFewFiles(minimum: 1))
            }
            return Batch(operation: op, items: [rejected])
        }
        let workItems = plan.items.map { entry in
            WorkItem(inputs: [entry.url], managesInputStamps: true) { _ in
                .move(entry, to: plan.destination)
            }
        }
        return Batch(operation: op, items: workItems)
    }
}
