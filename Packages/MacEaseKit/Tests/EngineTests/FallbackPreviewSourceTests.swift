import Foundation
import Testing

@testable import Engine

struct FallbackPreviewSourceTests {
    @Test func nonDecodeNativeFailuresAreRethrownWithoutTouchingTheFile() async throws {
        let missing = URL(filePath: "/nonexistent-\(UUID().uuidString).wmv")
        let staging = StagingArea(supportDirectory: try TestVolume.makeFolder())
        await #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try await FallbackPreviewSource.open(
                missing, audioOnly: false, staging: staging,
                nativeError: EngineError.invalidInput(.externalMediaReference))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await FallbackPreviewSource.open(
                missing, audioOnly: true, staging: staging, nativeError: CancellationError())
        }
    }
}
