import AVFoundation
import Formats
import Foundation

enum VideoCompressor {
    private static let audioKilobits = [128, 96, 64]
    private static let resolutionSteps = [2160, 1440, 1080, 720, 480]
    private static let containerShare = 0.02
    /// Encoders miss proportionally; aim mid-band.
    private static let correctionAim = 0.96
    private static let minimumBitsPerPixelFrame = 0.04
    private static let reducedFrameRate = 30
    private static let defaultQuality = 0.75
    private static let minimumTargetShare = 0.92
    private static let h264HighProfile: UInt8 = 100

    private struct Destination {
        let container: OutputContainer
        let codec: VideoEncoding.Codec
        let mediaCodec: MediaCodec
        let limits: MediaLimits
        let target: Int64?
        let quality: Double
    }

    static func run(_ compression: VideoCompression, url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try await MediaInput.open(url)
        try input.requireSingleTracksForReplacement()
        guard input.video != nil, input.duration > 0 else {
            throw EngineError.invalidInput(.malformed("video must have a positive duration"))
        }
        let destination = try destination(compression.goal, input: input)
        if let maximum = destination.limits.maxDurationSeconds,
            Double(input.duration) / Double(Nanoseconds.perSecond) > maximum
        {
            throw EngineError.invalidInput(.tooLong(limitSeconds: maximum))
        }
        var edit = try geometry(input, limits: destination.limits)
        var encoding = VideoEncoding(
            codec: destination.codec, width: edit.size?.width ?? input.displaySize.evened().width,
            height: edit.size?.height ?? input.displaySize.evened().height,
            frameDuration: input.frameDuration, bitrate: nil)
        encoding.quality = destination.quality
        let name = url.deletingPathExtension().lastPathComponent + "." + destination.container.fileExtension
        guard let target = destination.target else {
            let plan = TranscodePlan(
                container: destination.container, video: .encode(encoding, edit),
                audio: input.audio == nil ? nil : .encode(.aac, kilobits: audioKilobits[0]))
            let output = try await attempt(input, plan: plan, name: name, context: context)
            return result(output.url, name: name, original: url)
        }
        guard target > 0 else { throw EngineError.invalidInput(.malformed("target bytes must be positive")) }
        var search = TargetSearch(input: input, destination: destination, context: context, name: name, target: target)
        if let copied = try await search.copyIfPossible(edit: edit) { return result(copied, name: name, original: url) }
        let output = try await search.encode(compression, encoding: encoding, edit: &edit)
        return result(output, name: name, original: url)
    }

    private struct TargetSearch {
        let input: MediaInput
        let destination: Destination
        let context: ItemContext
        let name: String
        let target: Int64
        private var smallest = Int64.max

        init(input: MediaInput, destination: Destination, context: ItemContext, name: String, target: Int64) {
            self.input = input
            self.destination = destination
            self.context = context
            self.name = name
            self.target = target
        }

        mutating func copyIfPossible(edit: FrameEdit) async throws -> URL? {
            guard input.video?.codec == destination.mediaCodec, edit.size == input.codedSize, edit.aspect == nil,
                input.transform == .identity || destination.container.fileType != nil
            else { return nil }
            guard try await preservesProfile() else { return nil }
            if input.audio == nil || input.audio?.codec == .aac {
                let plan = TranscodePlan(
                    container: destination.container, video: .copy, audio: input.audio == nil ? nil : .copy)
                if let output = try await accepted(plan) { return output }
            }
            if input.audio != nil {
                for kilobits in audioKilobits {
                    let plan = TranscodePlan(
                        container: destination.container, video: .copy, audio: .encode(.aac, kilobits: kilobits))
                    if let output = try await accepted(plan) { return output }
                }
            }
            return nil
        }

        private func preservesProfile() async throws -> Bool {
            if destination.mediaCodec == .h264 {
                return input.video?.codecPrivate?.dropFirst().first == h264HighProfile
            }
            if case .asset(_, let video?, _) = input.backend {
                let format = try await video.load(.formatDescriptions).first
                return format.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC
            }
            return true
        }

        mutating func encode(_ compression: VideoCompression, encoding initial: VideoEncoding, edit: inout FrameEdit)
            async throws -> URL
        {
            let seconds = Double(input.duration) / Double(Nanoseconds.perSecond)
            let audioBitrate = input.audio == nil ? 0 : audioKilobits[audioKilobits.count - 1] * 1_000
            let budget = Double(target) * 8 / seconds
            let videoBitrate = max(
                1, Int(min(Double(Int.max / 2), max(0, budget * (1 - containerShare) - Double(audioBitrate)))))
            var encoding = initial
            encoding.bitrate = videoBitrate
            while true {
                while belowPixelBudget(encoding), reduce(&encoding, edit: &edit, compression: compression) {}
                if let output = try await encodeAndCorrect(encoding, edit: edit, audioBitrate: audioBitrate) {
                    return output
                }
                // Grain floors encoders; misses step down too.
                guard reduce(&encoding, edit: &edit, compression: compression) else {
                    throw EngineError.targetUnreachable(smallestBytes: smallest)
                }
            }
        }

        private mutating func encodeAndCorrect(_ encoding: VideoEncoding, edit: FrameEdit, audioBitrate: Int)
            async throws -> URL?
        {
            let audio: TranscodePlan.Audio? =
                input.audio == nil ? nil : .encode(.aac, kilobits: audioKilobits[audioKilobits.count - 1])
            let plan = TranscodePlan(container: destination.container, video: .encode(encoding, edit), audio: audio)
            let first = try await attempt(input, plan: plan, name: name, context: context)
            smallest = min(smallest, first.bytes)
            if first.bytes <= target, Double(first.bytes) >= Double(target) * minimumTargetShare { return first.url }
            let underTarget = first.bytes <= target
            if !underTarget { try FileManager.default.removeItem(at: first.url) }
            let ratio = Double(target) * correctionAim / Double(first.bytes)
            let fixedBitrate = Double(audioBitrate)
            let correctedRate = (Double(encoding.bitrate ?? 0) + fixedBitrate) * ratio - fixedBitrate
            var corrected = encoding
            corrected.bitrate = max(1, Int(min(Double(Int.max / 2), max(0, correctedRate))))
            let correction = TranscodePlan(
                container: destination.container, video: .encode(corrected, edit), audio: audio)
            if let output = try await accepted(correction) {
                if underTarget { try FileManager.default.removeItem(at: first.url) }
                return output
            }
            return underTarget ? first.url : nil
        }

        private func belowPixelBudget(_ encoding: VideoEncoding) -> Bool {
            let framesPerSecond = Double(Nanoseconds.perSecond) / Double(encoding.frameDuration)
            let pixelsPerSecond = Double(encoding.width) * Double(encoding.height) * framesPerSecond
            return Double(encoding.bitrate ?? 0) / pixelsPerSecond < minimumBitsPerPixelFrame
        }

        private mutating func accepted(_ plan: TranscodePlan) async throws -> URL? {
            let output = try await attempt(input, plan: plan, name: name, context: context)
            smallest = min(smallest, output.bytes)
            if output.bytes <= target { return output.url }
            try FileManager.default.removeItem(at: output.url)
            return nil
        }
    }

    private static func destination(_ goal: VideoCompression.Goal, input: MediaInput) throws -> Destination {
        var limits = MediaLimits()
        let platform: Bool
        let target: Int64?
        let quality: Double
        switch goal {
        case .bytes(let bytes):
            platform = false
            target = bytes
            quality = defaultQuality
        case .quality(let requested):
            guard requested.isFinite, (0...1).contains(requested) else {
                throw EngineError.invalidInput(.malformed("quality must be between zero and one"))
            }
            platform = false
            target = nil
            quality = requested
        case .platform(let preset):
            guard let video = preset.video else {
                throw EngineError.invalidInput(.malformed("preset has no video limits"))
            }
            limits = video
            platform = true
            target = video.targetBytes
            quality = video.quality.map { Double($0) / 100 } ?? defaultQuality
        }
        let container: OutputContainer = platform ? .mp4 : input.container.holds(.hevc) ? input.container : .mp4
        return Destination(
            container: container, codec: platform ? .h264 : .hevc, mediaCodec: platform ? .h264 : .hevc,
            limits: limits, target: target, quality: quality)
    }

    private static func geometry(_ input: MediaInput, limits: MediaLimits) throws -> FrameEdit {
        guard limits.maxWidth.map({ $0 > 0 }) ?? true,
            limits.maxHeight.map({ $0 > 0 }) ?? true,
            limits.aspect.map(\.isValid) ?? true
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        var edit = FrameEdit(rotation: input.displayRotation, aspect: limits.aspect)
        let natural = try FrameProcessor.outputSize(source: input.codedSize, edit: edit)
        let scale = min(
            1, Double(limits.maxWidth ?? natural.width) / Double(natural.width),
            Double(limits.maxHeight ?? natural.height) / Double(natural.height))
        guard let width = Int(exactly: (Double(natural.width) * scale).rounded(.towardZero)),
            let height = Int(exactly: (Double(natural.height) * scale).rounded(.towardZero))
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        edit.size = PixelSize(width: width, height: height).evened()
        if let aspect = edit.aspect {
            let sourceRatio = Double(input.displaySize.width) / Double(input.displaySize.height)
            if (aspect.min.value...aspect.max.value).contains(sourceRatio) { edit.aspect = nil }
        }
        return edit
    }

    private static func reduce(_ encoding: inout VideoEncoding, edit: inout FrameEdit, compression: VideoCompression)
        -> Bool
    {
        var changed = false
        let cappedDuration = Nanoseconds.perSecond / Int64(reducedFrameRate)
        if compression.allowsFrameRateReduction, encoding.frameDuration < cappedDuration {
            encoding.frameDuration = cappedDuration
            changed = true
        }
        if compression.allowsDownscale,
            let lines = resolutionSteps.first(where: { $0 < min(encoding.width, encoding.height) })
        {
            let scale = Double(lines) / Double(min(encoding.width, encoding.height))
            let size = PixelSize(
                width: Int(Double(encoding.width) * scale), height: Int(Double(encoding.height) * scale)
            ).evened()
            encoding.width = size.width
            encoding.height = size.height
            edit.size = size
            changed = true
        }
        return changed
    }

    private static func attempt(_ input: MediaInput, plan: TranscodePlan, name: String, context: ItemContext)
        async throws -> (url: URL, bytes: Int64)
    {
        try Task.checkCancellation()
        let output = try context.stagingURL(for: input.url, name: name)
        try await Transcoder.run(input, plan: plan, to: output) { context.progress($0) }
        let attributes = try output.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = attributes.fileSize, bytes > 0 else {
            throw EngineError.encodeFailed("empty compression output")
        }
        return (output, Int64(bytes))
    }

    private static func result(_ output: URL, name: String, original: URL) -> ItemResult {
        .replace(original: original, output: StagedFile(url: output, name: name, check: .media))
    }
}
