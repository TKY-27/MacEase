import Foundation

public struct OrganizationStability: Sendable {
    private struct Observation: Sendable {
        let stamp: FileStamp
        let since: Date
        var attempted: Bool
    }
    private var observations: [URL: Observation] = [:]

    public init() {}

    public mutating func inspect(
        _ candidates: [URL], now: Date, delay: TimeInterval, suppressions: [OrganizationSuppression]
    ) throws -> (ready: [URL], nextCheck: Date?) {
        observations = observations.filter { candidates.contains($0.key) }
        var ready: [URL] = []
        var nextCheck: Date?
        for url in candidates {
            let stamp = try FileStamp(of: url, includingIdentity: true)
            if suppressions.contains(where: { $0.matches(url) }) { continue }
            if observations[url]?.stamp != stamp {
                observations[url] = Observation(stamp: stamp, since: now, attempted: false)
            }
            guard var observation = observations[url], !observation.attempted else { continue }
            let deadline = observation.since.addingTimeInterval(delay)
            if now >= deadline {
                observation.attempted = true
                observations[url] = observation
                ready.append(url)
            } else {
                nextCheck = min(nextCheck ?? deadline, deadline)
            }
        }
        return (ready, nextCheck)
    }
}
