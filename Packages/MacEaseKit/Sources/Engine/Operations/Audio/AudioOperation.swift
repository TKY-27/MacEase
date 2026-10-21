import Foundation
import MenuCatalog

public enum AudioCompression: Codable, Hashable, Sendable {
    case kilobits(Int)
    /// Decimal bytes, already reduced for presets.
    case targetBytes(Int64)
}

/// Everything one audio run needs, panels included.
public enum AudioOperation: Codable, Hashable, Sendable {
    case subtitles(SubtitleRequest)
    case convert(AudioFormat)
    case compress(AudioCompression)
    /// Target integrated loudness in LUFS.
    case normalize(targetLoudness: Double)
    /// Seconds from the start; `end` is exclusive.
    case trim(start: Double, end: Double)
}

enum AudioPlanner {
    static func options(for op: OperationID, preset: String?, settings: Settings) -> AudioOperation? {
        guard let preset, op.presets.contains(preset) else { return nil }
        switch op {
        case .audioSubtitles:
            return SubtitleRequest.preset(preset, settings: settings.intelligence).map(AudioOperation.subtitles)
        case .audioConvert:
            return AudioFormat(rawValue: preset).map(AudioOperation.convert)
        case .audioCompress:
            return Int(preset).map { .compress(.kilobits($0)) }
        case .audioNormalize:
            let target: Double
            switch preset {
            case "lufs-14": target = settings.audio.loudnessTarget
            case "lufs-16": target = settings.audio.loudnessStreaming
            case "lufs-23": target = settings.audio.loudnessBroadcast
            default: return nil
            }
            guard target.isFinite, AudioSettings.loudnessRange.contains(target) else { return nil }
            return .normalize(targetLoudness: target)
        default:
            return nil
        }
    }

    static func batch(for request: OperationRequest, operation: AudioOperation) -> Batch {
        let items = OperationPlanner.targeted(request.inputs, kind: .audio).map { url in
            OperationPlanner.validated(url, kind: .audio) { context in
                try await AudioJob.run(operation, on: url, context: context)
            }
        }
        return Batch(operation: request.op, items: items)
    }
}
