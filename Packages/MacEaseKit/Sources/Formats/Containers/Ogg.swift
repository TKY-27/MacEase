import COgg
import Foundation

/// Ogg paging through libogg.
struct OggPacket {
    var data: Data
    /// -1 unless the packet ends a page.
    var granule: Int64
    var endsStream: Bool
}

package final class OggPacketWriter {
    private let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
    private let file: PatchableFile
    private var packetNumber: Int64 = 0

    package init(url: URL) throws {
        file = try PatchableFile(url: url)
        // `deinit` still frees the stream on failure.
        guard ogg_stream_init(stream, Int32.random(in: 1...Int32.max)) == 0 else {
            throw FormatError.encoderFailure("ogg_stream_init")
        }
    }

    deinit {
        ogg_stream_clear(stream)
        stream.deallocate()
    }

    /// Audio must start on a fresh page.
    package func writeHeader(_ packet: Data) throws {
        try submit(packet, granule: 0, last: false)
        try drain(flush: true)
    }

    package func write(_ packet: Data, granule: Int64, last: Bool) throws {
        try submit(packet, granule: granule, last: last)
        try drain(flush: last)
    }

    package func close() throws {
        try file.close()
    }

    private func submit(_ packet: Data, granule: Int64, last: Bool) throws {
        var bytes = [UInt8](packet)
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            var oggPacket = ogg_packet(
                packet: buffer.baseAddress, bytes: buffer.count, b_o_s: packetNumber == 0 ? 1 : 0,
                e_o_s: last ? 1 : 0, granulepos: granule, packetno: packetNumber
            )
            return ogg_stream_packetin(stream, &oggPacket)
        }
        guard status == 0 else { throw FormatError.encoderFailure("ogg_stream_packetin") }
        packetNumber += 1
    }

    private func drain(flush: Bool) throws {
        var page = ogg_page()
        while (flush ? ogg_stream_flush(stream, &page) : ogg_stream_pageout(stream, &page)) != 0 {
            try file.append(UnsafeBufferPointer(start: page.header, count: page.header_len))
            try file.append(UnsafeBufferPointer(start: page.body, count: page.body_len))
        }
    }
}

package enum OggReadError: Error, Equatable, Sendable {
    case chainedStream
    case multiplexedStream
}

final class OggPacketReader {
    private static let readSize = 1 << 16

    private let fileReader: FileHandle
    private let sync = UnsafeMutablePointer<ogg_sync_state>.allocate(capacity: 1)
    private let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
    private(set) var serial: Int32?
    private(set) var lastGranule: Int64?
    private var ended = false

    init(url: URL) throws {
        fileReader = try FileHandle(forReadingFrom: url)
        ogg_sync_init(sync)
        try validateSingleStream()
        try fileReader.seek(toOffset: 0)
        ogg_sync_reset(sync)
    }

    deinit {
        if serial != nil { ogg_stream_clear(stream) }
        ogg_sync_clear(sync)
        sync.deallocate()
        stream.deallocate()
        try? fileReader.close()
    }

    private func validateSingleStream() throws {
        var firstSerial: Int32?
        var reachedEOS = false
        while var page = try nextPage() {
            if reachedEOS, ogg_page_bos(&page) != 0 { throw OggReadError.chainedStream }
            let pageSerial = ogg_page_serialno(&page)
            if firstSerial == nil { firstSerial = pageSerial }
            guard pageSerial == firstSerial else { throw OggReadError.multiplexedStream }
            let granule = ogg_page_granulepos(&page)
            if granule >= 0 { lastGranule = granule }
            if ogg_page_eos(&page) != 0 { reachedEOS = true }
        }
    }

    func next() throws -> OggPacket? {
        while !ended {
            if serial != nil, let packet = try packetFromStream() { return packet }
            guard try pageIn() else { return nil }
        }
        return nil
    }

    private func packetFromStream() throws -> OggPacket? {
        var packet = ogg_packet()
        switch ogg_stream_packetout(stream, &packet) {
        case 1:
            if packet.e_o_s != 0 { ended = true }
            return OggPacket(
                data: Data(bytes: packet.packet, count: packet.bytes), granule: packet.granulepos,
                endsStream: packet.e_o_s != 0
            )
        case 0: return nil
        default: throw FormatError.corrupt("Ogg packets are missing")
        }
    }

    private func pageIn() throws -> Bool {
        guard var page = try nextPage() else { return false }
        let pageSerial = ogg_page_serialno(&page)
        if serial == nil {
            guard ogg_page_bos(&page) != 0 else { throw FormatError.corrupt("Ogg stream has no first page") }
            guard ogg_stream_init(stream, pageSerial) == 0 else { throw FormatError.corrupt("ogg_stream_init") }
            serial = pageSerial
        }
        if pageSerial == serial, ogg_stream_pagein(stream, &page) != 0 {
            throw FormatError.corrupt("Ogg page rejected")
        }
        return true
    }

    private func nextPage() throws -> ogg_page? {
        var page = ogg_page()
        while ogg_sync_pageout(sync, &page) != 1 {
            try Task.checkCancellation()
            let chunk = try fileReader.read(upToCount: Self.readSize) ?? Data()
            guard !chunk.isEmpty else { return nil }
            guard let buffer = ogg_sync_buffer(sync, chunk.count) else { throw FormatError.io("ogg_sync_buffer") }
            chunk.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: chunk.count)
            ogg_sync_wrote(sync, chunk.count)
        }
        return page
    }
}
