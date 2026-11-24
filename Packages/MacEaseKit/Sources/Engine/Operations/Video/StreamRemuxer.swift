import AVFoundation
import Formats
import Foundation

struct StreamCarryPlan: Sendable {
    let container: OutputContainer
    let carriedKinds: Set<UnpreservedStream>
    let uncarriableKinds: [UnpreservedStream]
    let subtitleIndexes: [Int]

    var carriesNativeTimecode: Bool { carriedKinds.contains(.timecode) }
    var needsRemux: Bool { !subtitleIndexes.isEmpty }

    static func none(container: OutputContainer, uncarriable: [UnpreservedStream]) -> StreamCarryPlan {
        StreamCarryPlan(container: container, carriedKinds: [], uncarriableKinds: uncarriable, subtitleIndexes: [])
    }

    func requireConsent(omitting consented: Set<UnpreservedStream>, context: ItemContext?) throws {
        let unconsented = uncarriableKinds.filter { !consented.contains($0) }
        if !unconsented.isEmpty { throw EngineError.invalidInput(.unpreservedStreams(unconsented)) }
        if !uncarriableKinds.isEmpty { context?.warnStreamsOmitted(uncarriableKinds) }
    }

}

enum StreamRemuxer {
    private static let fileProtocol = "file"
    private static let defaultMatroskaLanguage = "eng"
    private static let subtitleCodecs: Set<String> = [
        "subrip", "ass", "webvtt", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle",
    ]
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
        let container = destination
        guard preservesTiming else { return .none(container: container, uncarriable: skipped) }
        var carried: Set<UnpreservedStream> = []
        var indexes: [Int] = []
        if destination == .mov, skipped.contains(.timecode),
            case .asset(let asset, _, _) = input.backend,
            !(try await asset.loadTracks(withMediaType: .timecode)).isEmpty
        {
            carried.insert(.timecode)
        }
        if destination == .mkv, input.video?.hasAlpha != true, skipped.contains(.subtitle) {
            do {
                let probed = try await probe(input.url, tools: MediaDownloadTools.resolved(), countPackets: false)
                let subtitles = probed.streams.filter { $0.codecType == "subtitle" }
                let expected = input.skippedStreams.count { if case .track(_, .subtitle) = $0 { true } else { false } }
                if !subtitles.isEmpty, subtitles.count == expected,
                    subtitles.allSatisfy({ $0.codecName.map(subtitleCodecs.contains) == true })
                {
                    indexes = subtitles.map(\.index)
                    carried.insert(.subtitle)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .none(container: container, uncarriable: skipped)
            }
        }
        return StreamCarryPlan(
            container: container, carriedKinds: carried, uncarriableKinds: skipped.filter { !carried.contains($0) },
            subtitleIndexes: indexes)
    }

    static func apply(
        _ plan: StreamCarryPlan, to stagedURL: URL, original: URL, hasVideo: Bool, hasAudio: Bool,
        context: ItemContext
    ) async throws {
        if plan.carriesNativeTimecode {
            try await NativeTimecode.verify(original: original, output: stagedURL)
        }
        guard plan.needsRemux else { return }
        let remuxed = stagedURL.deletingLastPathComponent().appending(path: "remuxed-\(UUID().uuidString).mkv")
        do {
            let tools = try MediaDownloadTools.resolved()
            let before = try await packetProof(stagedURL, tools: tools)
            let subtitles = try await packetProof(original, tools: tools, subtitlesOnly: true)
            _ = try await MediaToolProcess().run(
                executable: tools.ffmpeg,
                arguments: buildArguments(
                    plan: plan, stagedURL: stagedURL, original: original, remuxedURL: remuxed,
                    hasVideo: hasVideo, hasAudio: hasAudio),
                directory: stagedURL.deletingLastPathComponent(), tools: tools, captureOutput: false)
            let after = try await packetProof(remuxed, tools: tools)
            try await verifyRemux(
                before: before, after: after, subtitles: subtitles, plan: plan,
                staged: stagedURL, remuxed: remuxed, hasVideo: hasVideo, hasAudio: hasAudio)
            _ = try FileManager.default.replaceItemAt(stagedURL, withItemAt: remuxed)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: remuxed)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: remuxed)
            let omitted = UnpreservedStream.allCases.filter(plan.carriedKinds.contains)
            let unconsented = omitted.filter { !context.omittedStreams.contains($0) }
            if !unconsented.isEmpty { throw EngineError.invalidInput(.unpreservedStreams(unconsented)) }
            context.warnStreamsOmitted(omitted)
        }
    }

    static func buildArguments(
        plan: StreamCarryPlan, stagedURL: URL, original: URL, remuxedURL: URL,
        hasVideo: Bool, hasAudio: Bool
    ) -> [String] {
        var arguments = [
            "-hide_banner", "-nostdin", "-v", "error", "-n", "-copyts",
            "-protocol_whitelist", fileProtocol, "-i", safeFilePath(stagedURL),
            "-protocol_whitelist", fileProtocol, "-i", safeFilePath(original),
        ]
        if hasVideo { arguments += ["-map", "0:V:0"] }
        if hasAudio { arguments += ["-map", "0:a:0"] }
        for index in plan.subtitleIndexes { arguments += ["-map", "1:\(index)"] }
        arguments += [
            "-map_metadata", "0", "-map_chapters", "-1", "-c", "copy",
            "-avoid_negative_ts", "disabled", "-f", "matroska", safeFilePath(remuxedURL),
        ]
        return arguments
    }

    private struct PacketProof: Decodable {
        let streams: [Stream]
        let packets: [Packet]

        struct Stream: Decodable {
            let index: Int
            let codecType: String
            let codecName: String?
            let extradataHash: String?

            enum CodingKeys: String, CodingKey {
                case index
                case codecType = "codec_type"
                case codecName = "codec_name"
                case extradataHash = "extradata_hash"
            }
        }

        struct Packet: Decodable, Equatable {
            let streamIndex: Int
            let presentationTime: String?
            let decodeTime: String?
            let duration: String?
            let size: String
            let payloadHash: String
            let sideData: [SideData]?

            enum CodingKeys: String, CodingKey {
                case streamIndex = "stream_index"
                case presentationTime = "pts_time"
                case decodeTime = "dts_time"
                case duration = "duration_time"
                case size
                case payloadHash = "data_hash"
                case sideData = "side_data_list"
            }

            struct SideData: Decodable, Equatable {
                let type: String
                let hash: String

                enum CodingKeys: String, CodingKey {
                    case type = "side_data_type"
                    case hash = "data_hash"
                }
            }

            func matches(_ other: Packet, tolerance: Double) -> Bool {
                func sameTime(_ first: String?, _ second: String?) -> Bool {
                    if first == second { return true }
                    guard let left = first.flatMap(Double.init), let right = second.flatMap(Double.init) else {
                        return false
                    }
                    return abs(left - right) <= tolerance
                }
                return (sideData ?? []) == (other.sideData ?? []) && size == other.size
                    && payloadHash == other.payloadHash
                    && sameTime(presentationTime, other.presentationTime) && sameTime(decodeTime, other.decodeTime)
                    && sameTime(duration, other.duration)
            }
        }
    }

    private static func packetProof(_ url: URL, tools: MediaDownloadTools, subtitlesOnly: Bool = false) async throws
        -> PacketProof
    {
        let selection = subtitlesOnly ? ["-select_streams", "s"] : []
        let result = try await MediaToolProcess().run(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-protocol_whitelist", fileProtocol, "-show_streams", "-show_packets",
                "-show_data_hash", "sha256", "-show_entries",
                "stream=index,codec_type,codec_name,extradata_hash:packet=stream_index,pts_time,dts_time,duration_time,size,data_hash:packet_side_data",
                "-of", "json",
            ] + selection + [safeFilePath(url)],
            directory: url.deletingLastPathComponent(), tools: tools)
        return try JSONDecoder().decode(PacketProof.self, from: result.stdout)
    }

    private static func verifyRemux(
        before: PacketProof, after: PacketProof, subtitles: PacketProof, plan: StreamCarryPlan,
        staged: URL, remuxed: URL, hasVideo: Bool, hasAudio: Bool
    ) async throws {
        let original = try await MediaInput.open(staged)
        let reopened = try await MediaInput.open(remuxed)
        guard (reopened.video != nil) == hasVideo, (reopened.audio != nil) == hasAudio,
            original.video?.hasAlpha != true,
            original.video?.codecPrivate == reopened.video?.codecPrivate,
            original.audio?.codecPrivate == reopened.audio?.codecPrivate,
            original.disabledTrackNumbers == reopened.disabledTrackNumbers
        else { throw EngineError.encodeFailed("remux changed codec configuration") }
        let originalTracks = [original.video, original.audio].compactMap { $0 }
        let writtenTracks = [reopened.video, reopened.audio].compactMap { $0 }
        for (source, written) in zip(originalTracks, writtenTracks) {
            var expectedTrack = source
            var normalized = written
            normalized.number = source.number
            if source.codec == .aac, source.defaultDuration == nil,
                normalized.defaultDuration == (try source.aacFrameDuration())
            {
                normalized.defaultDuration = nil
            }
            // Matroska omits its default English language.
            expectedTrack.language = source.language ?? defaultMatroskaLanguage
            normalized.language = written.language ?? defaultMatroskaLanguage
            guard normalized == expectedTrack else {
                throw EngineError.encodeFailed("remux changed track properties")
            }
        }
        guard abs(Double(original.duration) - Double(reopened.duration)) <= Double(original.frameDuration) else {
            throw EngineError.encodeFailed("remux changed presentation duration")
        }
        let primary = before.streams.filter { $0.codecType == "video" || $0.codecType == "audio" }
        let expected =
            primary.map { (proof: before, stream: $0) }
            + plan.subtitleIndexes.compactMap { index in
                subtitles.streams.first { $0.index == index }.map { (proof: subtitles, stream: $0) }
            }
        guard after.streams.count == expected.count else {
            throw EngineError.encodeFailed("remux stream count changed")
        }
        for (source, destination) in zip(expected, after.streams) {
            let tolerance: Double
            if source.stream.codecType == "audio", case .audio(let rate, _) = original.audio?.kind {
                tolerance = 1 / rate
            } else {
                tolerance = 1 / Double(Nanoseconds.perSecond)
            }
            guard source.stream.codecType == destination.codecType,
                source.stream.codecName == destination.codecName,
                source.stream.extradataHash == destination.extradataHash
            else { throw EngineError.encodeFailed("remux changed sample description") }
            let sourcePackets = source.proof.packets.filter { $0.streamIndex == source.stream.index }
            let destinationPackets = after.packets.filter { $0.streamIndex == destination.index }
            guard sourcePackets.count == destinationPackets.count,
                zip(sourcePackets, destinationPackets).allSatisfy({ $0.matches($1, tolerance: tolerance) })
            else { throw EngineError.encodeFailed("remux changed packets or their timing") }
        }
        if hasVideo {
            let sampler = try await FrameSampler(
                input: reopened, frameDuration: reopened.frameDuration,
                edit: FrameEdit(), start: 0, end: .max)
            guard let video = after.streams.first(where: { $0.codecType == "video" }) else {
                throw EngineError.decodeFailed("remux video stream missing")
            }
            let timestamps = after.packets.filter { $0.streamIndex == video.index }
                .compactMap { $0.presentationTime.flatMap(Double.init) }
            guard let first = timestamps.min(), let last = timestamps.max() else {
                throw EngineError.decodeFailed("remux video timing missing")
            }
            for seconds in [first, (first + last) / 2, last] {
                let position = try Nanoseconds.from(seconds: seconds)
                guard try await sampler.next(sourceTime: position, timestamp: position) != nil else {
                    throw EngineError.decodeFailed("remux frame probe failed")
                }
            }
        }
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

}
