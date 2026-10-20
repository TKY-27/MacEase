import COgg
import Foundation

/// Ogg paging through libogg.
struct OggPacket {
    var data: Data
    /// -1 unless the packet ends a page.
    var granule: Int64
    var endsStream: Bool
}

final class OggPacketWriter {
    private let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
    private let file: PatchableFile
    private var packetNumber: Int64 = 0

    init(url: URL) throws {
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
    func writeHeader(_ packet: Data) throws {
        try submit(packet, granule: 0, last: false)
        try drain(flush: true)
    }

    func write(_ packet: Data, granule: Int64, last: Bool) throws {
        try submit(packet, granule: granule, last: last)
        try drain(flush: last)
    }

    func close() throws {
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

/// First logical stream only; chains end it.
final class OggPacketReader {
    private static let readSize = 1 << 16
    private static let capturePattern = Array("OggS".utf8)
    private static let granuleOffset = 6
    private static let serialOffset = 14
    private static let pageHeaderLength = 27

    private let handle: FileHandle
    private let sync = UnsafeMutablePointer<ogg_sync_state>.allocate(capacity: 1)
    private let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
    private(set) var serial: Int32?
    private var ended = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        ogg_sync_init(sync)
    }

    deinit {
        if serial != nil { ogg_stream_clear(stream) }
        ogg_sync_clear(sync)
        sync.deallocate()
        stream.deallocate()
        try? handle.close()
    }

    /// Last page's granule, from the tail.
    func lastGranule() throws -> Int64? {
        guard let serial else { return nil }
        let resume = try handle.offset()
        defer { try? handle.seek(toOffset: resume) }
        let size = try handle.seekToEnd()
        let start = size - min(size, UInt64(Self.readSize))
        try handle.seek(toOffset: start)
        let tail = [UInt8](try handle.read(upToCount: Self.readSize) ?? Data())
        var index = tail.count - Self.pageHeaderLength
        while index >= 0 {
            if tail[index..<(index + Self.capturePattern.count)].elementsEqual(Self.capturePattern),
                Int32(bitPattern: UInt32(littleEndian: tail, at: index + Self.serialOffset)) == serial
            {
                let low = UInt64(UInt32(littleEndian: tail, at: index + Self.granuleOffset))
                let high = UInt64(UInt32(littleEndian: tail, at: index + Self.granuleOffset + 4))
                let granule = Int64(bitPattern: high << 32 | low)
                if granule >= 0 { return granule }
            }
            index -= 1
        }
        return nil
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

    /// `false` at the end of the file.
    private func pageIn() throws -> Bool {
        var page = ogg_page()
        while ogg_sync_pageout(sync, &page) != 1 {
            let chunk = try handle.read(upToCount: Self.readSize) ?? Data()
            guard !chunk.isEmpty else { return false }
            guard let buffer = ogg_sync_buffer(sync, chunk.count) else { throw FormatError.io("ogg_sync_buffer") }
            chunk.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: chunk.count)
            ogg_sync_wrote(sync, chunk.count)
        }
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
}
