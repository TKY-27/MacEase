import AVFAudio
import Foundation
import Testing

@testable import Formats

@Suite(.timeLimit(.minutes(1))) struct DemuxerFuzzTests {
    private static let mutationRounds = 192
    private static let byteFlipRounds = 64
    private static let seed: UInt64 = 0x4D61_6345_6173_6501
    private static let extremes: [UInt64] = [
        0, UInt64.max, UInt64(Int32.max), UInt64(UInt32.max),
        UInt64(bitPattern: Int64.min), UInt64(Int64.max),
    ]
    private static let fixtures = [
        "ffmpeg-mpeg4-ac3-srt.mkv", "ffmpeg-av1.mkv", "ffmpeg-flac-mp3.mka",
        "ffmpeg-mjpeg-pcm.avi", "ffmpeg-mpeg4-ac3.avi", "ffmpeg-h264.avi",
        "ffmpeg-h264-aac.flv", "ffmpeg-vorbis.ogg", "ffmpeg-opus.opus", "ffmpeg-flac.flac",
    ]
    private static let burstFixtures: Set<String> = [
        "ffmpeg-mjpeg-pcm.avi", "ffmpeg-mpeg4-ac3.avi", "ffmpeg-h264-aac.flv", "ffmpeg-mpeg4-ac3-srt.mkv",
    ]
    private static let ebmlMasters: Set<UInt32> = [
        MatroskaID.ebml, MatroskaID.segment, MatroskaID.seekHead, MatroskaID.seek,
        MatroskaID.info, MatroskaID.tracks, MatroskaID.trackEntry, MatroskaID.video, MatroskaID.audio,
        MatroskaID.cluster, MatroskaID.blockGroup, MatroskaID.blockAdditions, MatroskaID.blockMore,
        MatroskaID.contentEncodings, MatroskaID.contentEncoding, MatroskaID.contentCompression,
        MatroskaID.cues, MatroskaID.cuePoint, MatroskaID.cueTrackPositions,
    ]

    private struct Layout {
        var boundaries: Set<Int> = [0]
        var fields: Set<Int> = [0]
        var oggPages: [Range<Int>] = []

        mutating func chunk(_ start: Int, _ payload: Int, _ end: Int) {
            boundaries.formUnion([start, payload, end])
            fields.formUnion([start, payload])
        }
    }

    @Test(arguments: fixtures)
    func fixtureMutations(name: String) throws {
        let sourceURL = try ContainerFixtures.resource(name)
        let original = try Data(contentsOf: sourceURL)
        try readFully(sourceURL, byteCount: original.count)
        let layout = try layout(original, at: sourceURL)
        #expect(layout.boundaries.count > 2)
        try mutate(original, name: name, layout: layout)
    }

    @Test(arguments: ["tiny.avi", "tiny.flv", "tiny.webm", "tiny.ogg", "tiny.opus", "tiny.flac", "tiny.mp3"])
    func syntheticMutations(name: String) throws {
        let original: Data
        switch URL(fileURLWithPath: name).pathExtension {
        case "avi":
            original =
                Data("RIFF".utf8) + [16, 0, 0, 0] + Data("AVI LIST".utf8)
                + [1, 0, 0, 0] + Data("movi".utf8)
        case "flv":
            original =
                Data([0x46, 0x4C, 0x56, 1, 4, 0, 0, 0, 9, 0, 0, 0, 0])
                + [8, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x2F, 0, 0, 0, 0, 13]
        case "webm":
            let track = EBML.element(
                MatroskaID.trackEntry,
                EBML.element(MatroskaID.trackNumber, unsigned: 1)
                    + EBML.element(MatroskaID.trackType, unsigned: 2)
                    + EBML.element(MatroskaID.codecID, string: "A_OPUS"))
            let block = EBML.element(MatroskaID.simpleBlock, [0x81, 0, 0, 0x80, 0xFF])
            original = Data(
                EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "webm"))
                    + EBML.element(
                        MatroskaID.segment,
                        EBML.element(MatroskaID.tracks, track) + EBML.element(MatroskaID.cluster, block)))
        case "ogg", "opus": original = Data("OggS".utf8) + Data(count: 24)
        case "flac": original = Data("fLaC".utf8) + [0x80, 0, 0, 34] + Data(count: 34)
        default: original = Data("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0]
        }
        if name == "tiny.webm" || name == "tiny.flv" {
            let url = ContainerFixtures.temporaryURL(name)
            try original.write(to: url)
            defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
            try readFully(url, byteCount: original.count)
        }
        let layout = Layout(boundaries: Set(0...original.count), fields: Set(original.indices))
        try mutate(original, name: name, layout: layout)
    }

    private func mutate(_ original: Data, name: String, layout: Layout) throws {
        let url = ContainerFixtures.temporaryURL(name)
        try original.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        let cuts = Set(layout.boundaries.flatMap { [$0, max(0, $0 - 1)] }).sorted()
        for cut in cuts {
            try exercise(Data(original.prefix(cut)), at: url)
        }
        let fields = layout.fields.sorted()
        var random = FixtureRandom(seed: Self.seed ^ UInt64(original.count))
        let flipOffsets = fields + (0..<Self.byteFlipRounds).map { _ in Int(random.next() % UInt64(original.count)) }
        for offset in flipOffsets where offset < original.count {
            var mutated = original
            mutated[offset] ^= UInt8(truncatingIfNeeded: random.next()) | 1
            repairChecksums(&mutated, pages: layout.oggPages)
            try exercise(mutated, at: url)
        }
        let widths = [MemoryLayout<UInt32>.size, MemoryLayout<UInt64>.size]
        for round in 0..<Self.mutationRounds {
            var mutated = original
            let width = widths[(round / Self.extremes.count) % widths.count]
            let candidates = fields.filter { $0 + width <= original.count }
            let offset = candidates[Int(random.next() % UInt64(candidates.count))]
            let extreme = Self.extremes[round % Self.extremes.count]
            var replacement = (0..<width).map { UInt8(truncatingIfNeeded: extreme >> ($0 * 8)) }
            if (round / (Self.extremes.count * widths.count)) % 2 != 0 { replacement.reverse() }
            mutated.replaceSubrange(offset..<(offset + width), with: replacement)
            repairChecksums(&mutated, pages: layout.oggPages)
            try exercise(mutated, at: url)
        }
        if Self.burstFixtures.contains(name) {
            var burstRandom = FixtureRandom(seed: UInt64(original.count))
            for round in 0..<150 {
                var damaged = original
                if round % 3 == 0 {
                    damaged = damaged.prefix(Int(burstRandom.next() % UInt64(original.count)))
                } else {
                    for _ in 0..<(1 + Int(burstRandom.next() % 8)) {
                        let position = Int(burstRandom.next() % UInt64(original.count))
                        damaged[position] = round % 3 == 1 ? 0xFF : UInt8(truncatingIfNeeded: burstRandom.next())
                    }
                }
                try damaged.write(to: url)
                do { try readFully(url, byteCount: damaged.count) } catch is FormatError {}
            }
        }
    }

    private func exercise(_ bytes: Data, at url: URL) throws {
        try bytes.write(to: url)
        do {
            try readFully(url, byteCount: bytes.count)
        } catch is FormatError {
        } catch is OggReadError {
        } catch let failure as NSError where failure.domain == NSOSStatusErrorDomain {
        } catch let failure as NSError where failure.domain == "com.apple.coreaudio.avfaudio" {
        }
    }

    private func readFully(_ url: URL, byteCount: Int) throws {
        switch url.pathExtension {
        case "avi":
            var demuxer = try AVIDemuxer(url: url)
            try drain(&demuxer, byteCount: byteCount)
        case "flv":
            var demuxer = try FLVDemuxer(url: url)
            try drain(&demuxer, byteCount: byteCount)
        case "mkv", "mka", "webm":
            var demuxer = try MatroskaDemuxer(url: url)
            try drain(&demuxer, byteCount: byteCount)
        case "ogg", "opus":
            let packets = try OggPacketReader(url: url)
            var packetCount = 0
            while try packets.next() != nil {
                packetCount += 1
                try #require(packetCount <= byteCount + 1, "Ogg packet reader must advance")
            }
            let reader = try OggAudioReader(url: url)
            var reads = 0
            while try reader.read() != nil {
                reads += 1
                try #require(reads <= byteCount + 1, "Ogg audio reader must advance")
            }
        case "flac":
            _ = try FLACMetadata.tags(in: url)
            let audio = try AVAudioFile(forReading: url)
            try AudioMetadata.validate(
                sampleRate: audio.processingFormat.sampleRate, channels: Int(audio.processingFormat.channelCount))
            let capacity: AVAudioFrameCount = 4096
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: capacity))
            var reads = 0
            repeat {
                try audio.read(into: buffer)
                reads += 1
                try #require(reads <= byteCount + 1, "FLAC reader must advance")
            } while buffer.frameLength == capacity
        case "mp3":
            _ = ID3Tag.length(prefix: [UInt8](try Data(contentsOf: url)))
        default: Issue.record("Missing fuzz parser for \(url.pathExtension)")
        }
    }

    private func drain(_ demuxer: inout some MediaDemuxer, byteCount: Int) throws {
        let maximumLacedFrames = Int(UInt8.max) + 1
        let packetLimit = byteCount * maximumLacedFrames + 1
        var packetCount = 0
        while try demuxer.nextPacket() != nil {
            packetCount += 1
            try #require(packetCount <= packetLimit, "Demuxer must advance")
        }
    }

    private func layout(_ bytes: Data, at url: URL) throws -> Layout {
        var layout = Layout()
        layout.boundaries.insert(bytes.count)
        switch url.pathExtension {
        case "avi": scanRIFF(bytes, range: 0..<bytes.count, layout: &layout)
        case "mkv", "mka":
            try scanEBML(RandomAccessFile(url: url), range: 0..<Int64(bytes.count), layout: &layout)
        case "flv":
            var offset = FLV.fileHeaderSize + MemoryLayout<UInt32>.size
            while offset + FLV.tagHeaderSize <= bytes.count {
                let size = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                let payload = offset + FLV.tagHeaderSize
                let end = payload + size + MemoryLayout<UInt32>.size
                layout.chunk(offset, payload, end)
                layout.fields.formUnion([offset + 1, offset + 4])
                guard end <= bytes.count else { break }
                offset = end
            }
        case "ogg", "opus":
            let headerLength = 27
            var offset = 0
            while offset + headerLength <= bytes.count {
                let payload = offset + headerLength + Int(bytes[offset + headerLength - 1])
                guard payload <= bytes.count else { break }
                let end = payload + bytes[(offset + headerLength)..<payload].reduce(0) { $0 + Int($1) }
                guard end <= bytes.count else { break }
                layout.chunk(offset, payload, end)
                layout.fields.formUnion([offset + 6, offset + 14, offset + 18, payload + 8, payload + 12])
                var packetEnd = payload
                for length in bytes[(offset + headerLength)..<payload] {
                    packetEnd += Int(length)
                    if length < UInt8.max { layout.boundaries.insert(packetEnd) }
                }
                layout.oggPages.append(offset..<end)
                offset = end
            }
        case "flac":
            var offset = FLACBlock.marker.count
            while offset + 4 <= bytes.count {
                let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                let end = offset + 4 + length
                layout.chunk(offset, offset + 4, end)
                layout.fields.insert(offset + 1)
                guard bytes[offset] & FLACBlock.lastFlag == 0, end <= bytes.count else { break }
                offset = end
            }
        default: break
        }
        return layout
    }

    private func scanRIFF(_ bytes: Data, range: Range<Int>, layout: inout Layout) {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(UInt32(littleEndian: [UInt8](bytes[offset..<(offset + 8)]), at: 4))
            let payload = offset + 8
            let end = min(payload + size, range.upperBound)
            layout.chunk(offset, payload, end)
            layout.fields.insert(offset + 4)
            let identifier = String(decoding: bytes[offset..<payload - 4], as: UTF8.self)
            if identifier == "RIFF" || identifier == "LIST" {
                if payload + 4 <= end { scanRIFF(bytes, range: (payload + 4)..<end, layout: &layout) }
            } else if ["strh", "strf", "avih", "indx", "idx1"].contains(identifier) {
                layout.fields.formUnion(stride(from: payload, to: end, by: MemoryLayout<UInt32>.size))
            }
            offset = end + size % 2
        }
    }

    private func scanEBML(_ file: RandomAccessFile, range: Range<Int64>, layout: inout Layout) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let header = try EBML.readHeader(file, at: offset)
            let end = min(header.dataStart + (header.size ?? (range.upperBound - header.dataStart)), range.upperBound)
            layout.chunk(Int(offset), Int(header.dataStart), Int(end))
            layout.fields.insert(Int(header.dataStart) - 1)
            if Self.ebmlMasters.contains(header.id) {
                try scanEBML(file, range: header.dataStart..<end, layout: &layout)
            }
            offset = end
        }
    }

    private func repairChecksums(_ bytes: inout Data, pages: [Range<Int>]) {
        let checksumOffset = 22
        let polynomial: UInt32 = 0x04C1_1DB7
        for page in pages {
            let checksumStart = page.lowerBound + checksumOffset
            for octet in 0..<MemoryLayout<UInt32>.size { bytes[checksumStart + octet] = 0 }
            var checksum: UInt32 = 0
            for byte in bytes[page] {
                checksum ^= UInt32(byte) << 24
                for _ in 0..<8 {
                    checksum = checksum & 0x8000_0000 == 0 ? checksum << 1 : (checksum << 1) ^ polynomial
                }
            }
            for octet in 0..<MemoryLayout<UInt32>.size {
                bytes[checksumStart + octet] = UInt8(truncatingIfNeeded: checksum >> (octet * 8))
            }
        }
    }
}
