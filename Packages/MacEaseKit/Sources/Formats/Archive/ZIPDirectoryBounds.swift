import Darwin
import Foundation

enum ZIPDirectoryBounds {
    static let maximumEntries = 100_000
    static let maximumMetadataBytes = 32 * 1024 * 1024
    private static let maximumEOCDSearch = 16 * 1024
    private static let centralHeaderBytes = 46
    private static let maximumSignatureBytes = 6 + 65_535

    private struct Directory {
        let offset: Int64
        let size: Int64
        let entries: Int
    }

    static func validate(descriptor: Int32, size: Int64, check: () throws -> Void) throws -> Int {
        guard size >= 22 else { throw ZIPBrowserError.invalidZIP }
        let tailSize = min(Int(size), maximumEOCDSearch)
        let tail = try read(descriptor, at: size - Int64(tailSize), count: tailSize, fileSize: size, check: check)
        guard
            let index = stride(from: tail.count - 22, through: 0, by: -1).first(where: { candidate in
                UInt32(littleEndian: tail, at: candidate) == 0x06054b50
            })
        else { throw ZIPBrowserError.invalidZIP }
        guard index + 22 + Int(UInt16(littleEndian: tail, at: index + 20)) == tail.count else {
            throw ZIPBrowserError.invalidZIP
        }
        try check()
        let endOffset = size - Int64(tailSize) + Int64(index)
        guard UInt16(littleEndian: tail, at: index + 4) == 0,
            UInt16(littleEndian: tail, at: index + 6) == 0,
            UInt16(littleEndian: tail, at: index + 8) == UInt16(littleEndian: tail, at: index + 10)
        else { throw ZIPBrowserError.invalidZIP }
        let classicCount = UInt16(littleEndian: tail, at: index + 10)
        let classicSize = UInt32(littleEndian: tail, at: index + 12)
        let classicOffset = UInt32(littleEndian: tail, at: index + 16)
        let directory: Directory
        if index >= 20 {
            let locator = try read(descriptor, at: endOffset - 20, count: 20, fileSize: size, check: check)
            if UInt32(littleEndian: locator, at: 0) == 0x07064b50 {
                directory = try zip64(
                    locator, descriptor: descriptor, fileSize: size, locatorOffset: endOffset - 20,
                    classicCount: classicCount, classicSize: classicSize, classicOffset: classicOffset,
                    check: check)
            } else {
                directory = try classic(
                    count: classicCount, size: classicSize, offset: classicOffset, endOffset: endOffset)
            }
        } else {
            directory = try classic(
                count: classicCount, size: classicSize, offset: classicOffset, endOffset: endOffset)
        }
        try scan(directory, descriptor: descriptor, fileSize: size, check: check)
        return directory.entries
    }

    private static func classic(count: UInt16, size: UInt32, offset: UInt32, endOffset: Int64) throws -> Directory {
        guard size != .max, offset != .max,
            Int64(offset) <= endOffset, Int64(size) <= endOffset - Int64(offset)
        else { throw ZIPBrowserError.invalidZIP }
        return Directory(offset: endOffset - Int64(size), size: Int64(size), entries: Int(count))
    }

    private static func zip64(
        _ locator: [UInt8], descriptor: Int32, fileSize: Int64, locatorOffset: Int64,
        classicCount: UInt16, classicSize: UInt32, classicOffset: UInt32,
        check: () throws -> Void
    ) throws -> Directory {
        guard UInt32(littleEndian: locator, at: 4) == 0,
            UInt32(littleEndian: locator, at: 16) == 1
        else { throw ZIPBrowserError.invalidZIP }
        let recordOffset = little64(locator, at: 8)
        guard recordOffset <= UInt64(locatorOffset), recordOffset <= UInt64(Int64.max) else {
            throw ZIPBrowserError.invalidZIP
        }
        let record = try read(descriptor, at: Int64(recordOffset), count: 56, fileSize: fileSize, check: check)
        let recordSize = little64(record, at: 4)
        guard UInt32(littleEndian: record, at: 0) == 0x06064b50,
            recordSize >= 44, recordSize <= 16_372,
            recordSize + 12 <= UInt64(locatorOffset) - recordOffset,
            UInt32(littleEndian: record, at: 16) == 0,
            UInt32(littleEndian: record, at: 20) == 0,
            little64(record, at: 24) == little64(record, at: 32)
        else { throw ZIPBrowserError.invalidZIP }
        let count = little64(record, at: 32)
        let size = little64(record, at: 40)
        let offset = little64(record, at: 48)
        guard count <= UInt64(maximumEntries) else { throw ZIPBrowserError.tooManyEntries }
        guard classicCount == .max || UInt64(classicCount) == count,
            classicSize == .max || UInt64(classicSize) == size,
            classicOffset == .max || UInt64(classicOffset) == offset,
            offset <= recordOffset, size == recordOffset - offset,
            offset <= UInt64(Int64.max), size <= UInt64(Int64.max)
        else { throw ZIPBrowserError.invalidZIP }
        return Directory(offset: Int64(offset), size: Int64(size), entries: Int(count))
    }

    private static func scan(
        _ directory: Directory, descriptor: Int32, fileSize: Int64, check: () throws -> Void
    ) throws {
        guard directory.entries <= maximumEntries else { throw ZIPBrowserError.tooManyEntries }
        let maximumSize = Int64(maximumMetadataBytes + maximumEntries * centralHeaderBytes + maximumSignatureBytes)
        guard directory.size <= maximumSize else { throw ZIPBrowserError.namesTooLarge }
        guard directory.offset >= 0, directory.offset <= fileSize,
            directory.size <= fileSize - directory.offset
        else { throw ZIPBrowserError.invalidZIP }
        let end = directory.offset + directory.size
        var position = directory.offset
        var count = 0
        var metadataBytes = 0
        while position < end {
            try check()
            guard end - position >= 4 else { throw ZIPBrowserError.invalidZIP }
            let signature = try read(descriptor, at: position, count: 4, fileSize: fileSize, check: check)
            if UInt32(littleEndian: signature, at: 0) == 0x05054b50 {
                guard end - position >= 6 else { throw ZIPBrowserError.invalidZIP }
                let header = try read(descriptor, at: position, count: 6, fileSize: fileSize, check: check)
                guard Int64(UInt16(littleEndian: header, at: 4)) == end - position - 6 else {
                    throw ZIPBrowserError.invalidZIP
                }
                position = end
                break
            }
            guard UInt32(littleEndian: signature, at: 0) == 0x02014b50,
                end - position >= centralHeaderBytes
            else { throw ZIPBrowserError.invalidZIP }
            guard count < maximumEntries else { throw ZIPBrowserError.tooManyEntries }
            let header = try read(
                descriptor, at: position, count: centralHeaderBytes, fileSize: fileSize, check: check)
            guard UInt16(littleEndian: header, at: 34) == 0 else { throw ZIPBrowserError.invalidZIP }
            let variableBytes =
                Int(UInt16(littleEndian: header, at: 28))
                + Int(UInt16(littleEndian: header, at: 30))
                + Int(UInt16(littleEndian: header, at: 32))
            guard variableBytes <= maximumMetadataBytes - metadataBytes else {
                throw ZIPBrowserError.namesTooLarge
            }
            guard Int64(variableBytes) <= end - position - Int64(centralHeaderBytes) else {
                throw ZIPBrowserError.invalidZIP
            }
            metadataBytes += variableBytes
            count += 1
            position += Int64(centralHeaderBytes + variableBytes)
        }
        guard position == end, count == directory.entries else { throw ZIPBrowserError.invalidZIP }
    }

    private static func read(
        _ descriptor: Int32, at offset: Int64, count: Int, fileSize: Int64,
        check: () throws -> Void
    ) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset <= fileSize, Int64(count) <= fileSize - offset else {
            throw ZIPBrowserError.invalidZIP
        }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var position = 0
            while position < count {
                try check()
                let amount = pread(descriptor, base.advanced(by: position), count - position, offset + Int64(position))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw ZIPBrowserError.invalidZIP }
                position += amount
            }
        }
        return bytes
    }

    private static func little64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(UInt32(littleEndian: bytes, at: offset))
            | UInt64(UInt32(littleEndian: bytes, at: offset + 4)) << 32
    }
}
