public enum FormatError: Error, Equatable, Sendable {
    case corrupt(String)
    case unsupported(String)
    case encoderFailure(String)
    case decoderFailure(String)
    case io(String)
}
