import CDeflate
import Darwin
import Foundation

public struct PNGChunk: Equatable, Sendable {
    public var type: String
    public var payload: Data

    public init(type: String, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

enum PNGColorType: UInt8 {
    case gray = 0
    case rgb = 2
    case palette = 3
    case grayAlpha = 4
    case rgba = 6

    var channels: Int {
        switch self {
        case .gray, .palette: 1
        case .grayAlpha: 2
        case .rgb: 3
        case .rgba: 4
        }
    }
}

struct PNGRaster {
    var width: Int
    var height: Int
    var colorType: PNGColorType
    var bitDepth: Int
    /// Packed rows without filter bytes.
    var samples: any ContiguousBytes & Sendable
    var palette: [PaletteColor] = []
    var omitsOpaqueAlpha: Bool

    init<Samples: ContiguousBytes & Collection & Sendable>(
        width: Int, height: Int, colorType: PNGColorType, bitDepth: Int, samples: Samples,
        palette: [PaletteColor] = [], omitsOpaqueAlpha: Bool = false
    ) where Samples.Element == UInt8 {
        self.width = width
        self.height = height
        self.colorType = colorType
        self.bitDepth = bitDepth
        self.samples = samples
        self.palette = palette
        self.omitsOpaqueAlpha = omitsOpaqueAlpha
    }

    var sampleCount: Int { samples.withUnsafeBytes { $0.count } }
    var rowBytes: Int { (width * colorType.channels * bitDepth + 7) / 8 }
    var sourceRowBytes: Int { omitsOpaqueAlpha ? width * 4 : rowBytes }
    var bytesPerPixel: Int { max(1, colorType.channels * bitDepth / 8) }
}

enum PNGFilterStrategy: CaseIterable {
    case none
    case adaptive
    case paeth
}

public enum PNGOutputError: Error, Equatable {
    case sizeLimitExceeded
}

public enum PNGFile {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let maximumLevel: Int32 = 12
    static let trialLevel: Int32 = 6

    struct Prepared: Sendable {
        var filtered: Data
        var chunks: [PNGChunk]
    }

    /// Color-type independent, so copied verbatim.
    static let portableAncillaryTypes: Set<String> = [
        "iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI", "pHYs", "eXIf", "iTXt", "tEXt", "zTXt", "tIME",
    ]

    public static func fixedBytes(in encoded: Data) throws -> Int {
        try chunks(in: encoded).reduce(encoded.count) { total, chunk in
            chunk.type == "IDAT" ? total - chunk.payload.count : total
        }
    }

    static func chunks(in file: Data) throws -> [PNGChunk] {
        let chunkOverhead = 12
        let lengthWidth = 4
        let payloadOffset = 8
        guard file.starts(with: signature) else { throw FormatError.corrupt("not a PNG") }
        var chunks: [PNGChunk] = []
        var offset = file.startIndex + signature.count
        while file.endIndex - offset >= chunkOverhead {
            let length = file[offset..<(offset + lengthWidth)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= file.endIndex - offset - chunkOverhead else {
                throw FormatError.corrupt("truncated PNG chunk")
            }
            let type = String(decoding: file[(offset + lengthWidth)..<(offset + payloadOffset)], as: UTF8.self)
            chunks.append(
                PNGChunk(type: type, payload: file[(offset + payloadOffset)..<(offset + payloadOffset + length)]))
            offset += chunkOverhead + length
            if type == "IEND" { return chunks }
        }
        throw FormatError.corrupt("PNG ends before IEND")
    }

    static func encode(
        _ raster: PNGRaster,
        transparency: [UInt8]? = nil,
        ancillary: [PNGChunk] = [],
        strategy: PNGFilterStrategy,
        level: Int32,
        maximumCompressedBytes: Int64? = nil,
        cancelled: (() -> Bool)? = nil
    ) throws -> Data {
        let prepared = try prepare(
            raster, transparency: transparency, ancillary: ancillary, strategy: strategy, cancelled: cancelled)
        return try encode(prepared, level: level, maximumCompressedBytes: maximumCompressedBytes)
    }

    static func prepare(
        _ raster: PNGRaster, transparency: [UInt8]? = nil, ancillary: [PNGChunk] = [],
        strategy: PNGFilterStrategy, cancelled: (() -> Bool)? = nil
    ) throws -> Prepared {
        guard raster.width > 0, raster.height > 0,
            UInt32(exactly: raster.width) != nil, UInt32(exactly: raster.height) != nil,
            raster.bitDepth > 0, UInt8(exactly: raster.bitDepth) != nil,
            !raster.omitsOpaqueAlpha || raster.colorType == .rgb && raster.bitDepth == 8
        else {
            throw FormatError.corrupt(String(localized: "PNG raster out of range", comment: "Invalid image metadata"))
        }
        let (sampleBytes, overflow) = raster.sourceRowBytes.multipliedReportingOverflow(by: raster.height)
        guard !overflow, sampleBytes == raster.sampleCount, sampleBytes <= Int.max - raster.height else {
            throw FormatError.corrupt(String(localized: "PNG raster out of range", comment: "Invalid image metadata"))
        }
        var header = Data()
        header.appendBigEndian(UInt32(raster.width))
        header.appendBigEndian(UInt32(raster.height))
        header.append(contentsOf: [UInt8(raster.bitDepth), raster.colorType.rawValue, 0, 0, 0])
        var chunks = [PNGChunk(type: "IHDR", payload: header)] + ancillary
        if raster.colorType == .palette {
            chunks.append(
                PNGChunk(type: "PLTE", payload: Data(raster.palette.flatMap { [$0.red, $0.green, $0.blue] })))
        }
        if let transparency, !transparency.isEmpty {
            chunks.append(PNGChunk(type: "tRNS", payload: Data(transparency)))
        }
        return Prepared(filtered: try filtered(raster, strategy: strategy, cancelled: cancelled), chunks: chunks)
    }

    static func encode(
        _ prepared: Prepared, level: Int32, maximumCompressedBytes: Int64? = nil
    ) throws -> Data {
        var chunks = prepared.chunks
        chunks.append(
            PNGChunk(
                type: "IDAT",
                payload: try compress(
                    prepared.filtered, level: level, maximumBytes: maximumCompressedBytes)))
        chunks.append(PNGChunk(type: "IEND", payload: Data()))
        var count = signature.count
        for chunk in chunks {
            guard chunk.payload.count <= Int(UInt32.max), chunk.type.utf8.count == 4 else {
                throw FormatError.corrupt(
                    String(localized: "PNG chunk too large", comment: "Unrepresentable image chunk"))
            }
            let (next, overflow) = count.addingReportingOverflow(chunk.payload.count + 12)
            guard !overflow else { throw FormatError.encoderFailure("PNG output allocation") }
            count = next
        }
        var output = try mappedBytes(count: count)
        output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            UnsafeMutableRawBufferPointer(rebasing: destination[..<signature.count]).copyBytes(from: signature)
            var offset = signature.count
            for chunk in chunks {
                let end = offset + chunk.payload.count + 12
                write(chunk, to: UnsafeMutableRawBufferPointer(rebasing: destination[offset..<end]))
                offset = end
            }
        }
        return output
    }

    static func serialized(_ chunk: PNGChunk) -> Data {
        var output = Data(count: chunk.payload.count + chunk.type.utf8.count + 8)
        output.withUnsafeMutableBytes { write(chunk, to: $0) }
        return output
    }

    private static func write(_ chunk: PNGChunk, to output: UnsafeMutableRawBufferPointer) {
        withUnsafeBytes(of: UInt32(chunk.payload.count).bigEndian) {
            UnsafeMutableRawBufferPointer(rebasing: output[..<4]).copyBytes(from: $0)
        }
        let typeBytes = Array(chunk.type.utf8)
        let payloadOffset = 4 + typeBytes.count
        let checksumOffset = payloadOffset + chunk.payload.count
        UnsafeMutableRawBufferPointer(rebasing: output[4..<payloadOffset]).copyBytes(from: typeBytes)
        chunk.payload.withUnsafeBytes {
            UnsafeMutableRawBufferPointer(rebasing: output[payloadOffset..<checksumOffset]).copyBytes(from: $0)
        }
        let initial = typeBytes.withUnsafeBytes { libdeflate_crc32(0, $0.baseAddress, $0.count) }
        let crc = chunk.payload.withUnsafeBytes { libdeflate_crc32(initial, $0.baseAddress, $0.count) }
        withUnsafeBytes(of: crc.bigEndian) {
            UnsafeMutableRawBufferPointer(rebasing: output[checksumOffset...]).copyBytes(from: $0)
        }
    }

    static func compress(
        _ input: Data, level: Int32, maximumBytes: Int64? = nil
    ) throws -> Data {
        guard let compressor = libdeflate_alloc_compressor(level) else {
            throw FormatError.encoderFailure("libdeflate allocation")
        }
        defer { libdeflate_free_compressor(compressor) }
        let bound = libdeflate_zlib_compress_bound(compressor, input.count)
        guard bound <= Int(UInt32.max) else {
            throw FormatError.corrupt(String(localized: "PNG chunk too large", comment: "Unrepresentable image chunk"))
        }
        let capacity: Int
        if let maximumBytes {
            guard maximumBytes > 0, let limit = Int(exactly: maximumBytes) else {
                throw PNGOutputError.sizeLimitExceeded
            }
            capacity = min(bound, limit)
        } else {
            capacity = bound
        }
        var output = try mappedBytes(count: capacity)
        let written = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                libdeflate_zlib_compress(compressor, source.baseAddress, source.count, target.baseAddress, target.count)
            }
        }
        guard written > 0 else {
            if capacity < bound { throw PNGOutputError.sizeLimitExceeded }
            throw FormatError.encoderFailure("deflate output did not fit")
        }
        return output.prefix(written)
    }

    static func mappedBytes(count: Int) throws -> Data {
        guard let mapping = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
            mapping != MAP_FAILED
        else { throw FormatError.encoderFailure("PNG work allocation") }
        return Data(bytesNoCopy: mapping, count: count, deallocator: .unmap)
    }

    /// For sources that were not PNG.
    public static func metadataChunks(iccProfile: Data?, xmp: Data?) throws -> [PNGChunk] {
        var chunks: [PNGChunk] = []
        if let iccProfile {
            var payload = Data("ICC Profile".utf8)
            payload.append(contentsOf: [0, 0])
            let compressed = try compress(iccProfile, level: maximumLevel)
            guard compressed.count <= Int(UInt32.max) - payload.count else {
                throw FormatError.corrupt(
                    String(localized: "PNG chunk too large", comment: "Unrepresentable image chunk"))
            }
            payload.append(compressed)
            chunks.append(PNGChunk(type: "iCCP", payload: payload))
        }
        if let xmp {
            var payload = Data("XML:com.adobe.xmp".utf8)
            payload.append(contentsOf: [0, 0, 0, 0, 0])
            guard xmp.count <= Int(UInt32.max) - payload.count else {
                throw FormatError.corrupt(
                    String(localized: "PNG chunk too large", comment: "Unrepresentable image chunk"))
            }
            payload.append(xmp)
            chunks.append(PNGChunk(type: "iTXt", payload: payload))
        }
        return chunks
    }

    private static func filtered(
        _ raster: PNGRaster, strategy: PNGFilterStrategy, cancelled: (() -> Bool)?
    ) throws
        -> Data
    {
        let rowBytes = raster.rowBytes
        let bpp = raster.bytesPerPixel
        let count = (rowBytes + 1) * raster.height
        var filtered = try mappedBytes(count: count)
        try filtered.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            var offset = 0
            var candidates = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)
            var scratch = [UInt8](repeating: 0, count: rowBytes * (raster.omitsOpaqueAlpha ? 2 : 1))
            try raster.samples.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: UInt8.self)
                try scratch.withUnsafeMutableBufferPointer { scratchRows in
                    for y in 0..<raster.height {
                        if cancelled?() == true { throw CancellationError() }
                        let row: UnsafeBufferPointer<UInt8>
                        let previous: UnsafeBufferPointer<UInt8>
                        if raster.omitsOpaqueAlpha {
                            let start = (y % 2) * rowBytes
                            let current = UnsafeMutableBufferPointer(rebasing: scratchRows[start..<(start + rowBytes)])
                            for column in 0..<raster.width {
                                let source = y * raster.sourceRowBytes + column * 4
                                current[column * 3] = samples[source]
                                current[column * 3 + 1] = samples[source + 1]
                                current[column * 3 + 2] = samples[source + 2]
                            }
                            row = UnsafeBufferPointer(current)
                            let prior = (1 - y % 2) * rowBytes
                            previous = UnsafeBufferPointer(rebasing: scratchRows[prior..<(prior + rowBytes)])
                        } else {
                            row = UnsafeBufferPointer(rebasing: samples[(y * rowBytes)..<((y + 1) * rowBytes)])
                            previous =
                                y == 0
                                ? UnsafeBufferPointer(rebasing: scratchRows[..<rowBytes])
                                : UnsafeBufferPointer(rebasing: samples[((y - 1) * rowBytes)..<(y * rowBytes)])
                        }
                        if strategy == .none || strategy == .adaptive && raster.bitDepth < 8 {
                            output[offset] = 0
                            offset += 1
                            UnsafeMutableRawBufferPointer(rebasing: output[offset..<(offset + rowBytes)]).copyBytes(
                                from: row)
                            offset += rowBytes
                            continue
                        }
                        let filters: [Int]
                        switch strategy {
                        case .none: filters = [0]
                        case .paeth: filters = [4]
                        case .adaptive: filters = raster.bitDepth < 8 ? [0] : [0, 1, 2, 3, 4]
                        }
                        var best = filters[0]
                        var bestScore = Int.max
                        for filter in filters {
                            let score = apply(filter, row: row, previous: previous, bpp: bpp, into: &candidates[filter])
                            guard filters.count > 1 else { break }
                            if score < bestScore {
                                bestScore = score
                                best = filter
                            }
                        }
                        output[offset] = UInt8(best)
                        offset += 1
                        UnsafeMutableRawBufferPointer(rebasing: output[offset..<(offset + rowBytes)]).copyBytes(
                            from: candidates[best])
                        offset += rowBytes
                    }
                }
            }
        }
        return filtered
    }

    private static func apply(
        _ filter: Int, row current: UnsafeBufferPointer<UInt8>, previous preceding: UnsafeBufferPointer<UInt8>,
        bpp: Int, into target: inout [UInt8]
    ) -> Int {
        target.withUnsafeMutableBufferPointer { destination in
            var score = 0
            let prefix = min(bpp, current.count)
            switch filter {
            case 1:
                for index in 0..<prefix {
                    let left: UInt8 = 0
                    let value = current[index] &- left
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
                for index in prefix..<current.count {
                    let left: UInt8 = current[index - bpp]
                    let value = current[index] &- left
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
            case 2:
                for index in current.indices {
                    let value = current[index] &- preceding[index]
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
            case 3:
                for index in 0..<prefix {
                    let left: UInt8 = 0
                    let value = current[index] &- UInt8((Int(left) + Int(preceding[index])) / 2)
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
                for index in prefix..<current.count {
                    let left: UInt8 = current[index - bpp]
                    let value = current[index] &- UInt8((Int(left) + Int(preceding[index])) / 2)
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
            case 4:
                for index in 0..<prefix {
                    let left: UInt8 = 0
                    let upLeft: UInt8 = 0
                    let value = current[index] &- paeth(left, preceding[index], upLeft)
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
                for index in prefix..<current.count {
                    let left: UInt8 = current[index - bpp]
                    let upLeft: UInt8 = preceding[index - bpp]
                    let value = current[index] &- paeth(left, preceding[index], upLeft)
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
            default:
                for index in current.indices {
                    let value = current[index]
                    destination[index] = value
                    score &+= Int(Int8(bitPattern: value).magnitude)
                }
            }
            return score
        }
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a))
        let pb = abs(p - Int(b))
        let pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }
}
