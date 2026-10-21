import Foundation
import MenuCatalog
import Testing

@testable import Engine

private let cfr = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Native/cfr.jar")

private func javaTool(_ name: String) throws -> URL? {
    try JavaRuntime.executable()?.deletingLastPathComponent().appending(path: name)
}

private func jdkIsInstalled() throws -> Bool {
    guard let javac = try javaTool("javac") else { return false }
    return FileManager.default.isExecutableFile(atPath: javac.path)
}

private func runTool(_ name: String, _ arguments: [String]) throws {
    let executable: URL = try #require(try javaTool(name))
    let tool = Process()
    tool.executableURL = executable
    tool.arguments = arguments
    try tool.run()
    tool.waitUntilExit()
    #expect(tool.terminationStatus == 0)
}

private func compiledJAR(in folder: URL) throws -> URL {
    let sources = folder.appending(path: "src/demo")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let source = sources.appending(path: "Greeter.java")
    let program = """
        package demo;

        public class Greeter {
            public static String greet(String name) {
                return "Hello, " + name;
            }
        }
        """
    try Data(program.utf8).write(to: source)
    let classes = folder.appending(path: "classes")
    try runTool("javac", ["-d", classes.path, source.path])
    let jar = folder.appending(path: "greeter.jar")
    try runTool("jar", ["--create", "--file", jar.path, "-C", classes.path, "."])
    return jar
}

private func decompileBatch(_ inputs: [URL]) -> Batch {
    OperationPlanner.batch(
        for: OperationRequest(op: .jarDecompile, options: .jar(.decompile(cfr: cfr)), inputs: inputs),
        settings: Settings())
}

private func makeEngine() throws -> JobEngine {
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseJARSupport-\(UUID().uuidString)")
    TestTemporaryFolders.register(support)
    return try JobEngine(supportDirectory: support, concurrency: 2)
}

@Suite(.serialized, .requires(.java, probe: jdkIsInstalled)) struct JARTests {
    @Test func decompilesIntoAFolderNamedAfterTheJAR() async throws {
        let folder = try TestVolume.makeFolder()
        let jar = try compiledJAR(in: folder)

        let outcome = try await makeEngine().run(decompileBatch([jar]), settings: Settings()) { _ in }

        let output = folder.appending(path: "greeter")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        let source = try String(contentsOf: output.appending(path: "demo/Greeter.java"), encoding: .utf8)
        #expect(source.contains("public static String greet(String"))
        #expect(source.contains("return \"Hello, \" + "))
        #expect(FileManager.default.fileExists(atPath: jar.path))
    }

    @Test(arguments: [
        (Array("PK\u{03}\u{04}not a real archive".utf8), "Failed to load jar"),
        ([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18), "CFR produced no Java source"),
    ])
    func failuresReportCFRsErrorTail(contents: [UInt8], expected: String) async throws {
        let jar = try TestVolume.makeFolder().appending(path: "bad.jar")
        try Data(contents).write(to: jar)

        let outcome = try await makeEngine().run(decompileBatch([jar]), settings: Settings()) { _ in }

        guard case .failed(.invalidInput(.malformed(let detail))) = outcome.outcomes.first else {
            Issue.record("expected CFR's error, got \(outcome.outcomes)")
            return
        }
        #expect(detail.contains(expected), "\(detail)")
        #expect(!detail.contains("Processing "))
        #expect(!FileManager.default.fileExists(atPath: jar.deletingPathExtension().path))
    }

    @Test func cancellationLeavesNoOutput() async throws {
        let folder = try TestVolume.makeFolder()
        let jar = try compiledJAR(in: folder)
        let engine = try makeEngine()
        let batch = decompileBatch([jar])

        let run = Task { await engine.run(batch, settings: Settings()) { _ in } }
        run.cancel()
        let outcome = await run.value

        #expect(outcome.outcomes == [.failed(.cancelled)])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "greeter").path))
    }
}

@Suite struct JARPlanningTests {
    @Test func decompileUsesTheBundledCFR() throws {
        let options = try #require(OperationPlanner.options(for: .jarDecompile, preset: nil, settings: Settings()))
        guard case .jar(.decompile(let bundled)) = options else {
            Issue.record("expected a decompile operation, got \(options)")
            return
        }
        #expect(bundled.lastPathComponent == "cfr.jar")
    }
}
