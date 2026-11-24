import AVFoundation
import Formats
import Foundation

enum RemuxContainer: Hashable, Sendable {
    case mov
    case mp4
    case m4v
    case mkv
    case webm
    case avi
    case flv
    case m4a
    case mp3
    case opus
    case otherAudio

    init(_ container: OutputContainer) {
        switch container {
        case .mov: self = .mov
        case .mp4: self = .mp4
        case .m4v: self = .m4v
        case .mkv: self = .mkv
        case .webm: self = .webm
        case .avi: self = .avi
        case .flv: self = .flv
        }
    }

    init(_ format: AudioFormat) {
        switch format {
        case .m4aAAC, .m4aALAC: self = .m4a
        case .mp3: self = .mp3
        case .opus: self = .opus
        default: self = .otherAudio
        }
    }

    var muxerName: String? {
        switch self {
        case .mov: "mov"
        case .mp4: "mp4"
        case .m4v, .m4a: "ipod"
        case .mkv: "matroska"
        case .webm: "webm"
        case .mp3: "mp3"
        case .opus: "ogg"
        case .avi, .flv, .otherAudio: nil
        }
    }

    var fileExtension: String {
        switch self {
        case .mov: "mov"
        case .mp4: "mp4"
        case .m4v: "m4v"
        case .mkv: "mkv"
        case .webm: "webm"
        case .avi: "avi"
        case .flv: "flv"
        case .m4a: "m4a"
        case .mp3: "mp3"
        case .opus: "opus"
        case .otherAudio: "bin"
        }
    }

    var usesISOBMFFMetadata: Bool {
        switch self {
        case .mov, .mp4, .m4v, .m4a: true
        default: false
        }
    }
}

enum StreamCarryCategory: Hashable, Sendable {
    case timecode
    case textSubtitle
    case bitmapSubtitle
    case chapter
    case attachment
    case closedCaption
    case metadata
    case otherData
    case video
    case audio
}

enum StreamCarryAction: Equatable, Sendable {
    case copy
    case convert(codec: String)
    case regenerateTimecode
    case cannotCarry
}

enum StreamCarryTable {
    static let textSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "ttml",
        "jacosub", "microdvd", "mpl2", "pjs", "realtext", "sami", "stl",
        "subviewer", "subviewer1", "vplayer",
    ]
    static let bitmapSubtitleCodecs: Set<String> = [
        "dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle",
    ]

    private static let nativeSubtitleCodecs: [RemuxContainer: Set<String>] = [
        .mov: ["mov_text"],
        .mp4: ["mov_text"],
        .m4v: ["mov_text"],
        .mkv: ["subrip", "srt", "ass", "ssa", "webvtt"],
        .webm: ["webvtt"],
    ]

    private static let entries: [RemuxContainer: [StreamCarryCategory: StreamCarryAction]] = [
        .mov: [
            .timecode: .copy,
            .textSubtitle: .convert(codec: "mov_text"),
            .chapter: .copy,
        ],
        .mp4: [
            .timecode: .regenerateTimecode,
            .textSubtitle: .convert(codec: "mov_text"),
            .chapter: .copy,
        ],
        .m4v: [
            .textSubtitle: .convert(codec: "mov_text"),
            .chapter: .copy,
        ],
        .mkv: [
            .textSubtitle: .convert(codec: "subrip"),
            .bitmapSubtitle: .copy,
            .chapter: .copy,
            .attachment: .copy,
        ],
        .webm: [
            .textSubtitle: .convert(codec: "webvtt"),
            .chapter: .copy,
        ],
        .m4a: [.chapter: .copy],
        .mp3: [.chapter: .copy],
        .opus: [.chapter: .copy],
    ]

    static func action(for category: StreamCarryCategory, into container: RemuxContainer) -> StreamCarryAction {
        entries[container]?[category] ?? .cannotCarry
    }

    static func subtitleAction(codecName: String?, into container: RemuxContainer) -> StreamCarryAction {
        guard let codec = codecName?.lowercased() else { return .cannotCarry }
        if textSubtitleCodecs.contains(codec) {
            let base = action(for: .textSubtitle, into: container)
            guard base != .cannotCarry else { return .cannotCarry }
            if nativeSubtitleCodecs[container]?.contains(codec) == true { return .copy }
            return base
        }
        if bitmapSubtitleCodecs.contains(codec) {
            return action(for: .bitmapSubtitle, into: container)
        }
        return .cannotCarry
    }

    static func canPotentiallyCarry(_ kinds: [UnpreservedStream], into container: RemuxContainer) -> Bool {
        kinds.contains { kind in
            switch kind {
            case .timecode:
                action(for: .timecode, into: container) != .cannotCarry
            case .subtitle:
                action(for: .textSubtitle, into: container) != .cannotCarry
                    || action(for: .bitmapSubtitle, into: container) != .cannotCarry
            case .chapter:
                action(for: .chapter, into: container) != .cannotCarry
            case .attachment:
                action(for: .attachment, into: container) != .cannotCarry
            case .closedCaption, .metadata, .data, .video, .audio:
                false
            }
        }
    }
}

struct StreamCarryPlan: Sendable {
    enum TimecodeStrategy: Equatable, Sendable {
        case copy(streamIndexes: [Int], expectedStartValues: [String])
        case regenerate(startValue: String)
    }

    struct SubtitleMapping: Equatable, Sendable {
        let sourceIndex: Int
        let sourceCodec: String
        let action: StreamCarryAction
        let expectsPackets: Bool

        var expectedOutputCodec: String {
            let raw: String =
                switch action {
                case .copy: sourceCodec
                case .convert(let codec): codec
                case .regenerateTimecode, .cannotCarry: sourceCodec
                }
            switch raw {
            case "srt": return "subrip"
            case "ssa": return "ass"
            default: return raw
            }
        }
    }

    struct ExpectedChapter: Equatable, Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let title: String
    }

    let container: RemuxContainer
    let carriedKinds: Set<UnpreservedStream>
    let uncarriableKinds: [UnpreservedStream]
    let timecode: TimecodeStrategy?
    let subtitles: [SubtitleMapping]
    let chapters: [ExpectedChapter]
    let attachmentIndexes: [Int]
    let sourceDurationSeconds: Double?

    var needsRemux: Bool { !carriedKinds.isEmpty }

    static func none(container: RemuxContainer, uncarriable: [UnpreservedStream]) -> StreamCarryPlan {
        StreamCarryPlan(
            container: container, carriedKinds: [], uncarriableKinds: uncarriable,
            timecode: nil, subtitles: [], chapters: [], attachmentIndexes: [], sourceDurationSeconds: nil)
    }

    func requireConsent(omitting consented: Set<UnpreservedStream>, context: ItemContext?) throws {
        let unconsented = uncarriableKinds.filter { !consented.contains($0) }
        if !unconsented.isEmpty { throw EngineError.invalidInput(.unpreservedStreams(unconsented)) }
        if !uncarriableKinds.isEmpty { context?.warnStreamsOmitted(uncarriableKinds) }
    }

    func withoutTimecode() -> StreamCarryPlan {
        guard carriedKinds.contains(.timecode) else { return self }
        var remainingCarried = carriedKinds
        remainingCarried.remove(.timecode)
        let updatedUncarriable = UnpreservedStream.allCases.filter {
            $0 == .timecode || uncarriableKinds.contains($0)
        }
        return StreamCarryPlan(
            container: container, carriedKinds: remainingCarried, uncarriableKinds: updatedUncarriable,
            timecode: nil, subtitles: subtitles, chapters: chapters, attachmentIndexes: attachmentIndexes,
            sourceDurationSeconds: sourceDurationSeconds)
    }
}

enum StreamRemuxer {
    private static let microsecondsPerSecond = 1_000_000.0
    private static let chapterTimeToleranceSeconds = 0.05
    private static let durationToleranceSeconds = 1.0
    private static let fileProtocol = "file"
    private static let timecodePattern = #"^\d{2}:\d{2}:\d{2}[:;]\d{2}$"#

    struct Probe: Decodable {
        let streams: [Stream]
        let chapters: [Chapter]?
        let format: Format?

        struct Stream: Decodable {
            let index: Int
            let codecType: String
            let codecName: String?
            let codecTagString: String?
            let frameCount: String?
            let readPackets: String?
            let duration: String?
            let disposition: [String: Int]?
            let tags: [String: String]?

            enum CodingKeys: String, CodingKey {
                case index
                case codecType = "codec_type"
                case codecName = "codec_name"
                case codecTagString = "codec_tag_string"
                case frameCount = "nb_frames"
                case readPackets = "nb_read_packets"
                case duration
                case disposition
                case tags
            }

            var isAttachedPicture: Bool { disposition?["attached_pic"] == 1 }
            var isTimecode: Bool { codecType == "data" && codecTagString?.lowercased() == "tmcd" }
            var parsedFrameCount: Int? { frameCount.flatMap(Int.init) }
            var parsedReadPackets: Int? { readPackets.flatMap(Int.init) }
            var parsedDuration: Double? { duration.flatMap(Double.init) }
            var timecodeTag: String? {
                tags?.first { $0.key.lowercased() == "timecode" }?.value
            }
        }

        struct Chapter: Decodable {
            let startTime: String?
            let endTime: String?
            let tags: [String: String]?

            enum CodingKeys: String, CodingKey {
                case startTime = "start_time"
                case endTime = "end_time"
                case tags
            }

            var parsedStart: Double? { startTime.flatMap(Double.init) }
            var parsedEnd: Double? { endTime.flatMap(Double.init) }
            var title: String {
                tags?.first { $0.key.lowercased() == "title" }?.value ?? ""
            }
        }

        struct Format: Decodable {
            let duration: String?
            var parsedDuration: Double? { duration.flatMap(Double.init) }
        }
    }

    static func plan(
        for input: MediaInput, destination: OutputContainer, preservesTiming: Bool
    ) async throws -> StreamCarryPlan {
        if input.hasMultipleTracks { throw EngineError.invalidInput(.multipleTracks) }
        _ = try VideoDisplayOrientation(input.transform)
        let skipped = MediaInput.unpreservedStreams(from: input.skippedStreams)
        let asset: AVURLAsset? = if case .asset(let sourceAsset, _, _) = input.backend { sourceAsset } else { nil }
        let expectedSubtitles = input.skippedStreams.count {
            if case .track(_, .subtitle) = $0 { true } else { false }
        }
        return try await plan(
            url: input.url, skippedKinds: skipped, expectedSubtitleCount: expectedSubtitles,
            container: RemuxContainer(destination), preservesTiming: preservesTiming, asset: asset)
    }

    static func plan(
        for input: AudioInput, destination: AudioFormat, preservesTiming: Bool
    ) async throws -> StreamCarryPlan {
        let skipped = try await AudioJob.unpreservedStreams(in: input)
        let asset = input.container == .mpeg4 ? AVURLAsset(url: input.url) : nil
        return try await plan(
            url: input.url, skippedKinds: skipped, expectedSubtitleCount: 0,
            container: RemuxContainer(destination), preservesTiming: preservesTiming, asset: asset)
    }

    static func plan(
        url: URL, skippedKinds: [UnpreservedStream], expectedSubtitleCount: Int,
        container: RemuxContainer, preservesTiming: Bool, asset: AVURLAsset?
    ) async throws -> StreamCarryPlan {
        guard preservesTiming, !skippedKinds.isEmpty,
            StreamCarryTable.canPotentiallyCarry(skippedKinds, into: container)
        else {
            return .none(container: container, uncarriable: skippedKinds)
        }
        let probed: Probe
        do {
            let tools = try MediaDownloadTools.resolved()
            probed = try await probe(url, tools: tools, countPackets: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .none(container: container, uncarriable: skippedKinds)
        }
        return try await buildPlan(
            from: probed, skippedKinds: skippedKinds, expectedSubtitleCount: expectedSubtitleCount,
            container: container, asset: asset)
    }

    private static func buildPlan(
        from probed: Probe, skippedKinds: [UnpreservedStream], expectedSubtitleCount: Int,
        container: RemuxContainer, asset: AVURLAsset?
    ) async throws -> StreamCarryPlan {
        var carried: Set<UnpreservedStream> = []
        var timecodeStrategy: StreamCarryPlan.TimecodeStrategy?
        var subtitleMappings: [StreamCarryPlan.SubtitleMapping] = []
        var expectedChapters: [StreamCarryPlan.ExpectedChapter] = []
        var attachmentIndexes: [Int] = []

        for kind in skippedKinds {
            switch kind {
            case .timecode:
                if let strategy = planTimecode(probed, into: container) {
                    timecodeStrategy = strategy
                    carried.insert(.timecode)
                }
            case .subtitle:
                if let mappings = planSubtitles(
                    probed, expectedCount: expectedSubtitleCount, into: container)
                {
                    subtitleMappings = mappings
                    carried.insert(.subtitle)
                }
            case .chapter:
                if let chapters = try await planChapters(probed, into: container, asset: asset) {
                    expectedChapters = chapters
                    carried.insert(.chapter)
                }
            case .attachment:
                if let indexes = planAttachments(probed, into: container) {
                    attachmentIndexes = indexes
                    carried.insert(.attachment)
                }
            case .closedCaption, .metadata, .data, .video, .audio:
                break
            }
        }
        let uncarriable = skippedKinds.filter { !carried.contains($0) }
        return StreamCarryPlan(
            container: container, carriedKinds: carried, uncarriableKinds: uncarriable,
            timecode: timecodeStrategy, subtitles: subtitleMappings, chapters: expectedChapters,
            attachmentIndexes: attachmentIndexes, sourceDurationSeconds: probed.format?.parsedDuration)
    }

    private static func planTimecode(_ probed: Probe, into container: RemuxContainer) -> StreamCarryPlan
        .TimecodeStrategy?
    {
        let action = StreamCarryTable.action(for: .timecode, into: container)
        let streams = probed.streams.filter(\.isTimecode)
        guard !streams.isEmpty else { return nil }
        switch action {
        case .copy:
            let startValues = streams.compactMap(\.timecodeTag)
            guard startValues.count == streams.count,
                startValues.allSatisfy(isValidTimecode)
            else { return nil }
            return .copy(streamIndexes: streams.map(\.index), expectedStartValues: startValues)
        case .regenerateTimecode:
            guard streams.count == 1, let single = streams.first,
                (single.parsedFrameCount ?? 1) <= 1,
                let startValue = single.timecodeTag, isValidTimecode(startValue)
            else { return nil }
            return .regenerate(startValue: startValue)
        case .convert, .cannotCarry:
            return nil
        }
    }

    private static func planSubtitles(
        _ probed: Probe, expectedCount: Int, into container: RemuxContainer
    ) -> [StreamCarryPlan.SubtitleMapping]? {
        let streams = probed.streams.filter { $0.codecType == "subtitle" }
        guard !streams.isEmpty, streams.count >= expectedCount else { return nil }
        var mappings: [StreamCarryPlan.SubtitleMapping] = []
        for stream in streams {
            let action = StreamCarryTable.subtitleAction(codecName: stream.codecName, into: container)
            guard action != .cannotCarry, let codec = stream.codecName?.lowercased() else { return nil }
            let expectsPackets = (stream.parsedFrameCount ?? 1) > 0
            mappings.append(
                StreamCarryPlan.SubtitleMapping(
                    sourceIndex: stream.index, sourceCodec: codec, action: action, expectsPackets: expectsPackets))
        }
        return mappings
    }

    private static func planChapters(
        _ probed: Probe, into container: RemuxContainer, asset: AVURLAsset?
    ) async throws -> [StreamCarryPlan.ExpectedChapter]? {
        guard StreamCarryTable.action(for: .chapter, into: container) == .copy,
            let chapters = probed.chapters, !chapters.isEmpty
        else { return nil }
        var expected: [StreamCarryPlan.ExpectedChapter] = []
        for chapter in chapters {
            guard let start = chapter.parsedStart, let end = chapter.parsedEnd,
                start.isFinite, end.isFinite, end >= start
            else { return nil }
            expected.append(StreamCarryPlan.ExpectedChapter(startSeconds: start, endSeconds: end, title: chapter.title))
        }
        // Refuse when FFmpeg drops mebx chapter titles.
        if let asset, expected.allSatisfy(\.title.isEmpty),
            try await assetHasTitledChapters(asset)
        {
            return nil
        }
        return expected
    }

    private static func assetHasTitledChapters(_ asset: AVURLAsset) async throws -> Bool {
        let locales = try await asset.load(.availableChapterLocales)
        for locale in locales {
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])
            for group in groups {
                for entry in group.items
                where entry.commonKey == .commonKeyTitle || entry.identifier == .commonIdentifierTitle {
                    if let title = try await entry.load(.stringValue), !title.isEmpty { return true }
                }
            }
        }
        return false
    }

    private static func planAttachments(_ probed: Probe, into container: RemuxContainer) -> [Int]? {
        guard StreamCarryTable.action(for: .attachment, into: container) == .copy else { return nil }
        let streams = probed.streams.filter { $0.codecType == "attachment" }
        guard !streams.isEmpty else { return nil }
        return streams.map(\.index)
    }

    static func apply(
        _ plan: StreamCarryPlan, to stagedURL: URL, original: URL, hasVideo: Bool, hasAudio: Bool,
        context: ItemContext
    ) async throws {
        guard plan.needsRemux else { return }
        let remuxedURL = stagedURL.deletingLastPathComponent().appending(
            path: "remuxed-\(UUID().uuidString).\(plan.container.fileExtension)")
        do {
            try await performRemuxAndVerify(
                plan, stagedURL: stagedURL, original: original, remuxedURL: remuxedURL,
                hasVideo: hasVideo, hasAudio: hasAudio, context: context)
            try Task.checkCancellation()
            _ = try FileManager.default.replaceItemAt(stagedURL, withItemAt: remuxedURL)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: remuxedURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: remuxedURL)
            let unconsented = UnpreservedStream.allCases.filter {
                plan.carriedKinds.contains($0) && !context.omittedStreams.contains($0)
            }
            if !unconsented.isEmpty {
                throw EngineError.invalidInput(.unpreservedStreams(unconsented))
            }
            context.warnStreamsOmitted(UnpreservedStream.allCases.filter(plan.carriedKinds.contains))
        }
    }

    private static func performRemuxAndVerify(
        _ plan: StreamCarryPlan, stagedURL: URL, original: URL, remuxedURL: URL,
        hasVideo: Bool, hasAudio: Bool, context: ItemContext
    ) async throws {
        let tools = try MediaDownloadTools.resolved()
        let beforeHash = try await streamHash(of: stagedURL, tools: tools)
        let stagedProbe = try await probe(stagedURL, tools: tools, countPackets: false)
        let hasStagedArtwork = !hasVideo && stagedProbe.streams.contains(where: \.isAttachedPicture)
        let arguments = try buildArguments(
            plan: plan, stagedURL: stagedURL, original: original, remuxedURL: remuxedURL,
            hasVideo: hasVideo, hasAudio: hasAudio, hasStagedArtwork: hasStagedArtwork)
        let duration = plan.sourceDurationSeconds ?? stagedProbe.format?.parsedDuration
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg, arguments: arguments,
            directory: stagedURL.deletingLastPathComponent(), tools: tools, captureOutput: false
        ) { line in
            guard line.hasPrefix("out_time_us="), let duration, duration > 0,
                let microseconds = Double(line.dropFirst("out_time_us=".count))
            else { return }
            context.progress(microseconds / microsecondsPerSecond / duration)
        }
        if plan.container.usesISOBMFFMetadata {
            try ISOBMFFMetadataPatcher.copyMetadata(from: stagedURL, to: remuxedURL)
        }
        try await verifyRemux(
            plan: plan, remuxedURL: remuxedURL, beforeHash: beforeHash,
            stagedDuration: stagedProbe.format?.parsedDuration,
            hasVideo: hasVideo, hasAudio: hasAudio, tools: tools)
    }

    static func buildArguments(
        plan: StreamCarryPlan, stagedURL: URL, original: URL, remuxedURL: URL,
        hasVideo: Bool, hasAudio: Bool, hasStagedArtwork: Bool
    ) throws -> [String] {
        guard let muxer = plan.container.muxerName else {
            throw EngineError.encodeFailed("unsupported remux container")
        }
        var arguments = [
            "-hide_banner", "-nostdin", "-v", "error", "-n",
            "-protocol_whitelist", fileProtocol, "-i", safeFilePath(stagedURL),
            "-protocol_whitelist", fileProtocol, "-i", safeFilePath(original),
        ]
        if hasVideo { arguments += ["-map", "0:V:0"] }
        if hasAudio { arguments += ["-map", "0:a:0"] }
        if hasStagedArtwork { arguments += ["-map", "0:v:0", "-disposition:v:0", "attached_pic"] }
        arguments += ["-map_metadata", "0"]
        arguments += plan.chapters.isEmpty ? ["-map_chapters", "-1"] : ["-map_chapters", "1"]
        if hasVideo || hasStagedArtwork { arguments += ["-c:v", "copy"] }
        if hasAudio { arguments += ["-c:a", "copy"] }

        if let timecode = plan.timecode {
            switch timecode {
            case .copy(let indexes, _):
                for index in indexes { arguments += ["-map", "1:\(index)"] }
                arguments += ["-c:d", "copy"]
            case .regenerate(let startValue):
                arguments += ["-timecode", startValue]
            }
        }
        for (outputIndex, subtitle) in plan.subtitles.enumerated() {
            arguments += ["-map", "1:\(subtitle.sourceIndex)"]
            switch subtitle.action {
            case .copy:
                arguments += ["-c:s:\(outputIndex)", "copy"]
            case .convert(let codec):
                arguments += ["-c:s:\(outputIndex)", codec]
            case .regenerateTimecode, .cannotCarry:
                throw EngineError.encodeFailed("invalid subtitle carry action")
            }
        }
        if !plan.attachmentIndexes.isEmpty {
            for index in plan.attachmentIndexes { arguments += ["-map", "1:\(index)"] }
            arguments += ["-c:t", "copy"]
        }
        if plan.container == .mp3 {
            arguments += ["-id3v2_version", "3", "-write_xing", "1"]
        }
        arguments += ["-progress", "pipe:1", "-nostats", "-f", muxer, safeFilePath(remuxedURL)]
        return arguments
    }

    private static func verifyRemux(
        plan: StreamCarryPlan, remuxedURL: URL, beforeHash: String, stagedDuration: Double?,
        hasVideo: Bool, hasAudio: Bool, tools: MediaDownloadTools
    ) async throws {
        let afterHash = try await streamHash(of: remuxedURL, tools: tools)
        guard !beforeHash.isEmpty, afterHash == beforeHash else {
            throw EngineError.encodeFailed("remux modified video or audio packets")
        }
        let remuxProbe = try await probe(remuxedURL, tools: tools, countPackets: !plan.subtitles.isEmpty)
        if let expectedDuration = stagedDuration, let actualDuration = remuxProbe.format?.parsedDuration {
            guard abs(actualDuration - expectedDuration) <= durationToleranceSeconds else {
                throw EngineError.encodeFailed("remux duration diverged")
            }
        }
        if let timecode = plan.timecode {
            let outputTimecodes = remuxProbe.streams.filter(\.isTimecode)
            let expectedValues: [String] =
                switch timecode {
                case .copy(_, let values): values
                case .regenerate(let value): [value]
                }
            guard outputTimecodes.count == expectedValues.count,
                outputTimecodes.compactMap(\.timecodeTag) == expectedValues
            else {
                throw EngineError.encodeFailed("remux did not preserve timecode")
            }
            if let expectedDuration = stagedDuration {
                for stream in outputTimecodes {
                    if let actualDuration = stream.parsedDuration,
                        abs(actualDuration - expectedDuration) > durationToleranceSeconds
                    {
                        throw EngineError.encodeFailed("remux timecode duration diverged")
                    }
                }
            }
        }
        if !plan.subtitles.isEmpty {
            let outputSubtitles = remuxProbe.streams.filter { $0.codecType == "subtitle" }
            guard outputSubtitles.count == plan.subtitles.count else {
                throw EngineError.encodeFailed("remux subtitle stream count mismatch")
            }
            for (expected, actual) in zip(plan.subtitles, outputSubtitles) {
                guard actual.codecName?.lowercased() == expected.expectedOutputCodec else {
                    throw EngineError.encodeFailed("remux subtitle codec mismatch")
                }
                if expected.expectsPackets {
                    let count = actual.parsedReadPackets ?? actual.parsedFrameCount ?? 0
                    guard count > 0 else {
                        throw EngineError.encodeFailed("remux subtitle stream has no packets")
                    }
                }
            }
        }
        if !plan.chapters.isEmpty {
            let actualChapters = remuxProbe.chapters ?? []
            guard actualChapters.count == plan.chapters.count else {
                throw EngineError.encodeFailed("remux chapter count mismatch")
            }
            for (expected, actual) in zip(plan.chapters, actualChapters) {
                guard let start = actual.parsedStart, let end = actual.parsedEnd,
                    abs(start - expected.startSeconds) <= chapterTimeToleranceSeconds,
                    abs(end - expected.endSeconds) <= chapterTimeToleranceSeconds,
                    actual.title == expected.title
                else {
                    throw EngineError.encodeFailed("remux chapter metadata diverged")
                }
            }
        }
        if !plan.attachmentIndexes.isEmpty {
            let outputAttachments = remuxProbe.streams.filter { $0.codecType == "attachment" }
            guard outputAttachments.count == plan.attachmentIndexes.count else {
                throw EngineError.encodeFailed("remux attachment count mismatch")
            }
        }
        if hasVideo {
            let reopened = try await MediaInput.open(remuxedURL)
            guard reopened.video != nil, (reopened.audio != nil) == hasAudio else {
                throw EngineError.encodeFailed("remuxed video tracks do not match engine output")
            }
            let detected = Set(MediaInput.unpreservedStreams(from: reopened.skippedStreams))
            guard plan.carriedKinds.isSubset(of: detected) else {
                throw EngineError.encodeFailed("engine inspection did not see all carried streams")
            }
        } else {
            let reopened = try AudioInput(url: remuxedURL)
            if plan.container != .opus {
                let detected = Set(try await AudioJob.unpreservedStreams(in: reopened))
                guard plan.carriedKinds.isSubset(of: detected) else {
                    throw EngineError.encodeFailed("engine audio inspection did not see all carried streams")
                }
            }
        }
    }

    static func streamHash(of url: URL, tools: MediaDownloadTools) async throws -> String {
        let result = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-hide_banner", "-nostdin", "-v", "error",
                "-protocol_whitelist", fileProtocol, "-i", safeFilePath(url),
                "-map", "0:V?", "-map", "0:a?", "-c", "copy",
                "-f", "streamhash", "-hash", "sha256", "-",
            ],
            directory: url.deletingLastPathComponent(), tools: tools)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func probe(_ url: URL, tools: MediaDownloadTools, countPackets: Bool) async throws -> Probe {
        var arguments = [
            "-v", "error", "-protocol_whitelist", fileProtocol,
            "-show_streams", "-show_chapters", "-show_format", "-of", "json",
        ]
        if countPackets { arguments.insert("-count_packets", at: 2) }
        arguments.append(safeFilePath(url))
        let result = try await MediaToolProcess().run(
            executable: tools.ffprobe, arguments: arguments,
            directory: url.deletingLastPathComponent(), tools: tools)
        return try JSONDecoder().decode(Probe.self, from: result.stdout)
    }

    /// `file:` prevents leading dashes or scheme parsing.
    static func safeFilePath(_ url: URL) -> String {
        fileProtocol + ":" + url.path
    }

    private static func isValidTimecode(_ value: String) -> Bool {
        value.range(of: timecodePattern, options: .regularExpression) != nil
    }
}
