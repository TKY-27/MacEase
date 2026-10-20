import Engine
import Foundation
import Testing

struct MissingCapabilityOnDevice: Error, CustomStringConvertible {
    let capability: Capability

    var description: String { "\(capability.rawValue) is missing, but MACEASE_DEVICE_TESTS=1 requires it" }
}

extension Trait where Self == ConditionTrait {
    /// `make test-device` fails instead of skipping.
    static func requires(_ capability: Capability, probe: @escaping @Sendable () throws -> Bool) -> Self {
        .enabled("Requires \(capability.rawValue)") {
            let present = try probe()
            if !present, ProcessInfo.processInfo.environment["MACEASE_DEVICE_TESTS"] == "1" {
                throw MissingCapabilityOnDevice(capability: capability)
            }
            return present
        }
    }
}
