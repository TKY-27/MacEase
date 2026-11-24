import AVFoundation
import Foundation

public enum UntrustedMediaAsset {
    /// Forbids QuickTime external media references everywhere.
    public static func make(_ url: URL, preciseTiming: Bool = false) -> AVURLAsset {
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]
        if preciseTiming {
            options[AVURLAssetPreferPreciseDurationAndTimingKey] = true
        }
        return AVURLAsset(url: url, options: options)
    }

    public static func isReferenceForbidden(_ error: (any Error)?) -> Bool {
        var current = error as NSError?
        while let candidate = current {
            if candidate.domain == AVFoundationErrorDomain,
                candidate.code == AVError.Code.referenceForbiddenByReferencePolicy.rawValue
            {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Rejects external references before non-AVAsset readers open.
    public static func rejectExternalReferences(in url: URL) async throws {
        let asset = make(url)
        do {
            _ = try await withTaskCancellationHandler {
                try await asset.load(.isPlayable)
            } onCancel: {
                asset.cancelLoading()
            }
        } catch {
            if isReferenceForbidden(error) {
                throw EngineError.invalidInput(.externalMediaReference)
            }
            throw error
        }
    }
}
