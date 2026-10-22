public enum FormatError: Error, Equatable, Sendable {
    case nonFiniteAudioSample
    case frameMemoryExceeded
    case inputTooLarge(limitBytes: Int64)
    case corrupt(String)
    case unsupported(String)
    case encoderFailure(String)
    case decoderFailure(String)
    case io(String)
}
