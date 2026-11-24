import Engine

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
