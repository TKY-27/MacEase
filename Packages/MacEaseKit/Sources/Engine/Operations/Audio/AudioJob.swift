import AVFoundation
import Accelerate
import Formats
import Foundation

/// SPEC 8.10's audio rule, public for video.
public enum AudioTargetSize {
    /// Container framing and index overhead.
    public static let overheadShare = 0.02

    /// The largest fitting supported bitrate.
    public static func kilobits(forBytes bytes: Int64, seconds: Double, supported: [Int]) -> Int? {
        guard seconds.isFinite, seconds > 0, bytes > 0 else { return nil }
        let budget = Double(bytes) * 8 / seconds / 1_000 * (1 - overheadShare)
        return supported.last { Double($0) <= budget }
    }
}

enum AudioJob {
    private struct WaveSizeExtensions {
        let audioBytes: UInt64
        let chunkLengths: [String: [UInt64]]
        var chunkPositions: [String: Int] = [:]

        mutating func resolve(_ name: String, stored: UInt64) throws -> UInt64 {
            guard stored == UInt64(UInt32.max) else { return stored }
            if name == "data" { return audioBytes }
            let position = chunkPositions[name, default: 0]
            guard let lengths = chunkLengths[name], position < lengths.count else {
                throw EngineError.decodeFailed("missing extended audio chunk size")
            }
            chunkPositions[name] = position + 1
            return lengths[position]
        }
    }

    private static let id3Version3: UInt8 = 3
    private static let id3Version4: UInt8 = 4
    private static let id3FooterFlag: UInt8 = 0x10
    private static let id3FrameIDLength = 4
    private static let id3FrameSizeEnd = 8
    private static let id3SynchsafeBits = 7
    private static let byteBits = 8
    private static let cafHeaderBytes = 12
    private static let riffHeaderBytes = 8
    private static let extendedSizeBytes: UInt64 = 28
    private static let extendedSizeEntryBytes: UInt64 = 12
    private static let maxExtendedSizeEntries: UInt64 = 4_096
    private static let cafFirstChunk: UInt64 = 8
    private static let riffFirstChunk: UInt64 = 12
    private static let wavePreservedChunks: Set<String> = [
        "fmt ", "fact", "data", "ds64", "JUNK", "PAD ", "FLLR", "PEAK", "ID3 ", "id3 ",
    ]
    private static let aiffPreservedChunks: Set<String> = [
        "COMM", "SSND", "FVER", "CHAN", "FLLR", "NAME", "AUTH", "(c) ", "ANNO", "COMT", "ID3 ", "id3 ",
    ]
    private static let cafPreservedChunks: Set<String> = [
        "desc", "data", "pakt", "kuki", "chan", "info", "free", "strg",
    ]
    private static let peakCeiling = -1.0
    /// Gain changes below this are inaudible.
    private static let negligibleDecibels = 0.05
    private static let measureShare = 0.5

    static func run(_ operation: AudioOperation, on url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try AudioInput(url: url)
        switch operation {
        case .subtitles(let request):
            let speech = try context.stagingURL(for: url, name: "speech.wav")
            try await encode(
                input, to: AudioTarget(format: .wav, kilobits: 0), at: speech, tags: AudioTags(), context: context)
            return try await Subtitles.export(request, audioFile: speech, nextTo: url, context: context)
        case .convert(let format):
            guard format != input.exactFormat else { return .skipped(.alreadyDone) }
            let target = AudioTarget.defaults(for: format, settings: context.settings.audio)
            return try await replace(url, with: input, target: target, context: context)
        case .compress(.kilobits(let kilobits)):
            let target = AudioTarget(format: try compressedFormat(input, kilobits: kilobits), kilobits: kilobits)
            let result = try await replace(url, with: input, target: target, context: context)
            return try isSmaller(result, than: url) ? result : .skipped(.outputNotSmaller)
        case .compress(.targetBytes(let bytes)):
            return try await compress(url, input: input, toBytes: bytes, context: context)
        case .normalize(let loudness):
            return try await normalize(url, input: input, to: loudness, context: context)
        case .trim(let start, let end):
            return try await trim(url, input: input, start: start, end: end, context: context)
        }
    }

    private static func requirePreservableContent(_ input: AudioInput) async throws {
        if input.container == .mpeg4 {
            let asset = AVURLAsset(url: input.url)
            let tracks = try await asset.load(.tracks)
            let chapters = try await asset.load(.availableChapterLocales)
            guard tracks.count == 1, tracks[0].mediaType == .audio, chapters.isEmpty else {
                throw EngineError.invalidInput(.unpreservedStreams)
            }
        }
        if input.container == .mp3 || input.container == .flac {
            guard try !hasUnpreservedID3Content(input.url) else { throw EngineError.invalidInput(.unpreservedStreams) }
        }
        if input.container == .flac, try FLACMetadata.hasUnpreservedContent(in: input.url) {
            throw EngineError.invalidInput(.unpreservedStreams)
        }
        if input.container == .wave || input.container == .aiff || input.container == .caf,
            try hasUnpreservedChunks(input.url, container: input.container)
        {
            throw EngineError.invalidInput(.unpreservedStreams)
        }
    }

    private static func hasUnpreservedID3Content(
        _ url: URL, startingAt start: UInt64 = 0, within length: UInt64? = nil, requireTag: Bool = false
    ) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try reader.seek(toOffset: start)
        let prefix = [UInt8](try reader.read(upToCount: ID3Tag.headerLength) ?? Data())
        guard let tagLength = ID3Tag.length(prefix: prefix), prefix.count == ID3Tag.headerLength else {
            return requireTag
        }
        if let length, UInt64(tagLength) > length { throw EngineError.decodeFailed("ID3 tag out of range") }
        guard prefix[3] == id3Version3 || prefix[3] == id3Version4 else { return true }
        if prefix[5] & ~id3FooterFlag != 0 { return true }
        let tagEnd = start + UInt64(tagLength - (prefix[5] & id3FooterFlag != 0 ? ID3Tag.headerLength : 0))
        var offset = start + UInt64(ID3Tag.headerLength)
        var artworkCount = 0
        let unpreservedFrames: Set<String> = ["CHAP", "CTOC", "SYLT", "ETCO", "GEOB", "PRIV", "MLLT", "SYTC"]
        while offset + UInt64(ID3Tag.headerLength) <= tagEnd {
            try Task.checkCancellation()
            try reader.seek(toOffset: offset)
            let frame = [UInt8](try reader.read(upToCount: ID3Tag.headerLength) ?? Data())
            guard frame.count == ID3Tag.headerLength else { throw EngineError.decodeFailed("truncated ID3 frame") }
            if frame[0..<id3FrameIDLength].allSatisfy({ $0 == 0 }) { break }
            let name = String(decoding: frame[0..<id3FrameIDLength], as: UTF8.self)
            if unpreservedFrames.contains(name) { return true }
            if name == "APIC" {
                artworkCount += 1
                if artworkCount > 1 { return true }
            }
            if prefix[3] == id3Version4,
                frame[id3FrameIDLength..<id3FrameSizeEnd].contains(where: { $0 & 0x80 != 0 })
            {
                throw EngineError.decodeFailed("ID3 frame size out of range")
            }
            let size = frame[id3FrameIDLength..<id3FrameSizeEnd].reduce(0) {
                $0 << (prefix[3] == id3Version4 ? id3SynchsafeBits : byteBits) | Int($1)
            }
            guard size > 0, UInt64(size) <= tagEnd - offset - UInt64(ID3Tag.headerLength) else {
                throw EngineError.decodeFailed("ID3 frame out of range")
            }
            offset += UInt64(ID3Tag.headerLength + size)
        }
        return false
    }

    private static func hasUnpreservedChunks(_ url: URL, container: AudioContainer) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let fileSize = try reader.seekToEnd()
        var waveSizes = container == .wave ? try extendedWaveSizes(reader, fileSize: fileSize) : nil
        let firstChunk = container == .caf ? cafFirstChunk : riffFirstChunk
        let headerBytes = container == .caf ? cafHeaderBytes : riffHeaderBytes
        var offset = firstChunk
        var audioChunkCount = 0
        while offset <= fileSize, UInt64(headerBytes) <= fileSize - offset {
            try Task.checkCancellation()
            try reader.seek(toOffset: offset)
            let header = [UInt8](try reader.read(upToCount: headerBytes) ?? Data())
            guard header.count == headerBytes else { throw EngineError.decodeFailed("truncated audio chunk") }
            let name = String(decoding: header[0..<4], as: UTF8.self)
            let lengthBytes = header[4..<headerBytes]
            let storedSize =
                container == .wave
                ? lengthBytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                : lengthBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var size = storedSize
            if var sizes = waveSizes {
                if name == "ds64", offset != riffFirstChunk {
                    throw EngineError.decodeFailed("duplicate extended audio sizes")
                }
                if name == "data" {
                    audioChunkCount += 1
                    guard storedSize == UInt64(UInt32.max), audioChunkCount == 1 else {
                        throw EngineError.decodeFailed("invalid extended audio chunk")
                    }
                }
                size = try sizes.resolve(name, stored: storedSize)
                waveSizes = sizes
            }
            guard size <= fileSize - offset - UInt64(headerBytes) else {
                if container == .caf, name == "data", size == UInt64.max { return false }
                throw EngineError.decodeFailed("audio chunk out of range")
            }
            if container == .wave {
                if name == "LIST" {
                    guard size >= 4 else { throw EngineError.decodeFailed("truncated audio list") }
                    let list = [UInt8](try reader.read(upToCount: 4) ?? Data())
                    guard list.count == 4 else { throw EngineError.decodeFailed("truncated audio list") }
                    if String(decoding: list, as: UTF8.self) != "INFO" { return true }
                } else if !wavePreservedChunks.contains(name) {
                    return true
                }
            } else if container == .aiff {
                if !aiffPreservedChunks.contains(name) { return true }
            } else if !cafPreservedChunks.contains(name) {
                return true
            }
            if name == "ID3 " || name == "id3 " {
                if try hasUnpreservedID3Content(
                    url, startingAt: offset + UInt64(headerBytes), within: size, requireTag: true)
                {
                    return true
                }
            }
            offset += UInt64(headerBytes) + size + (container == .caf ? 0 : size % 2)
        }
        guard offset == fileSize else { throw EngineError.decodeFailed("truncated audio chunk") }
        if waveSizes != nil, audioChunkCount != 1 { throw EngineError.decodeFailed("missing extended audio chunk") }
        return false
    }

    private static func extendedWaveSizes(_ reader: FileHandle, fileSize: UInt64) throws -> WaveSizeExtensions? {
        try reader.seek(toOffset: 0)
        let waveHeader = [UInt8](try reader.read(upToCount: 12) ?? Data())
        guard waveHeader.count == 12 else { throw EngineError.decodeFailed("truncated audio header") }
        let magic = String(decoding: waveHeader[0..<4], as: UTF8.self)
        guard magic == "RF64" || magic == "BW64" else { return nil }
        guard waveHeader[4..<8].allSatisfy({ $0 == 0xFF }) else {
            throw EngineError.decodeFailed("invalid extended audio header")
        }
        try reader.seek(toOffset: riffFirstChunk)
        let chunkHeader = [UInt8](try reader.read(upToCount: riffHeaderBytes) ?? Data())
        guard chunkHeader.count == riffHeaderBytes,
            chunkHeader[0..<4].elementsEqual("ds64".utf8)
        else { throw EngineError.decodeFailed("missing extended audio sizes") }
        let littleEndian = { (bytes: ArraySlice<UInt8>) in
            bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        let chunkLength = littleEndian(chunkHeader[4..<8])
        guard fileSize >= riffFirstChunk + UInt64(riffHeaderBytes),
            chunkLength >= extendedSizeBytes,
            chunkLength <= fileSize - riffFirstChunk - UInt64(riffHeaderBytes)
        else {
            throw EngineError.decodeFailed("extended audio sizes out of range")
        }
        let sizes = [UInt8](try reader.read(upToCount: Int(extendedSizeBytes)) ?? Data())
        guard sizes.count == Int(extendedSizeBytes) else {
            throw EngineError.decodeFailed("truncated extended audio sizes")
        }
        let riffLength = littleEndian(sizes[0..<8])
        let audioBytes = littleEndian(sizes[8..<16])
        let entryCount = littleEndian(sizes[24..<28])
        guard riffLength == fileSize - UInt64(riffHeaderBytes),
            entryCount <= maxExtendedSizeEntries,
            entryCount <= (chunkLength - extendedSizeBytes) / extendedSizeEntryBytes,
            chunkLength == extendedSizeBytes + entryCount * extendedSizeEntryBytes
        else { throw EngineError.decodeFailed("invalid extended audio sizes") }
        var chunkLengths: [String: [UInt64]] = [:]
        for _ in 0..<entryCount {
            try Task.checkCancellation()
            let entry = [UInt8](try reader.read(upToCount: Int(extendedSizeEntryBytes)) ?? Data())
            guard entry.count == Int(extendedSizeEntryBytes) else {
                throw EngineError.decodeFailed("truncated extended audio size table")
            }
            let name = String(decoding: entry[0..<4], as: UTF8.self)
            chunkLengths[name, default: []].append(littleEndian(entry[4..<12]))
        }
        return WaveSizeExtensions(audioBytes: audioBytes, chunkLengths: chunkLengths)
    }

    /// Lossless sources become AAC in M4A.
    private static func compressedFormat(_ input: AudioInput, kilobits: Int?) throws -> AudioFormat {
        let format = input.codec.isLossy && input.sameFormat.isLossy ? input.sameFormat : .m4aAAC
        let supported = try format.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels)
        guard format == .mp3, let kilobits, let lowest = supported.first, kilobits < lowest else { return format }
        // The in-house encoder stops at 128 kbps.
        return .m4aAAC
    }

    private static func compress(_ url: URL, input: AudioInput, toBytes bytes: Int64, context: ItemContext)
        async throws -> ItemResult
    {
        guard try fileSize(url) > bytes else { return .skipped(.alreadyDone) }
        try await requirePreservableContent(input)
        guard let seconds = input.duration, seconds > 0 else { throw EngineError.decodeFailed("unknown duration") }
        var format = try compressedFormat(input, kilobits: nil)
        try format.validateLayout(input)
        let tags = try await tags(of: input, context: context)
        var supported = try format.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels)
        var budget = bytes - tagBytes(tags, format: format)
        var planned = AudioTargetSize.kilobits(forBytes: budget, seconds: seconds, supported: supported)
        if planned == nil, format == .mp3 {
            format = .m4aAAC
            try format.validateLayout(input)
            supported = try format.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels)
            budget = bytes - tagBytes(tags, format: format)
            planned = AudioTargetSize.kilobits(forBytes: budget, seconds: seconds, supported: supported)
        }
        guard let minimum = supported.first else {
            throw EngineError.unsupportedCodec("\(format.fileExtension) bitrates")
        }
        let candidates = supported.filter { $0 <= (planned ?? minimum) }.reversed()
        var smallest = Int64.max
        for kilobits in candidates {
            let staged = try context.stagingURL(for: url, name: outputName(for: url, format: format))
            try await encode(
                input, to: AudioTarget(format: format, kilobits: kilobits), at: staged, tags: tags, context: context)
            let size = try fileSize(staged)
            if size <= bytes {
                return .replace(
                    original: url, output: StagedFile(url: staged, name: staged.lastPathComponent, check: .audio))
            }
            smallest = min(smallest, size)
            try FileManager.default.removeItem(at: staged)
        }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }

    private static func tagBytes(_ tags: AudioTags, format: AudioFormat) -> Int64 {
        switch format {
        case .mp3: Int64(ID3Tag.encode(tags).count)
        case .ogg, .opus: Int64(VorbisComment.encode(tags).count)
        default:
            Int64(
                (tags.title?.utf8.count ?? 0) + (tags.artist?.utf8.count ?? 0) + (tags.album?.utf8.count ?? 0)
                    + (tags.artwork?.data.count ?? 0))
        }
    }

    private static func normalize(_ url: URL, input: AudioInput, to target: Double, context: ItemContext)
        async throws -> ItemResult
    {
        guard target.isFinite else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let output = AudioTarget.defaults(for: input.sameFormat, settings: context.settings.audio)
        try output.format.validateLayout(input)
        let meter: LoudnessMeter
        do {
            meter = try LoudnessMeter(sampleRate: input.sampleRate, channels: input.channels)
        } catch {
            throw EngineError.fromAudio(error)
        }
        let source = try input.open()
        var measured: Int64 = 0
        while let chunk = try source.read() {
            try Task.checkCancellation()
            meter.add(chunk)
            measured += Int64(chunk.count / input.channels)
            context.progress(measureShare * fraction(measured, of: input.frameCount))
        }
        guard let loudness = meter.integratedLoudness else { return .skipped(.alreadyDone) }
        let wanted = target - loudness
        let gain = min(wanted, peakCeiling - meter.truePeak)
        guard abs(gain) >= negligibleDecibels else { return .skipped(.alreadyDone) }
        if wanted - gain >= negligibleDecibels {
            context.warn(.loudnessLimitedByPeak(reachedLUFS: loudness + gain))
        }
        return try await replace(
            url, with: input, target: output, gain: Float(pow(10, gain / 20)), progressStart: measureShare,
            context: context)
    }

    private static func trim(_ url: URL, input: AudioInput, start: Double, end: Double, context: ItemContext)
        async throws -> ItemResult
    {
        guard start.isFinite, end.isFinite,
            let first = Int64(exactly: (max(start, 0) * input.sampleRate).rounded()),
            var last = Int64(exactly: (end * input.sampleRate).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        if let total = input.frameCount {
            if first == 0, last >= total { return .skipped(.alreadyDone) }
            last = min(last, total)
        }
        guard last > first else { throw EngineError.invalidInput(.malformed("the trim range is empty")) }
        let target = AudioTarget.defaults(for: input.sameFormat, settings: context.settings.audio)
        return try await replace(url, with: input, target: target, frames: first..<last, context: context)
    }

    private static func replace(
        _ url: URL, with input: AudioInput, target: AudioTarget, frames: Range<Int64>? = nil, gain: Float = 1,
        progressStart: Double = 0, context: ItemContext
    ) async throws -> ItemResult {
        try await requirePreservableContent(input)
        try target.format.validateLayout(input)
        if input.bitDepth == 32, !input.isFloat, !target.format.isLossy {
            throw EngineError.unsupportedCodec(
                String(localized: "32-bit integer audio to lossless output", comment: "Refuses integer precision loss"))
        }
        let tags = try await tags(of: input, context: context)
        if !tags.isEmpty, !target.format.holdsTags {
            guard context.settings.outputMode == .newFile else { throw EngineError.audioMetadataUnsupported }
            context.warn(.metadataDropped)
        }
        let staged = try context.stagingURL(for: url, name: outputName(for: url, format: target.format))
        try await encode(
            input, to: target, at: staged, tags: tags, frames: frames, gain: gain, progressStart: progressStart,
            context: context)
        return .replace(original: url, output: StagedFile(url: staged, name: staged.lastPathComponent, check: .audio))
    }

    private static func tags(of input: AudioInput, context: ItemContext) async throws -> AudioTags {
        do {
            return try await input.tags()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard context.settings.outputMode == .newFile else { throw EngineError.audioMetadataUnsupported }
            context.warn(.metadataDropped)
            return AudioTags()
        }
    }

    private static func encode(
        _ input: AudioInput, to target: AudioTarget, at staged: URL, tags: AudioTags, frames: Range<Int64>? = nil,
        gain: Float = 1, progressStart: Double = 0, context: ItemContext
    ) async throws {
        let source = try input.open()
        let encoder = try AudioFileEncoder(
            url: staged, target: target, sampleRate: input.sampleRate, channels: input.channels,
            bitDepth: input.bitDepth, isFloat: input.isFloat, tags: tags)
        let channels = input.channels
        let total = frames.map { Int64($0.count) } ?? input.frameCount
        var position: Int64 = 0
        var written: Int64 = 0
        while let chunk = try source.read() {
            try Task.checkCancellation()
            let count = Int64(chunk.count / channels)
            let range = frames ?? 0..<Int64.max
            let lower = max(range.lowerBound - position, 0)
            let upper = min(range.upperBound - position, count)
            position += count
            guard upper > lower else {
                if position >= range.upperBound { break }
                continue
            }
            var samples = Array(chunk[Int(lower) * channels..<Int(upper) * channels])
            if gain != 1 { vDSP.multiply(gain, samples, result: &samples) }
            try await encoder.write(samples)
            written += upper - lower
            context.progress(progressStart + (1 - progressStart) * fraction(written, of: total))
        }
        try await encoder.finish()
    }

    private static func outputName(for url: URL, format: AudioFormat) -> String {
        let pathExtension = url.pathExtension
        let kept = format.keptExtensions.contains(pathExtension.lowercased()) ? pathExtension : format.fileExtension
        return url.deletingPathExtension().lastPathComponent + "." + kept
    }

    private static func fraction(_ done: Int64, of total: Int64?) -> Double {
        guard let total, total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private static func isSmaller(_ result: ItemResult, than original: URL) throws -> Bool {
        guard case .replace(_, let output) = result else { return true }
        return try fileSize(output.url) < fileSize(original)
    }
}

extension AudioInput {
    /// What same-format operations write.
    var sameFormat: AudioFormat {
        switch (container, codec) {
        case (.mp3, _): .mp3
        case (.adts, _): .aac
        case (.wave, _): .wav
        case (.aiff, _): .aiff
        case (.flac, _): .flac
        case (.ogg, .opus): .opus
        case (.ogg, _): .ogg
        case (.caf, .pcm): .cafPCM
        case (.caf, .alac), (.caf, .flac): .cafALAC
        case (.mpeg4, .alac), (.mpeg4, .flac), (.mpeg4, .pcm): .m4aALAC
        default: .m4aAAC
        }
    }
}

extension AudioFormat {
    var holdsTags: Bool {
        switch self {
        case .mp3, .m4aAAC, .m4aALAC, .flac, .ogg, .opus: true
        default: false
        }
    }
}
