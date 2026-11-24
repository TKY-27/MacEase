import Engine
import Foundation

struct PreviewConversionLimits: Equatable, Sendable {
    static let `default` = Self(
        maximumAudioDuration: 30 * 60,
        maximumVideoDuration: 10 * 60,
        maximumInputBytes: 512 * 1024 * 1024)

    let maximumAudioDuration: TimeInterval
    let maximumVideoDuration: TimeInterval
    let maximumInputBytes: Int64

    func allowsFileSize(_ bytes: Int64) -> Bool {
        bytes > 0 && bytes <= maximumInputBytes
    }

    func allowsDuration(_ seconds: TimeInterval, audioOnly: Bool) -> Bool {
        let limit = audioOnly ? maximumAudioDuration : maximumVideoDuration
        return seconds.isFinite && seconds > 0 && seconds <= limit
    }

    static var fileTooLargeMessage: String {
        String(localized: "This file is too large to convert for preview. Open it in a media player.")
    }

    static var fileTooLongMessage: String {
        String(localized: "This file is too long to convert for preview. Open it in a media player.")
    }
}

enum PreviewMediaRole: Equatable, Sendable {
    case video
    case audio
}

enum PreviewPlaybackRefusal: Equatable, Sendable {
    case restricted
    case contentMismatch(detectedName: String)
    case emptyFile
}

enum PreviewPlaybackDecision: Equatable, Sendable {
    case playable
    case convertible
    case refused(PreviewPlaybackRefusal)

    static func evaluate(
        role: PreviewMediaRole,
        isPlayable: Bool,
        detected: DetectedContent,
        restricted: Bool
    ) -> Self {
        if detected.family == .empty {
            return .refused(.emptyFile)
        }
        if isPlayable {
            return .playable
        }
        let matchesRole =
            switch role {
            case .video: detected.family == .video
            case .audio: detected.family == .audio
            }
        guard matchesRole else {
            return .refused(.contentMismatch(detectedName: detected.displayName))
        }
        if restricted {
            return .refused(.restricted)
        }
        return .convertible
    }
}
