import Foundation

enum Before {
    static func byteIdenticalSets(_ urls: [URL]) throws -> [[URL]] {
        var remaining = urls.sorted { $0.path < $1.path }
        var sets: [[URL]] = []
        while let first = remaining.first {
            try Task.checkCancellation()
            let identical = remaining.filter {
                $0 == first || FileManager.default.contentsEqual(atPath: first.path, andPath: $0.path)
            }
            remaining.removeAll { identical.contains($0) }
            if identical.count > 1 { sets.append(identical) }
        }
        return sets
    }
}
enum After {
    static func byteIdenticalSets(_ urls: [URL]) throws -> [[URL]] {
        var remaining = urls.sorted { $0.path < $1.path }
        var sets: [[URL]] = []
        while let first = remaining.first {
            try Task.checkCancellation()
            var identical: [URL] = []
            var different: [URL] = []
            for url in remaining {
                if url == first || FileManager.default.contentsEqual(atPath: first.path, andPath: url.path) {
                    identical.append(url)
                } else {
                    different.append(url)
                }
            }
            remaining = different
            if identical.count > 1 { sets.append(identical) }
        }
        return sets
    }
}
