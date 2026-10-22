import Foundation
import Testing

@testable import Engine

@Suite struct EncodedImageInputTests {
    @Test func oversizedIconFailsBeforeReadingPayload() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let url = folder.appending(path: "oversized.ico")
        let icon = try ImageEncoder.encode(
            [ImageFrame(image: ImageFixtures.disc(size: 16), duration: 0)], as: .ico,
            options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        try icon.write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(EncodedImageInput.maximumBytes) + 1)
        try writer.close()
        await #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: EncodedImageInput.maximumBytes))) {
            _ = try await ImageDocument.load(url)
        }
    }
}
