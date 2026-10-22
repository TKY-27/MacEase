import CoreGraphics
import Foundation
import ImageIO

/// Writes PNG entries; reads PNG or DIB.
public enum ICOFile {
    public static let standardSizes = [16, 24, 32, 48, 64, 128, 256]
    private static let directorySize = 6
    private static let entrySize = 16

    public static func write(_ images: [(size: Int, png: Data)]) throws -> Data {
        guard !images.isEmpty, images.count <= Int(UInt16.max),
            images.allSatisfy({ (1...256).contains($0.size) })
        else {
            throw FormatError.encoderFailure("ICO entries must be 1 to 256 px")
        }
        let directoryBytes = directorySize + entrySize * images.count
        var imageBytes = 0
        for image in images {
            guard image.png.count <= Int(UInt32.max) - directoryBytes - imageBytes else {
                throw FormatError.corrupt(
                    String(localized: "ICO output too large", comment: "Unrepresentable icon file"))
            }
            imageBytes += image.png.count
        }
        var output = Data()
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(1))
        output.appendLittleEndian(UInt16(images.count))
        var offset = directoryBytes
        for image in images {
            let edge = UInt8(image.size == 256 ? 0 : image.size)
            output.append(contentsOf: [edge, edge, 0, 0])
            output.appendLittleEndian(UInt16(1))
            output.appendLittleEndian(UInt16(32))
            output.appendLittleEndian(UInt32(image.png.count))
            output.appendLittleEndian(UInt32(offset))
            offset += image.png.count
        }
        for image in images { output.append(image.png) }
        return output
    }

    public static func read(_ file: Data) throws -> [PixelBuffer] {
        try DecodedImageBudget.validateEncodedData(file)
        let bytes = [UInt8](file)
        let entries = try entries(in: bytes)
        var budget = DecodedImageBudget()
        for entry in entries {
            try Task.checkCancellation()
            let dimensions = try dimensions(of: bytes, entry: entry)
            try budget.reserve(width: dimensions.width, height: dimensions.height)
        }
        var actualBudget = DecodedImageBudget()
        return try entries.map { entry in
            try Task.checkCancellation()
            let image = try decode(bytes, entry: entry)
            try actualBudget.reserve(width: image.width, height: image.height)
            return image
        }
    }

    public static func validateStructure(_ file: Data) throws {
        try DecodedImageBudget.validateEncodedData(file)
        _ = try entries(in: [UInt8](file))
    }

    public static func readLargest(_ file: Data) throws -> PixelBuffer {
        try DecodedImageBudget.validateEncodedData(file)
        let bytes = [UInt8](file)
        let (selected, dimensions) = try largestEntry(in: bytes)
        var budget = DecodedImageBudget()
        try budget.reserve(width: dimensions.width, height: dimensions.height)
        return try decode(bytes, entry: selected)
    }

    public static func largestDimensions(_ file: Data) throws -> (width: Int, height: Int) {
        try DecodedImageBudget.validateEncodedData(file)
        return try largestEntry(in: [UInt8](file)).dimensions
    }

    private static func largestEntry(in bytes: [UInt8]) throws -> (entry: Entry, dimensions: (width: Int, height: Int))
    {
        let entries = try entries(in: bytes)
        var selected: Entry?
        var selectedWidth = 0
        var selectedHeight = 0
        for entry in entries {
            try Task.checkCancellation()
            let dimensions = try dimensions(of: bytes, entry: entry)
            if dimensions.width > selectedWidth {
                selected = entry
                selectedWidth = dimensions.width
                selectedHeight = dimensions.height
            }
        }
        guard let selected else { throw FormatError.corrupt("ICO has no entries") }
        return (selected, (selectedWidth, selectedHeight))
    }

    private struct Entry {
        let offset: Int
        let length: Int
    }

    private static func entries(in bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= directorySize, UInt16(littleEndian: bytes, at: 0) == 0,
            UInt16(littleEndian: bytes, at: 2) == 1
        else { throw FormatError.corrupt("not an ICO file") }
        let count = Int(UInt16(littleEndian: bytes, at: 4))
        let directoryEnd = directorySize + count * entrySize
        guard bytes.count >= directoryEnd else { throw FormatError.corrupt("truncated ICO") }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            let entry = directorySize + index * entrySize
            let length = Int(UInt32(littleEndian: bytes, at: entry + 8))
            let offset = Int(UInt32(littleEndian: bytes, at: entry + 12))
            guard length > 0, offset >= directoryEnd, offset <= bytes.count,
                length <= bytes.count - offset
            else {
                throw FormatError.corrupt("ICO entry out of range")
            }
            entries.append(Entry(offset: offset, length: length))
        }
        let sorted = entries.sorted { $0.offset < $1.offset }
        if sorted.count > 1 {
            for index in 1..<sorted.count
            where sorted[index].offset < sorted[index - 1].offset + sorted[index - 1].length {
                throw FormatError.corrupt("overlapping ICO entries")
            }
        }
        return entries
    }

    private static func dimensions(of bytes: [UInt8], entry: Entry) throws -> (width: Int, height: Int) {
        let payload = Array(bytes[entry.offset..<(entry.offset + entry.length)])
        if payload.starts(with: PNGFile.signature) {
            return try EmbeddedImage.dimensions(Data(payload), maximumEdge: ICNSFile.maximumEdge)
        }
        return try DIBImage.dimensions(payload)
    }

    private static func decode(_ bytes: [UInt8], entry: Entry) throws -> PixelBuffer {
        let payload = Array(bytes[entry.offset..<(entry.offset + entry.length)])
        if payload.starts(with: PNGFile.signature) {
            return try EmbeddedImage.decode(Data(payload), maximumEdge: ICNSFile.maximumEdge)
        }
        return try DIBImage.decode(payload)
    }

}

/// Checks declared size before decoding untrusted payloads.
enum EmbeddedImage {
    static func dimensions(_ payload: Data, maximumEdge: Int) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw FormatError.corrupt("embedded image has no size") }
        guard width > 0, height > 0, width <= maximumEdge, height <= maximumEdge else {
            throw FormatError.unsupported("embedded image of \(width)×\(height)")
        }
        return (width, height)
    }

    static func decode(_ payload: Data, maximumEdge: Int) throws -> PixelBuffer {
        let dimensions = try dimensions(payload, maximumEdge: maximumEdge)
        var budget = DecodedImageBudget()
        try budget.reserve(width: dimensions.width, height: dimensions.height)
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FormatError.corrupt("embedded image does not decode")
        }
        guard image.width <= maximumEdge, image.height <= maximumEdge else {
            throw FormatError.frameMemoryExceeded
        }
        var actualBudget = DecodedImageBudget()
        try actualBudget.reserve(width: image.width, height: image.height)
        return try PixelBuffer(cgImage: image)
    }
}

/// ICO's headerless BMP: colors, then AND mask.
enum DIBImage {
    static func dimensions(_ bytes: [UInt8]) throws -> (width: Int, height: Int) {
        guard bytes.count >= 12 else { throw FormatError.corrupt("short DIB header") }
        let width = Int(Int32(bitPattern: UInt32(littleEndian: bytes, at: 4)))
        let doubledHeight = Int(Int32(bitPattern: UInt32(littleEndian: bytes, at: 8)))
        let height = abs(doubledHeight) / 2
        guard width > 0, height > 0, width <= ICNSFile.maximumEdge, height <= ICNSFile.maximumEdge else {
            throw FormatError.unsupported("DIB variant")
        }
        return (width, height)
    }

    static func decode(_ bytes: [UInt8]) throws -> PixelBuffer {
        guard bytes.count >= 40 else { throw FormatError.corrupt("short DIB header") }
        let headerSize = Int(UInt32(littleEndian: bytes, at: 0))
        let dimensions = try dimensions(bytes)
        let width = dimensions.width
        let height = dimensions.height
        let bitCount = Int(UInt16(littleEndian: bytes, at: 14))
        let compression = UInt32(littleEndian: bytes, at: 16)
        guard compression == 0,
            [1, 4, 8, 24, 32].contains(bitCount)
        else { throw FormatError.unsupported("DIB variant") }
        var paletteEntries = Int(UInt32(littleEndian: bytes, at: 32))
        if bitCount <= 8, paletteEntries == 0 { paletteEntries = 1 << bitCount }
        if bitCount > 8 { paletteEntries = 0 }
        let paletteOffset = headerSize
        let pixelOffset = paletteOffset + paletteEntries * 4
        let xorStride = (width * bitCount + 31) / 32 * 4
        let andStride = (width + 31) / 32 * 4
        let andOffset = pixelOffset + xorStride * height
        guard bytes.count >= andOffset else { throw FormatError.corrupt("truncated DIB") }
        let hasMask = bytes.count >= andOffset + andStride * height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var anyAlpha = false
        for row in 0..<height {
            let y = height - 1 - row
            let line = pixelOffset + row * xorStride
            for x in 0..<width {
                let target = (y * width + x) * 4
                switch bitCount {
                case 32:
                    let source = line + x * 4
                    rgba[target] = bytes[source + 2]
                    rgba[target + 1] = bytes[source + 1]
                    rgba[target + 2] = bytes[source]
                    rgba[target + 3] = bytes[source + 3]
                    if bytes[source + 3] != 0 { anyAlpha = true }
                case 24:
                    let source = line + x * 3
                    rgba[target] = bytes[source + 2]
                    rgba[target + 1] = bytes[source + 1]
                    rgba[target + 2] = bytes[source]
                    rgba[target + 3] = 255
                default:
                    let bitIndex = x * bitCount
                    let byte = bytes[line + bitIndex / 8]
                    let shift = 8 - bitCount - bitIndex % 8
                    let index = Int(byte >> shift) & ((1 << bitCount) - 1)
                    let entry = paletteOffset + index * 4
                    guard entry + 2 < bytes.count else { throw FormatError.corrupt("DIB palette index") }
                    rgba[target] = bytes[entry + 2]
                    rgba[target + 1] = bytes[entry + 1]
                    rgba[target + 2] = bytes[entry]
                    rgba[target + 3] = 255
                }
            }
        }
        if bitCount == 32, !anyAlpha {
            for index in stride(from: 3, to: rgba.count, by: 4) { rgba[index] = 255 }
        }
        if hasMask, !(bitCount == 32 && anyAlpha) {
            for row in 0..<height {
                let y = height - 1 - row
                let line = andOffset + row * andStride
                for x in 0..<width where bytes[line + x / 8] >> (7 - x % 8) & 1 == 1 {
                    rgba[(y * width + x) * 4 + 3] = 0
                }
            }
        }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }
}
