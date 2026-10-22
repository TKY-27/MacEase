import AVFoundation

extension AVAssetReaderOutput {
    /// Blocking reads would starve the cooperative pool.
    func nextSample() async -> CMSampleBuffer? {
        nonisolated(unsafe) let output = self
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                nonisolated(unsafe) let sample = output.copyNextSampleBuffer()
                continuation.resume(returning: sample)
            }
        }
    }
}
