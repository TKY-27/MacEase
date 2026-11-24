import Foundation
import Testing

@testable import Engine

struct FallbackPreviewSourceTests {
    @Test func nonDecodeNativeFailuresAreRethrownWithoutTouchingTheFile() throws {
        let missing = URL(filePath: "/nonexistent-\(UUID().uuidString).wmv")
        let staging = StagingArea(supportDirectory: try TestVolume.makeFolder())
        #expect(throws: EngineError.invalidInput(.externalMediaReference)) {
            _ = try FallbackPreviewSource.open(
                missing, audioOnly: false, staging: staging,
                nativeError: EngineError.invalidInput(.externalMediaReference))
        }
        #expect(throws: CancellationError.self) {
            _ = try FallbackPreviewSource.open(
                missing, audioOnly: true, staging: staging, nativeError: CancellationError())
        }
    }
}
