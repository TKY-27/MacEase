/// Interleaved 32-bit float samples, read in chunks.
public protocol PCMSource: AnyObject {
    var sampleRate: Double { get }
    var channels: Int { get }
    /// `nil` once the source is exhausted.
    func read() throws -> [Float]?
}
