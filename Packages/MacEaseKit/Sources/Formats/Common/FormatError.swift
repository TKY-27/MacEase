public enum FormatError: Error, Equatable, Sendable {
    case nonFiniteAudioSample
    case corrupt(String)
    case unsupported(String)
    case encoderFailure(String)
    case decoderFailure(String)
    case io(String)
}
