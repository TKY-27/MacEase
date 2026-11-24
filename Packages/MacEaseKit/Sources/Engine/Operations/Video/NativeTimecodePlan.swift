import AVFoundation
import Foundation

struct NativeTimecodePlan: Sendable {
    let carriesTimecode: Bool
    let omittedKinds: [UnpreservedStream]
    private let sourceStamp: MediaSourceStamp?

    static func make(
        for input: MediaInput, destination: OutputContainer, preservesTiming: Bool,
        omitting consented: Set<UnpreservedStream> = []
    ) async throws -> NativeTimecodePlan {
        if input.hasMultipleTracks { throw EngineError.invalidInput(.multipleTracks) }
        _ = try VideoDisplayOrientation(input.transform)
        let skipped = MediaInput.unpreservedStreams(from: input.skippedStreams)
        var carries = false
        let stamp = skipped.contains(.timecode) ? try MediaSourceStamp(url: input.url) : nil
        if destination == .mov, preservesTiming, skipped.contains(.timecode), !consented.contains(.timecode),
            case .asset(let asset, let video?, _) = input.backend
        {
            do {
                let timecode = try await NativeTimecode(asset: asset)
                let probe = try AVAssetWriter(
                    outputURL: FileManager.default.temporaryDirectory.appending(
                        path: "timecode-probe-\(UUID().uuidString).mov"), fileType: .mov)
                let videoInput = AVAssetWriterInput(
                    mediaType: .video, outputSettings: nil,
                    sourceFormatHint: try await video.load(.formatDescriptions).first)
                guard probe.canAdd(videoInput) else { throw EngineError.invalidInput(.unpreservedStreams([.timecode])) }
                probe.add(videoInput)
                try timecode.attach(to: probe, video: videoInput)
                carries = true
            } catch {
                try stamp?.validate(input.url)
                guard case EngineError.invalidInput(.unpreservedStreams([.timecode])) = error else { throw error }
            }
            try stamp?.validate(input.url)
        }
        return NativeTimecodePlan(
            carriesTimecode: carries,
            omittedKinds: skipped.filter { $0 != .timecode || !carries }, sourceStamp: carries ? stamp : nil)
    }

    func requireConsent(omitting consented: Set<UnpreservedStream>, context: ItemContext?) throws {
        let unconsented = omittedKinds.filter { !consented.contains($0) }
        if !unconsented.isEmpty { throw EngineError.invalidInput(.unpreservedStreams(unconsented)) }
        if !omittedKinds.isEmpty { context?.warnStreamsOmitted(omittedKinds) }
    }

    func write(_ input: MediaInput, plan: TranscodePlan, to output: URL, progress: (Double) -> Void) async throws {
        try sourceStamp?.validate(input.url)
        do {
            try await Transcoder.run(input, plan: plan, to: output, progress: progress)
        } catch {
            try sourceStamp?.validate(input.url)
            throw error
        }
        try sourceStamp?.validate(input.url)
    }

    func verify(original: URL, output: URL) async throws {
        guard carriesTimecode else { return }
        try sourceStamp?.validate(original)
        do {
            try await NativeTimecode.verify(original: original, output: output)
        } catch {
            try sourceStamp?.validate(original)
            throw error
        }
        try sourceStamp?.validate(original)
    }
}
