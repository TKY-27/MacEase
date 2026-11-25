import Foundation

@main struct Benchmark {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseDuplicates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let allFiles = (0..<16_000).map { root.appending(path: "copy-\($0)") }
        for file in allFiles { try Data().write(to: file) }
        for count in [1_000, 4_000, 16_000] {
            let files = Array(allFiles.prefix(count))
            let expected = [files.sorted { $0.path < $1.path }]
            var before: [Double] = []
            var after: [Double] = []
            for trial in 0..<6 {
                for useBefore in (trial.isMultiple(of: 2) ? [true, false] : [false, true]) {
                    let start = ContinuousClock.now
                    let actual = try useBefore ? Before.byteIdenticalSets(files) : After.byteIdenticalSets(files)
                    let seconds = (ContinuousClock.now - start) / .seconds(1)
                    guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
                    if trial > 0 {
                        if useBefore { before.append(seconds) } else { after.append(seconds) }
                    }
                }
            }
            let baseline = before.sorted()[2]
            let candidate = after.sorted()[2]
            print("files=\(count) baseline_seconds=\(baseline) candidate_seconds=\(candidate) speedup=\(baseline / candidate)")
        }
        let mixed = Array(allFiles.prefix(60))
        for (index, file) in mixed.enumerated() {
            try Data("group-\(index % 7)".utf8).write(to: file)
        }
        let oldGroups = try Before.byteIdenticalSets(mixed.reversed())
        let newGroups = try After.byteIdenticalSets(mixed.reversed())
        guard oldGroups == newGroups, newGroups.count == 7 else { throw CocoaError(.fileReadCorruptFile) }
        guard try After.byteIdenticalSets([]).isEmpty,
            try After.byteIdenticalSets([mixed[0]]).isEmpty
        else { throw CocoaError(.fileReadCorruptFile) }
        print("Behavior: identical, mixed-content, reversed input, empty and singleton groups passed")
    }
}
