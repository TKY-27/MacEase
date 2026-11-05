import Foundation

enum DownloadedMediaRepair {
    private static let emptyNAL = Data([0, 0, 0, 4, 0, 0, 0, 0])

    private struct Packet: Decodable {
        let streamIndex: Int
        let presentation: String?
        let decode: String?
        let duration: String?
        let size: String
        let position: String?
        let hash: String?
        let sideData: [SideData]?

        enum CodingKeys: String, CodingKey {
            case streamIndex = "stream_index", presentation = "pts_time", decode = "dts_time"
            case duration = "duration_time", size, position = "pos", hash = "data_hash"
            case sideData = "side_data_list"
        }

        var signature: Signature? {
            guard let presentation, let decode, let duration, let hash, hash.hasPrefix("SHA256:"),
                (sideData ?? []).allSatisfy({ $0.type == "Skip Samples" })
            else { return nil }
            return Signature(
                stream: streamIndex, presentation: presentation, decode: decode, duration: duration, size: size,
                hash: hash, sideData: sideData ?? [])
        }
    }

    private struct SideData: Decodable, Equatable {
        let type: String
        let skipSamples: Int?
        let discardPadding: Int?
        let skipReason: Int?
        let discardReason: Int?

        enum CodingKeys: String, CodingKey {
            case type = "side_data_type", skipSamples = "skip_samples", discardPadding = "discard_padding"
            case skipReason = "skip_reason", discardReason = "discard_reason"
        }
    }

    private struct Signature: Equatable {
        let stream: Int
        let presentation: String
        let decode: String
        let duration: String
        let size: String
        let hash: String
        let sideData: [SideData]
    }

    static func removeEmptyH264Tail(
        _ output: URL, videoIndex: Int, tools: MediaDownloadTools, verify: (URL) async throws -> Void
    ) async throws -> Bool {
        guard output.pathExtension.lowercased() == "mp4" else { return false }
        let original = try await packets(in: output, tools: tools)
        let reader = try FileHandle(forReadingFrom: output)
        let length = try reader.seekToEnd()
        var valid: [Packet] = []
        var foundTail = false
        do {
            for packet in original {
                try Task.checkCancellation()
                if packet.streamIndex == videoIndex {
                    if packet.size == String(emptyNAL.count), let position = packet.position.flatMap(UInt64.init),
                        position <= length, UInt64(emptyNAL.count) <= length - position
                    {
                        try reader.seek(toOffset: position)
                        if try reader.read(upToCount: emptyNAL.count) == emptyNAL {
                            foundTail = true
                            continue
                        }
                    }
                    if foundTail { try reader.close(); return false }
                }
                valid.append(packet)
            }
            try reader.close()
        } catch {
            try reader.close()
            throw error
        }
        guard foundTail, valid.contains(where: { $0.streamIndex == videoIndex }) else { return false }
        let repaired = output.deletingLastPathComponent().appending(path: "repaired-\(UUID().uuidString).mp4")
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-n", "-i", output.path, "-map", "0", "-map_metadata", "0", "-map_chapters",
                "0",
                "-c", "copy", "-bsf:v:0", "filter_units=remove_types=0", repaired.path,
            ], directory: output.deletingLastPathComponent(), tools: tools, captureOutput: false)
        let replacement = try await packets(in: repaired, tools: tools)
        guard valid.allSatisfy({ $0.signature != nil }), replacement.allSatisfy({ $0.signature != nil }),
            Dictionary(grouping: valid, by: \.streamIndex).mapValues({ $0.compactMap(\.signature) })
                == Dictionary(grouping: replacement, by: \.streamIndex).mapValues({ $0.compactMap(\.signature) })
        else { throw EngineError.decodeFailed("Media repair changed valid packets or presentation timing") }
        try await verify(repaired)
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(output, withItemAt: repaired)
        return true
    }

    private static func packets(in output: URL, tools: MediaDownloadTools) async throws -> [Packet] {
        struct PacketListing: Decodable { let packets: [Packet] }
        let result = try await MediaToolProcess().run(
            executable: tools.ffprobe,
            arguments: [
                "-v", "error", "-show_packets", "-show_data_hash", "sha256", "-show_entries",
                "packet=stream_index,pts_time,dts_time,duration_time,size,pos,data_hash", "-of", "json", output.path,
            ], directory: output.deletingLastPathComponent(), tools: tools)
        return try JSONDecoder().decode(PacketListing.self, from: result.stdout).packets
    }
}
