import Foundation

/// Preserves AVAssetWriter boxes FFmpeg drops on remux.
enum ISOBMFFMetadataPatcher {
    private static let minimumBoxHeaderBytes = 8
    private static let extendedBoxHeaderBytes = 16
    private static let tkhdMinimumV0Bytes = 46
    private static let tkhdMinimumV1Bytes = 58
    private static let tkhdVersionOffset = 8
    private static let tkhdFlagsRange = 9..<12
    private static let tkhdAlternateGroupV0Offset = 42
    private static let tkhdAlternateGroupV1Offset = 54
    private static let tkhdVolumeV0Offset = 44
    private static let tkhdVolumeV1Offset = 56
    private static let hdlrMinimumBytes = 20
    private static let hdlrTypeRange = 16..<20
    private static let maximumMoovBytes: UInt64 = 128 * 1_024 * 1_024

    private struct BoxHeader {
        let kind: String
        let offset: UInt64
        let size: UInt64
        let headerBytes: Int
    }

    private struct MemoryBox {
        let kind: String
        let raw: Data
        let headerBytes: Int

        var payload: Data { Data(raw[headerBytes...]) }
    }

    private struct TrackMetadata {
        let flags: Data
        let alternateGroup: Data
        let volume: Data
        let metaBoxes: [Data]
        let udtaBoxes: [Data]
        let extendedLanguageBox: Data?
    }

    static func copyMetadata(from stagedURL: URL, to remuxedURL: URL) throws {
        let stagedMoov = try readMoovPayload(at: stagedURL)
        let stagedChildren = try parseBoxes(stagedMoov)
        let stagedMeta = stagedChildren.filter { $0.kind == "meta" }.map(\.raw)
        let stagedUdta = stagedChildren.filter { $0.kind == "udta" }.map(\.raw)
        let stagedTracks = try extractTrackMetadata(from: stagedChildren)

        let remuxedFile = try FileHandle(forUpdating: remuxedURL)
        defer { try? remuxedFile.close() }
        let remuxedSize = try remuxedFile.seekToEnd()
        let topLevel = try scanTopLevelBoxes(in: remuxedFile, fileSize: remuxedSize)
        guard let moovIndex = topLevel.firstIndex(where: { $0.kind == "moov" }) else {
            throw EngineError.encodeFailed("remuxed file has no moov box")
        }
        let trailingBoxes = topLevel[(moovIndex + 1)...]
        // Trailing moov keeps chunk offsets unchanged.
        guard trailingBoxes.allSatisfy({ $0.kind == "free" || $0.kind == "skip" }) else {
            throw EngineError.encodeFailed("remuxed moov precedes media data")
        }
        let moovHeader = topLevel[moovIndex]
        guard moovHeader.size <= maximumMoovBytes else {
            throw EngineError.encodeFailed("remuxed moov exceeds limit")
        }
        try remuxedFile.seek(toOffset: moovHeader.offset + UInt64(moovHeader.headerBytes))
        let moovBytes = try remuxedFile.read(upToCount: Int(moovHeader.size) - moovHeader.headerBytes) ?? Data()
        let remuxedChildren = try parseBoxes(moovBytes)

        let preservedChpl = try extractChplBoxes(from: remuxedChildren)
        var patchedChildren: [Data] = []
        var patchedHandlers: Set<String> = []
        for child in remuxedChildren {
            switch child.kind {
            case "meta", "udta":
                continue
            case "trak":
                if let handler = try trackHandler(of: child.payload),
                    !patchedHandlers.contains(handler),
                    let sourceTrack = stagedTracks[handler]
                {
                    patchedHandlers.insert(handler)
                    patchedChildren.append(try patchTrack(child.payload, with: sourceTrack))
                } else {
                    patchedChildren.append(child.raw)
                }
            default:
                patchedChildren.append(child.raw)
            }
        }
        patchedChildren.append(contentsOf: stagedMeta)
        if let mergedUdta = try mergeUdta(stagedUdta, preserving: preservedChpl) {
            patchedChildren.append(mergedUdta)
        }
        let rebuiltMoov = makeBox(kind: "moov", children: patchedChildren)
        try remuxedFile.seek(toOffset: moovHeader.offset)
        try remuxedFile.write(contentsOf: rebuiltMoov)
        try remuxedFile.truncate(atOffset: moovHeader.offset + UInt64(rebuiltMoov.count))
    }

    private static func readMoovPayload(at url: URL) throws -> Data {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let fileSize = try reader.seekToEnd()
        let boxes = try scanTopLevelBoxes(in: reader, fileSize: fileSize)
        guard let moov = boxes.first(where: { $0.kind == "moov" }), moov.size <= maximumMoovBytes else {
            throw EngineError.encodeFailed("staged file has no readable moov box")
        }
        try reader.seek(toOffset: moov.offset + UInt64(moov.headerBytes))
        return try reader.read(upToCount: Int(moov.size) - moov.headerBytes) ?? Data()
    }

    private static func scanTopLevelBoxes(in reader: FileHandle, fileSize: UInt64) throws -> [BoxHeader] {
        var offset: UInt64 = 0
        var boxes: [BoxHeader] = []
        while offset + UInt64(minimumBoxHeaderBytes) <= fileSize {
            try reader.seek(toOffset: offset)
            let header = try reader.read(upToCount: minimumBoxHeaderBytes) ?? Data()
            guard header.count == minimumBoxHeaderBytes else { break }
            let rawSize = UInt64(readUInt32(header, at: 0))
            let kind = String(decoding: header[4..<8], as: UTF8.self)
            let size: UInt64
            let headerBytes: Int
            if rawSize == 1 {
                let extended = try reader.read(upToCount: minimumBoxHeaderBytes) ?? Data()
                guard extended.count == minimumBoxHeaderBytes else {
                    throw EngineError.encodeFailed("truncated extended ISO box")
                }
                size = readUInt64(extended, at: 0)
                headerBytes = extendedBoxHeaderBytes
            } else if rawSize == 0 {
                size = fileSize - offset
                headerBytes = minimumBoxHeaderBytes
            } else {
                size = rawSize
                headerBytes = minimumBoxHeaderBytes
            }
            guard size >= UInt64(headerBytes), size <= fileSize - offset else {
                throw EngineError.encodeFailed("invalid ISO box size")
            }
            boxes.append(BoxHeader(kind: kind, offset: offset, size: size, headerBytes: headerBytes))
            offset += size
        }
        return boxes
    }

    private static func parseBoxes(_ container: Data) throws -> [MemoryBox] {
        var offset = 0
        var boxes: [MemoryBox] = []
        while offset + minimumBoxHeaderBytes <= container.count {
            let rawSize = UInt64(readUInt32(container, at: offset))
            let kind = String(decoding: container[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let size: UInt64
            let headerBytes: Int
            if rawSize == 1 {
                guard offset + extendedBoxHeaderBytes <= container.count else {
                    throw EngineError.encodeFailed("truncated extended nested ISO box")
                }
                size = readUInt64(container, at: offset + 8)
                headerBytes = extendedBoxHeaderBytes
            } else if rawSize == 0 {
                size = UInt64(container.count - offset)
                headerBytes = minimumBoxHeaderBytes
            } else {
                size = rawSize
                headerBytes = minimumBoxHeaderBytes
            }
            guard size >= UInt64(headerBytes), size <= UInt64(container.count - offset) else {
                throw EngineError.encodeFailed("invalid nested ISO box size")
            }
            let end = offset + Int(size)
            boxes.append(MemoryBox(kind: kind, raw: Data(container[offset..<end]), headerBytes: headerBytes))
            offset = end
        }
        return boxes
    }

    private static func extractTrackMetadata(from moovChildren: [MemoryBox]) throws -> [String: TrackMetadata] {
        var result: [String: TrackMetadata] = [:]
        for child in moovChildren where child.kind == "trak" {
            let trackBoxes = try parseBoxes(child.payload)
            guard let handler = try trackHandler(of: child.payload),
                handler == "vide" || handler == "soun",
                result[handler] == nil,
                let tkhd = trackBoxes.first(where: { $0.kind == "tkhd" })
            else { continue }
            let fields = try readTkhdFields(tkhd.raw)
            let elng = try trackBoxes.first(where: { $0.kind == "mdia" }).flatMap { mdia in
                try parseBoxes(mdia.payload).first(where: { $0.kind == "elng" })?.raw
            }
            result[handler] = TrackMetadata(
                flags: fields.flags, alternateGroup: fields.alternateGroup, volume: fields.volume,
                metaBoxes: trackBoxes.filter { $0.kind == "meta" }.map(\.raw),
                udtaBoxes: trackBoxes.filter { $0.kind == "udta" }.map(\.raw),
                extendedLanguageBox: elng)
        }
        return result
    }

    private static func trackHandler(of trakPayload: Data) throws -> String? {
        let trackBoxes = try parseBoxes(trakPayload)
        guard let mdia = trackBoxes.first(where: { $0.kind == "mdia" }) else { return nil }
        let mediaBoxes = try parseBoxes(mdia.payload)
        guard let hdlr = mediaBoxes.first(where: { $0.kind == "hdlr" }),
            hdlr.raw.count >= hdlrMinimumBytes
        else { return nil }
        return String(decoding: hdlr.raw[hdlrTypeRange], as: UTF8.self)
    }

    private static func readTkhdFields(_ tkhd: Data) throws -> (flags: Data, alternateGroup: Data, volume: Data) {
        guard tkhd.count > tkhdVersionOffset else { throw EngineError.encodeFailed("truncated tkhd box") }
        let version = tkhd[tkhdVersionOffset]
        if version == 0 {
            guard tkhd.count >= tkhdMinimumV0Bytes else { throw EngineError.encodeFailed("truncated v0 tkhd box") }
            return (
                Data(tkhd[tkhdFlagsRange]),
                Data(tkhd[tkhdAlternateGroupV0Offset..<(tkhdAlternateGroupV0Offset + 2)]),
                Data(tkhd[tkhdVolumeV0Offset..<(tkhdVolumeV0Offset + 2)])
            )
        }
        guard version == 1, tkhd.count >= tkhdMinimumV1Bytes else {
            throw EngineError.encodeFailed("unsupported tkhd version")
        }
        return (
            Data(tkhd[tkhdFlagsRange]),
            Data(tkhd[tkhdAlternateGroupV1Offset..<(tkhdAlternateGroupV1Offset + 2)]),
            Data(tkhd[tkhdVolumeV1Offset..<(tkhdVolumeV1Offset + 2)])
        )
    }

    private static func patchTkhd(_ tkhd: Data, with source: TrackMetadata) throws -> Data {
        var patched = tkhd
        guard patched.count > tkhdVersionOffset else { throw EngineError.encodeFailed("truncated remuxed tkhd") }
        let version = patched[tkhdVersionOffset]
        if version == 0 {
            guard patched.count >= tkhdMinimumV0Bytes else {
                throw EngineError.encodeFailed("truncated remuxed v0 tkhd")
            }
            patched.replaceSubrange(tkhdFlagsRange, with: source.flags)
            patched.replaceSubrange(
                tkhdAlternateGroupV0Offset..<(tkhdAlternateGroupV0Offset + 2), with: source.alternateGroup)
            patched.replaceSubrange(tkhdVolumeV0Offset..<(tkhdVolumeV0Offset + 2), with: source.volume)
        } else if version == 1 {
            guard patched.count >= tkhdMinimumV1Bytes else {
                throw EngineError.encodeFailed("truncated remuxed v1 tkhd")
            }
            patched.replaceSubrange(tkhdFlagsRange, with: source.flags)
            patched.replaceSubrange(
                tkhdAlternateGroupV1Offset..<(tkhdAlternateGroupV1Offset + 2), with: source.alternateGroup)
            patched.replaceSubrange(tkhdVolumeV1Offset..<(tkhdVolumeV1Offset + 2), with: source.volume)
        }
        return patched
    }

    private static func patchTrack(_ trakPayload: Data, with source: TrackMetadata) throws -> Data {
        let trackBoxes = try parseBoxes(trakPayload)
        var rebuilt: [Data] = []
        for box in trackBoxes {
            switch box.kind {
            case "meta", "udta":
                continue
            case "tkhd":
                rebuilt.append(try patchTkhd(box.raw, with: source))
            case "mdia":
                if let elng = source.extendedLanguageBox {
                    let mediaChildren = try parseBoxes(box.payload).filter { $0.kind != "elng" }.map(\.raw) + [elng]
                    rebuilt.append(makeBox(kind: "mdia", children: mediaChildren))
                } else {
                    rebuilt.append(box.raw)
                }
            default:
                rebuilt.append(box.raw)
            }
        }
        rebuilt.append(contentsOf: source.metaBoxes)
        rebuilt.append(contentsOf: source.udtaBoxes)
        return makeBox(kind: "trak", children: rebuilt)
    }

    private static func extractChplBoxes(from moovChildren: [MemoryBox]) throws -> [Data] {
        var chplBoxes: [Data] = []
        for udta in moovChildren where udta.kind == "udta" {
            for child in try parseBoxes(udta.payload) where child.kind == "chpl" {
                chplBoxes.append(child.raw)
            }
        }
        return chplBoxes
    }

    private static func mergeUdta(_ stagedUdta: [Data], preserving chplBoxes: [Data]) throws -> Data? {
        if stagedUdta.isEmpty {
            return chplBoxes.isEmpty ? nil : makeBox(kind: "udta", children: chplBoxes)
        }
        guard !chplBoxes.isEmpty else {
            return stagedUdta.reduce(into: Data()) { $0.append($1) }
        }
        var children: [Data] = []
        for udtaRaw in stagedUdta {
            let parsed = try parseBoxes(udtaRaw)
            if let first = parsed.first {
                children.append(contentsOf: try parseBoxes(first.payload).filter { $0.kind != "chpl" }.map(\.raw))
            }
        }
        children.append(contentsOf: chplBoxes)
        return makeBox(kind: "udta", children: children)
    }

    private static func makeBox(kind: String, children: [Data]) -> Data {
        let payloadLength = children.reduce(0) { $0 + $1.count }
        let total32 = UInt64(minimumBoxHeaderBytes) + UInt64(payloadLength)
        var output = Data()
        if total32 <= UInt64(UInt32.max) {
            output.reserveCapacity(Int(total32))
            appendBigEndian(UInt32(total32), to: &output)
            output.append(contentsOf: kind.utf8)
        } else {
            let total64 = UInt64(extendedBoxHeaderBytes) + UInt64(payloadLength)
            output.reserveCapacity(Int(total64))
            appendBigEndian(UInt32(1), to: &output)
            output.append(contentsOf: kind.utf8)
            appendBigEndian(total64, to: &output)
        }
        for child in children { output.append(child) }
        return output
    }

    private static func readUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(bytes[offset + $1]) }
    }

    private static func readUInt64(_ bytes: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to buffer: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { buffer.append(contentsOf: $0) }
    }
}
