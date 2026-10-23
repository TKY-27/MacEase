import Darwin
import Foundation

final class JSONFile {
    static let chunkBytes = 64 * 1024
    private static let caseFoldLocale = Locale(identifier: "en_US_POSIX")
    let file: FileHandle
    private var pending = Data()
    private var flushed: UInt64 = 0
    private var cached = Data()
    private var cachedOffset: UInt64 = 0
    private var previous = Data()
    private var previousOffset: UInt64 = 0
    var count: UInt64 { flushed + UInt64(pending.count) }

    init(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        pending.reserveCapacity(Self.chunkBytes)
    }

    init(reading url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        flushed = try file.seekToEnd()
    }

    func append(_ bytes: Data) throws {
        guard UInt64(bytes.count) <= UInt64(Int64.max) - count else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
        }
        var offset = 0
        while offset < bytes.count {
            let length = min(Self.chunkBytes - pending.count, bytes.count - offset)
            pending.append(bytes[offset..<(offset + length)])
            offset += length
            if pending.count == Self.chunkBytes { try flush() }
        }
    }

    func append(_ text: String) throws { try append(Data(text.utf8)) }

    func flush() throws {
        try Task.checkCancellation()
        guard !pending.isEmpty else { return }
        try file.seek(toOffset: flushed)
        try file.write(contentsOf: pending)
        flushed += UInt64(pending.count)
        pending.removeAll(keepingCapacity: true)
        cached.removeAll(keepingCapacity: true)
        previous.removeAll(keepingCapacity: true)
    }

    func replace<T>(_ value: T, at offset: UInt64) throws {
        let bytes = withUnsafeBytes(of: value) { Data($0) }
        if offset >= flushed {
            let start = Int(offset - flushed)
            pending.replaceSubrange(start..<(start + bytes.count), with: bytes)
        } else {
            try file.seek(toOffset: offset)
            let written = Int(min(UInt64(bytes.count), flushed - offset))
            try file.write(contentsOf: bytes.prefix(written))
            if written < bytes.count {
                pending.replaceSubrange(0..<(bytes.count - written), with: bytes.suffix(from: written))
            }
            cached.removeAll(keepingCapacity: true)
            previous.removeAll(keepingCapacity: true)
        }
    }

    func read(at offset: UInt64, count length: Int) throws -> Data {
        guard offset <= count, UInt64(length) <= count - offset else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        if offset >= flushed {
            let start = Int(offset - flushed)
            return pending.subdata(in: start..<(start + length))
        }
        if offset < cachedOffset || offset + UInt64(length) > cachedOffset + UInt64(cached.count) {
            if offset >= previousOffset, offset + UInt64(length) <= previousOffset + UInt64(previous.count) {
                swap(&cached, &previous)
                swap(&cachedOffset, &previousOffset)
            }
        }
        if offset < cachedOffset || offset + UInt64(length) > cachedOffset + UInt64(cached.count) {
            try Task.checkCancellation()
            previous = cached
            previousOffset = cachedOffset
            cachedOffset = offset
            let available = min(UInt64(Self.chunkBytes), flushed - offset)
            cached = Data(count: Int(available))
            var received = 0
            while received < cached.count {
                let amount = cached.withUnsafeMutableBytes { bytes in
                    pread(
                        file.fileDescriptor, bytes.baseAddress?.advanced(by: received), bytes.count - received,
                        off_t(offset + UInt64(received)))
                }
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(amount == 0 ? EIO : errno))
                }
                received += amount
            }
        }
        let start = Int(offset - cachedOffset)
        if start + length <= cached.count { return cached.subdata(in: start..<(start + length)) }
        let first = cached.subdata(in: start..<cached.count)
        return first + (try read(at: offset + UInt64(first.count), count: length - first.count))
    }

    func copy(_ span: JSONSpan, to output: JSONFile) throws {
        var offset: UInt64 = 0
        while offset < span.length {
            let length = Int(min(UInt64(Self.chunkBytes), span.length - offset))
            try output.append(read(at: span.offset + offset, count: length))
            offset += UInt64(length)
        }
    }

    func string(_ span: JSONSpan) throws -> String {
        try String(unsafeUninitializedCapacity: Int(span.length)) { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let length = min(Self.chunkBytes, buffer.count - offset)
                let bytes = try read(at: span.offset + UInt64(offset), count: length)
                offset += bytes.copyBytes(
                    to: UnsafeMutableBufferPointer(rebasing: buffer[offset..<(offset + length)]))
            }
            return offset
        }
    }

    func appendCaseFolded(_ span: JSONSpan, from source: JSONFile) throws -> JSONSpan {
        let start = count
        let maximumIncompleteBytes = 3
        var offset: UInt64 = 0
        while offset < span.length {
            try Task.checkCancellation()
            let length = Int(min(UInt64(Self.chunkBytes), span.length - offset))
            let bytes = try source.read(at: span.offset + offset, count: length)
            let consumed = try autoreleasepool {
                for suffix in 0...min(maximumIncompleteBytes, bytes.count) {
                    let prefix = bytes.prefix(bytes.count - suffix)
                    if let text = String(validating: prefix, as: UTF8.self) {
                        try append(text.folding(options: .caseInsensitive, locale: Self.caseFoldLocale))
                        return prefix.count
                    }
                }
                throw EngineError.unexpected("Invalid UTF-8 in JSON key storage")
            }
            guard consumed > 0 else { throw EngineError.unexpected("Incomplete UTF-8 in JSON key storage") }
            offset += UInt64(consumed)
        }
        return JSONSpan(offset: start, length: count - start)
    }

    func compare(_ left: JSONSpan, _ right: JSONSpan) throws -> ComparisonResult {
        if left.offset == right.offset, left.length == right.length { return .orderedSame }
        var offset: UInt64 = 0
        while offset < min(left.length, right.length) {
            try Task.checkCancellation()
            let length = Int(min(UInt64(Self.chunkBytes), min(left.length, right.length) - offset))
            let leftBytes = try read(at: left.offset + offset, count: length)
            let rightBytes = try read(at: right.offset + offset, count: length)
            if leftBytes != rightBytes {
                return leftBytes.lexicographicallyPrecedes(rightBytes) ? .orderedAscending : .orderedDescending
            }
            offset += UInt64(length)
        }
        if left.length == right.length { return .orderedSame }
        return left.length < right.length ? .orderedAscending : .orderedDescending
    }
}

struct JSONSpan {
    var offset: UInt64 = 0
    var length: UInt64 = 0
}

struct JSONRecord {
    var kind: UInt64 = 0
    var payload = JSONSpan()
    var key = JSONSpan()
    var rawKey = JSONSpan()
    var end: UInt64 = 0
    var children: UInt64 = 0
    var primitiveChildren: UInt64 = 1
    var order: UInt64 = 0

    static var size: UInt64 { UInt64(MemoryLayout<Self>.size) }
}

final class JSONIndex {
    private struct Frame {
        var record: JSONRecord
        let index: UInt64
        var key = JSONSpan()
        var rawKey = JSONSpan()
    }

    let records: JSONFile
    let payload: JSONFile
    let keys: JSONFile
    private var frames: [Frame] = []
    private var scalar = JSONRecord()
    private var scalarKind = JSONToken.null
    private var keyStart: UInt64 = 0
    private var rawKeyStart: UInt64 = 0
    var count: UInt64 { records.count / JSONRecord.size }

    init(directory: URL) throws {
        records = try JSONFile(directory.appendingPathComponent("nodes"))
        payload = try JSONFile(directory.appendingPathComponent("values"))
        keys = try JSONFile(directory.appendingPathComponent("keys"))
    }

    func accept(_ event: JSONEvent) throws {
        switch event {
        case .begin(let kind):
            scalarKind = kind
            if kind == .key {
                keyStart = payload.count
                rawKeyStart = keys.count
                try payload.append("\"")
                return
            }
            var record = JSONRecord(kind: kind.rawValue)
            if !frames.isEmpty {
                let parent = frames.count - 1
                record.key = frames[parent].key
                record.rawKey = frames[parent].rawKey
                frames[parent].record.children += 1
                if !kind.primitive { frames[parent].record.primitiveChildren = 0 }
            }
            if kind.primitive {
                record.payload.offset = payload.count
                scalar = record
                if kind == .string { try payload.append("\"") }
            } else {
                let index = count
                try append(record)
                frames.append(Frame(record: record, index: index))
            }
        case .bytes(let bytes):
            if scalarKind == .key {
                try keys.append(Data(bytes))
                try JSONOutput.escaped(bytes, to: payload)
            } else if scalarKind == .string {
                try JSONOutput.escaped(bytes, to: payload)
            } else {
                try payload.append(Data(bytes))
            }
        case .end(let kind):
            if kind == .key {
                try payload.append("\"")
                frames[frames.count - 1].key = JSONSpan(offset: keyStart, length: payload.count - keyStart)
                frames[frames.count - 1].rawKey = JSONSpan(offset: rawKeyStart, length: keys.count - rawKeyStart)
            } else if kind.primitive {
                if kind == .string { try payload.append("\"") }
                scalar.payload.length = payload.count - scalar.payload.offset
                scalar.end = count + 1
                try append(scalar)
            } else {
                var frame = frames.removeLast()
                frame.record.end = count
                try records.replace(frame.record, at: frame.index * JSONRecord.size)
            }
        }
    }

    private func append(_ record: JSONRecord) throws {
        try records.append(withUnsafeBytes(of: record) { Data($0) })
    }

    func record(_ index: UInt64) throws -> JSONRecord {
        let bytes = try records.read(at: index * JSONRecord.size, count: Int(JSONRecord.size))
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: JSONRecord.self) }
    }

    func flush() throws {
        try records.flush()
        try payload.flush()
        try keys.flush()
    }
}
