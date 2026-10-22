import Foundation
import Testing

@testable import Engine

@Suite struct BoundedInputTests {
    @Test func chunkedReadersReturnEveryByteIncludingTheFinalPartialBlock() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseInput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = directory.appending(path: "payload")
        let blockBytes = 64 * 1024
        let payload = Data((0..<(3 * blockBytes + 1)).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: source)
        #expect(try ConversionInput.read(source, limit: Int64(payload.count)) == payload)
        #expect(try EncodedImageInput.read(source) == payload)
        #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: Int64(payload.count - 1)))) {
            _ = try ConversionInput.read(source, limit: Int64(payload.count - 1))
        }
        #expect(try Data(contentsOf: source) == payload)
    }
}
