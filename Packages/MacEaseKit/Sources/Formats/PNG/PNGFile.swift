import CDeflate
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
    var samples: [UInt8]
    var palette: [PaletteColor] = []

    var rowBytes: Int { (width * colorType.channels * bitDepth + 7) / 8 }
    var bytesPerPixel: Int { max(1, colorType.channels * bitDepth / 8) }
}

enum PNGFilterStrategy: CaseIterable {
    case none
    case adaptive
    case paeth
}

public enum PNGFile {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let maximumLevel: Int32 = 12
    static let trialLevel: Int32 = 6

    /// Color-type independent, so copied verbatim.
    static let portableAncillaryTypes: Set<String> = [
        "iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI", "pHYs", "eXIf", "iTXt", "tEXt", "zTXt", "tIME",
    ]

    static func chunks(in file: Data) throws -> [PNGChunk] {
        let bytes = [UInt8](file)
        guard bytes.starts(with: signature) else { throw FormatError.corrupt("not a PNG") }
        var chunks: [PNGChunk] = []
        var offset = signature.count
        while offset + 12 <= bytes.count {
            let length = Int(UInt32(bigEndian: bytes, at: offset))
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            guard offset + 12 + length <= bytes.count else { throw FormatError.corrupt("truncated PNG chunk") }
            let type = String(decoding: typeBytes, as: UTF8.self)
            chunks.append(PNGChunk(type: type, payload: Data(bytes[(offset + 8)..<(offset + 8 + length)])))
            offset += 12 + length
            if type == "IEND" { return chunks }
        }
        throw FormatError.corrupt("PNG ends before IEND")
    }

    static func encode(
        _ raster: PNGRaster,
        transparency: [UInt8]? = nil,
        ancillary: [PNGChunk] = [],
        strategy: PNGFilterStrategy,
        level: Int32
    ) throws -> Data {
        guard raster.width > 0, raster.height > 0,
            UInt32(exactly: raster.width) != nil, UInt32(exactly: raster.height) != nil,
            raster.bitDepth > 0, UInt8(exactly: raster.bitDepth) != nil
        else {
            throw FormatError.corrupt(String(localized: "PNG raster out of range", comment: "Invalid image metadata"))
        }
        let rowBytes = raster.rowBytes
        let (sampleBytes, overflow) = rowBytes.multipliedReportingOverflow(by: raster.height)
        guard !overflow, sampleBytes == raster.samples.count, sampleBytes <= Int.max - raster.height else {
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
        chunks.append(PNGChunk(type: "IDAT", payload: try compress(filtered(raster, strategy: strategy), level: level)))
        chunks.append(PNGChunk(type: "IEND", payload: Data()))
        var output = Data(signature)
        for chunk in chunks {
            guard chunk.payload.count <= Int(UInt32.max) else {
                throw FormatError.corrupt(
                    String(localized: "PNG chunk too large", comment: "Unrepresentable image chunk"))
            }
            output.append(serialized(chunk))
        }
        return output
    }

    static func serialized(_ chunk: PNGChunk) -> Data {
        var output = Data()
        output.appendBigEndian(UInt32(chunk.payload.count))
        let typeAndPayload = Data(chunk.type.utf8) + chunk.payload
        output.append(typeAndPayload)
        let crc = typeAndPayload.withUnsafeBytes { libdeflate_crc32(0, $0.baseAddress, $0.count) }
        output.appendBigEndian(crc)
        return output
    }

    static func compress(_ input: [UInt8], level: Int32) throws -> Data {
        guard let compressor = libdeflate_alloc_compressor(level) else {
            throw FormatError.encoderFailure("libdeflate allocation")
        }
        defer { libdeflate_free_compressor(compressor) }
        let bound = libdeflate_zlib_compress_bound(compressor, input.count)
        guard bound <= Int(UInt32.max) else {
            throw FormatError.corrupt(String(localized: "PNG chunk too large", comment: "Unrepresentable image chunk"))
        }
        var output = [UInt8](repeating: 0, count: bound)
        let written = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                libdeflate_zlib_compress(compressor, source.baseAddress, source.count, target.baseAddress, target.count)
            }
        }
        guard written > 0 else { throw FormatError.encoderFailure("deflate output did not fit") }
        return Data(output.prefix(written))
    }

    /// For sources that were not PNG.
    public static func metadataChunks(iccProfile: Data?, xmp: Data?) throws -> [PNGChunk] {
        var chunks: [PNGChunk] = []
        if let iccProfile {
            var payload = Data("ICC Profile".utf8)
            payload.append(contentsOf: [0, 0])
            let compressed = try compress([UInt8](iccProfile), level: maximumLevel)
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

    private static func filtered(_ raster: PNGRaster, strategy: PNGFilterStrategy) -> [UInt8] {
        let rowBytes = raster.rowBytes
        let bpp = raster.bytesPerPixel
        var output = [UInt8]()
        output.reserveCapacity((rowBytes + 1) * raster.height)
        var candidates = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)
        let zeroRow = [UInt8](repeating: 0, count: rowBytes)
        let samples = raster.samples
        for y in 0..<raster.height {
            let row = samples[(y * rowBytes)..<((y + 1) * rowBytes)]
            let previous = y == 0 ? zeroRow[0..<rowBytes] : samples[((y - 1) * rowBytes)..<(y * rowBytes)]
            let filters: [Int]
            switch strategy {
            case .none: filters = [0]
            case .paeth: filters = [4]
            case .adaptive: filters = raster.bitDepth < 8 ? [0] : [0, 1, 2, 3, 4]
            }
            var best = filters[0]
            var bestScore = Int.max
            for filter in filters {
                apply(filter, row: row, previous: previous, bpp: bpp, into: &candidates[filter])
                guard filters.count > 1 else { break }
                let score = candidates[filter].reduce(0) { $0 + Int(Int8(bitPattern: $1).magnitude) }
                if score < bestScore {
                    bestScore = score
                    best = filter
                }
            }
            output.append(UInt8(best))
            output.append(contentsOf: candidates[best])
        }
        return output
    }

    private static func apply(
        _ filter: Int,
        row: ArraySlice<UInt8>,
        previous: ArraySlice<UInt8>,
        bpp: Int,
        into target: inout [UInt8]
    ) {
        let rowStart = row.startIndex
        let previousStart = previous.startIndex
        for index in 0..<row.count {
            let current = row[rowStart + index]
            let left = index >= bpp ? row[rowStart + index - bpp] : 0
            let up = previous[previousStart + index]
            let upLeft = index >= bpp ? previous[previousStart + index - bpp] : 0
            let predictor: UInt8
            switch filter {
            case 1: predictor = left
            case 2: predictor = up
            case 3: predictor = UInt8((Int(left) + Int(up)) / 2)
            case 4: predictor = paeth(left, up, upLeft)
            default: predictor = 0
            }
            target[index] = current &- predictor
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
