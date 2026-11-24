import Engine

enum PreviewContentMatch: Equatable, Sendable {
    case matches
    case mismatch(detectedName: String)
    case binaryWithTextExtension(detectedName: String)
    case empty

    static func evaluate(kind: PreviewKind, detected: DetectedContent) -> Self {
        if detected.family == .empty { return .empty }
        switch kind {
        case .text, .html, .markdown, .json:
            switch detected.family {
            case .text, .svg: return .matches
            default: return .binaryWithTextExtension(detectedName: detected.displayName)
            }
        case .propertyList:
            switch detected.family {
            case .text, .binaryPropertyList: return .matches
            default: return .binaryWithTextExtension(detectedName: detected.displayName)
            }
        case .svg:
            switch detected.family {
            case .svg: return .matches
            case .text: return .mismatch(detectedName: detected.displayName)
            default: return .binaryWithTextExtension(detectedName: detected.displayName)
            }
        case .image:
            return detected.family == .image ? .matches : .mismatch(detectedName: detected.displayName)
        case .media:
            return detected.family == .video ? .matches : .mismatch(detectedName: detected.displayName)
        case .audio:
            return detected.family == .audio ? .matches : .mismatch(detectedName: detected.displayName)
        case .pdf:
            return detected.family == .pdf ? .matches : .mismatch(detectedName: detected.displayName)
        case .font:
            return detected.family == .font ? .matches : .mismatch(detectedName: detected.displayName)
        case .archive:
            return detected.family == .archive ? .matches : .mismatch(detectedName: detected.displayName)
        case .quickLook:
            return .matches
        }
    }
}
