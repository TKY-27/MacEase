import AVFoundation
import Formats
import Foundation

public enum VideoMetadataProperty: String, CaseIterable, Sendable {
    case descriptiveMetadata
    case trackMetadata
    case language
    case volume
    case enabledState
    case alternateGroups
}

struct VideoMetadata {
    private struct TrackAttributes {
        var identifier: CMPersistentTrackID
        var isVideo: Bool
        var metadata: [AVMetadataItem]
        var languageCode: String?
        var extendedLanguageTag: String?
        var preferredVolume: Float
        var isEnabled: Bool
    }

    private let assetMetadata: [AVMetadataItem]
    private let mpeg4Metadata: [AVMetadataItem]
    private let containerMetadata: Set<VideoMetadataProperty>
    private let sourceContainer: OutputContainer?
    private let video: TrackAttributes?
    private let audio: TrackAttributes?
    private let groups: [[CMPersistentTrackID]]

    static func load(from input: MediaInput) async throws -> VideoMetadata {
        guard case .asset(let asset, let videoTrack, let audioTrack) = input.backend else {
            var containerMetadata: Set<VideoMetadataProperty> = []
            if input.hasContainerDescriptiveMetadata { containerMetadata.insert(.descriptiveMetadata) }
            if input.hasContainerTrackMetadata { containerMetadata.insert(.trackMetadata) }
            return VideoMetadata(
                assetMetadata: [], mpeg4Metadata: [], containerMetadata: containerMetadata,
                sourceContainer: input.container,
                video: input.video.map { attributes(of: $0, disabledTrackNumbers: input.disabledTrackNumbers) },
                audio: input.audio.map { attributes(of: $0, disabledTrackNumbers: input.disabledTrackNumbers) },
                groups: [])
        }
        let video: TrackAttributes?
        if let videoTrack { video = try await attributes(of: videoTrack, isVideo: true) } else { video = nil }
        let audio: TrackAttributes?
        if let audioTrack { audio = try await attributes(of: audioTrack, isVideo: false) } else { audio = nil }
        let groups = try await asset.load(.trackGroups).map { $0.trackIDs.map(\.int32Value) }
            .filter { $0.count > 1 }
        let metadata = try await asset.load(.metadata).filter { !isEncodingMetadata($0) }
        var mpeg4Metadata: [AVMetadataItem] = []
        for entry in metadata {
            guard entry.identifier == .quickTimeMetadataLocationISO6709 else {
                mpeg4Metadata.append(entry)
                continue
            }
            let mapped = AVMutableMetadataItem()
            mapped.identifier = .commonIdentifierLocation
            mapped.value = try await entry.load(.value)
            mpeg4Metadata.append(mapped)
        }
        return VideoMetadata(
            assetMetadata: metadata, mpeg4Metadata: mpeg4Metadata, containerMetadata: [],
            sourceContainer: input.container,
            video: video, audio: audio, groups: groups)
    }

    func losses(
        for container: OutputContainer?, includingVideo: Bool = true, includingAudio: Bool
    ) -> [VideoMetadataProperty] {
        let selected = [includingVideo ? video : nil, includingAudio ? audio : nil].compactMap { $0 }
        let selectedIDs = Set(selected.map(\.identifier))
        let relevantGroups = groups.filter { !$0.isEmpty && !$0.allSatisfy { !selectedIDs.contains($0) } }
        var losses: [VideoMetadataProperty] = []
        losses.append(contentsOf: containerMetadata)
        if container?.fileType == nil {
            if !assetMetadata.isEmpty { losses.append(.descriptiveMetadata) }
            if selected.contains(where: { !$0.metadata.isEmpty }) {
                losses.append(.trackMetadata)
            }
            if selected.contains(where: { $0.preferredVolume != ($0.isVideo ? 0 : 1) }) {
                losses.append(.volume)
            }
            if container != .mkv, container != .webm, selected.contains(where: { !$0.isEnabled }) {
                losses.append(.enabledState)
            }
        }
        if container == .mp4 || container == .m4v,
            assetMetadata.contains(where: { $0.identifier == .quickTimeMetadataLocationISO6709 })
        {
            losses.append(.descriptiveMetadata)
        }
        if selected.contains(where: { source in
            let language = source.languageCode
            let hasLanguage = language != nil && language != "und"
            switch container {
            case .mov, .mp4, .m4v:
                return hasLanguage && !Self.isISO639Code(language)
            case .mkv, .webm:
                return source.extendedLanguageTag != nil || (hasLanguage && !Self.isISO639Code(language))
            case .avi, .flv, nil:
                return hasLanguage || source.extendedLanguageTag != nil
            }
        }) {
            losses.append(.language)
        }
        if relevantGroups.contains(where: { group in
            container?.fileType == nil || group.contains(where: { !selectedIDs.contains($0) })
                || Set(group).count != group.count
                || (group.contains(video?.identifier ?? 0) && group.contains(audio?.identifier ?? 0))
        }) {
            losses.append(.alternateGroups)
        }
        let unsupported = Set(losses)
        return VideoMetadataProperty.allCases.filter { unsupported.contains($0) }
    }

    func losses(
        in output: URL, container: OutputContainer, includingAudio: Bool
    ) async throws -> [VideoMetadataProperty] {
        var unsupported = Set(losses(for: container, includingAudio: includingAudio))
        guard container.fileType != nil else {
            if container == .mkv || container == .webm {
                let written = try await MediaInput.open(output)
                for (source, target) in [(video, written.video), (includingAudio ? audio : nil, written.audio)] {
                    guard let source else { continue }
                    if Self.isISO639Code(source.languageCode), source.languageCode != "und",
                        source.languageCode != target?.language
                    {
                        unsupported.insert(.language)
                    }
                    if let target {
                        if source.isEnabled == written.disabledTrackNumbers.contains(target.number) {
                            unsupported.insert(.enabledState)
                        }
                    } else if !source.isEnabled {
                        unsupported.insert(.enabledState)
                    }
                }
            }
            return VideoMetadataProperty.allCases.filter { unsupported.contains($0) }
        }

        let asset = AVURLAsset(url: output)
        if !(try await preserves(assetMetadata, in: asset.load(.metadata), container: container)) {
            unsupported.insert(.descriptiveMetadata)
        }
        let writtenVideo = try await asset.loadTracks(withMediaType: .video).first
        let writtenAudio = includingAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil
        if let video {
            unsupported.formUnion(
                try await trackLosses(video, output: writtenVideo, container: container))
        }
        if includingAudio, let audio {
            unsupported.formUnion(
                try await trackLosses(audio, output: writtenAudio, container: container))
        }
        let sourceIDs = Set([video?.identifier, includingAudio ? audio?.identifier : nil].compactMap { $0 })
        var identifiers: [CMPersistentTrackID: CMPersistentTrackID] = [:]
        if let video, let writtenVideo { identifiers[video.identifier] = writtenVideo.trackID }
        if includingAudio, let audio, let writtenAudio { identifiers[audio.identifier] = writtenAudio.trackID }
        let writtenGroups = try await asset.load(.trackGroups).map { Set($0.trackIDs.map(\.int32Value)) }
        for group in groups where group.contains(where: sourceIDs.contains) {
            let mapped = Set(group.compactMap { identifiers[$0] })
            if mapped.count != group.count || !writtenGroups.contains(mapped) {
                unsupported.insert(.alternateGroups)
            }
        }
        return VideoMetadataProperty.allCases.filter { unsupported.contains($0) }
    }

    private func trackLosses(
        _ source: TrackAttributes, output: AVAssetTrack?, container: OutputContainer
    ) async throws -> Set<VideoMetadataProperty> {
        guard let output else {
            var unsupported: Set<VideoMetadataProperty> = []
            if !source.metadata.isEmpty { unsupported.insert(.trackMetadata) }
            if source.languageCode != nil || source.extendedLanguageTag != nil { unsupported.insert(.language) }
            if source.preferredVolume != (source.isVideo ? 0 : 1) { unsupported.insert(.volume) }
            if !source.isEnabled { unsupported.insert(.enabledState) }
            return unsupported
        }
        let written = try await Self.attributes(of: output, isVideo: source.isVideo)
        var unsupported: Set<VideoMetadataProperty> = []
        if !(try await preserves(source.metadata, in: written.metadata, container: container)) {
            unsupported.insert(.trackMetadata)
        }
        if source.languageCode != nil && source.languageCode != "und"
            && source.languageCode != written.languageCode
            || source.extendedLanguageTag != nil && source.extendedLanguageTag != written.extendedLanguageTag
        {
            unsupported.insert(.language)
        }
        if source.preferredVolume != written.preferredVolume { unsupported.insert(.volume) }
        if source.isEnabled != written.isEnabled { unsupported.insert(.enabledState) }
        return unsupported
    }

    private func preserves(
        _ source: [AVMetadataItem], in output: [AVMetadataItem], container: OutputContainer
    ) async throws -> Bool {
        var remaining = output
        for expected in source {
            var match: Int?
            for index in remaining.indices {
                if try await matches(expected, remaining[index], container: container) {
                    match = index
                    break
                }
            }
            guard let match else { return false }
            remaining.remove(at: match)
        }
        return true
    }

    private func matches(
        _ expected: AVMetadataItem, _ written: AVMetadataItem, container: OutputContainer
    ) async throws -> Bool {
        let exact = expected.identifier != nil && expected.identifier == written.identifier
        let common =
            sourceContainer != container && expected.commonKey != nil
            && expected.commonKey == written.commonKey
        let sourceTag = expected.extendedLanguageTag == "und" ? nil : expected.extendedLanguageTag
        let outputTag = written.extendedLanguageTag == "und" ? nil : written.extendedLanguageTag
        let sourceLocale = expected.locale?.identifier == "und" ? nil : expected.locale?.identifier
        let outputLocale = written.locale?.identifier == "und" ? nil : written.locale?.identifier
        guard (exact || common) && sourceTag == outputTag && sourceLocale == outputLocale else { return false }
        switch (try await expected.load(.value), try await written.load(.value)) {
        case (nil, nil): return true
        case (let original?, let result?): return original.isEqual(result)
        default: return false
        }
    }

    func apply(to tracks: inout [OutputTrack], container: OutputContainer) -> [AVMetadataItem] {
        let selectedIDs = Set(tracks.compactMap { $0.track.isVideo ? video?.identifier : audio?.identifier })
        for index in tracks.indices {
            guard let source = tracks[index].track.isVideo ? video : audio else { continue }
            if Self.isISO639Code(source.languageCode), source.languageCode != "und" {
                tracks[index].track.language = source.languageCode
            }
            tracks[index].isEnabled = source.isEnabled
            guard container.fileType != nil else { continue }
            tracks[index].metadata = source.metadata
            tracks[index].languageCode = Self.isISO639Code(source.languageCode) ? source.languageCode : nil
            tracks[index].extendedLanguageTag = source.extendedLanguageTag
            tracks[index].preferredVolume = source.preferredVolume
            if let group = groups.firstIndex(where: { $0.contains(source.identifier) }),
                groups[group].allSatisfy(selectedIDs.contains),
                !groups[group].contains(video?.identifier ?? 0) || !groups[group].contains(audio?.identifier ?? 0)
            {
                tracks[index].alternateGroup = group
            }
        }
        switch container {
        case .mov: return assetMetadata
        case .mp4, .m4v: return mpeg4Metadata
        case .mkv, .webm, .avi, .flv: return []
        }
    }

    private static func attributes(of track: AVAssetTrack, isVideo: Bool) async throws -> TrackAttributes {
        try await TrackAttributes(
            identifier: track.trackID,
            isVideo: isVideo,
            metadata: track.load(.metadata).filter { !isEncodingMetadata($0) },
            languageCode: track.load(.languageCode),
            extendedLanguageTag: track.load(.extendedLanguageTag),
            preferredVolume: track.load(.preferredVolume),
            isEnabled: track.load(.isEnabled))
    }

    private static func attributes(of track: MediaTrack, disabledTrackNumbers: Set<Int>) -> TrackAttributes {
        TrackAttributes(
            identifier: kCMPersistentTrackID_Invalid, isVideo: track.isVideo, metadata: [],
            languageCode: track.language, extendedLanguageTag: nil, preferredVolume: track.isVideo ? 0 : 1,
            isEnabled: !disabledTrackNumbers.contains(track.number))
    }

    private static func isISO639Code(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.range(of: #"^[a-z]{3}$"#, options: .regularExpression) != nil
    }

    private static func isEncodingMetadata(_ entry: AVMetadataItem) -> Bool {
        switch entry.identifier {
        case .commonIdentifierSoftware, .quickTimeUserDataSoftware, .quickTimeMetadataSoftware,
            .iTunesMetadataEncodingTool, .id3MetadataEncodedWith:
            return true
        default:
            return false
        }
    }
}
