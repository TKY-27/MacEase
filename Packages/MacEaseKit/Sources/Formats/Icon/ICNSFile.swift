import CoreGraphics
import Foundation
import ImageIO

/// Writes PNG; reads PNG, JPEG 2000, RLE.
public enum ICNSFile {
    /// Element type and pixel edge, smallest first.
    public static let pngElements: [(type: String, size: Int)] = [
        ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512),
        ("ic10", 1024),
    ]

    /// Larger embedded images are refused, not decoded.
    static let maximumEdge = 1024

    private static let legacyRLE: [String: (size: Int, mask: String)] = [
        "is32": (16, "s8mk"), "il32": (32, "l8mk"), "ih32": (48, "h8mk"), "it32": (128, "t8mk"),
    ]

    /// `pngBySize` must hold every edge in `pngElements`.
    public static func write(pngBySize: [Int: Data]) throws -> Data {
        var body = Data()
        for element in pngElements {
            guard let png = pngBySize[element.size] else {
                throw FormatError.encoderFailure("missing \(element.size) px")
            }
            body.append(Data(element.type.utf8))
            body.appendBigEndian(UInt32(png.count + 8))
            body.append(png)
        }
        var output = Data("icns".utf8)
        output.appendBigEndian(UInt32(body.count + 8))
        output.append(body)
        return output
    }

    public static func read(_ file: Data) throws -> [PixelBuffer] {
        let bytes = [UInt8](file)
        guard bytes.count >= 8, String(decoding: bytes[0..<4], as: UTF8.self) == "icns" else {
            throw FormatError.corrupt("not an ICNS file")
        }
        var elements: [String: [UInt8]] = [:]
        var order: [String] = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let type = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let length = Int(UInt32(bigEndian: bytes, at: offset + 4))
            guard length >= 8, offset + length <= bytes.count else {
                throw FormatError.corrupt("ICNS element out of range")
            }
            elements[type] = Array(bytes[(offset + 8)..<(offset + length)])
            order.append(type)
            offset += length
        }
        var images: [PixelBuffer] = []
        for type in order {
            guard let payload = elements[type] else { continue }
            if let legacy = legacyRLE[type] {
                images.append(try decodeLegacy(payload, type: type, size: legacy.size, mask: elements[legacy.mask]))
            } else if let image = try decodeEncoded(payload) {
                images.append(image)
            }
        }
        guard !images.isEmpty else { throw FormatError.unsupported("no readable ICNS element") }
        return images
    }

    private static let jpeg2000Signature: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]

    /// `nil` for non-image elements such as TOC.
    private static func decodeEncoded(_ payload: [UInt8]) throws -> PixelBuffer? {
        guard payload.starts(with: PNGFile.signature) || payload.starts(with: jpeg2000Signature) else { return nil }
        return try EmbeddedImage.decode(Data(payload), maximumEdge: maximumEdge)
    }

    private static func decodeLegacy(_ payload: [UInt8], type: String, size: Int, mask: [UInt8]?) throws -> PixelBuffer
    {
        let pixelCount = size * size
        // it32 data starts after four zero bytes.
        let start = type == "it32" ? 4 : 0
        var channels = [[UInt8]]()
        var offset = start
        for _ in 0..<3 {
            var channel = [UInt8]()
            channel.reserveCapacity(pixelCount)
            while channel.count < pixelCount {
                guard offset < payload.count else { throw FormatError.corrupt("truncated ICNS RLE") }
                let control = Int(payload[offset])
                offset += 1
                if control & 0x80 == 0 {
                    let run = control + 1
                    guard offset + run <= payload.count else { throw FormatError.corrupt("truncated ICNS RLE") }
                    channel.append(contentsOf: payload[offset..<(offset + run)])
                    offset += run
                } else {
                    guard offset < payload.count else { throw FormatError.corrupt("truncated ICNS RLE") }
                    channel.append(contentsOf: repeatElement(payload[offset], count: control - 125))
                    offset += 1
                }
            }
            channels.append(Array(channel.prefix(pixelCount)))
        }
        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
        for pixel in 0..<pixelCount {
            rgba[pixel * 4] = channels[0][pixel]
            rgba[pixel * 4 + 1] = channels[1][pixel]
            rgba[pixel * 4 + 2] = channels[2][pixel]
            if let mask, mask.count >= pixelCount { rgba[pixel * 4 + 3] = mask[pixel] }
        }
        return PixelBuffer(width: size, height: size, rgba: rgba)
    }
}
